// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * RitualPredict — a self-resolving binary prediction market.
 *
 * Users stake native RITUAL on YES or NO. When the betting window closes, nobody
 * clicks "resolve" and no backend cron runs: the Ritual Scheduler wakes the contract
 * at a block chosen at market-creation time. The contract then calls the HTTP
 * precompile (0x0801) to read the configured oracle URL, extracts one number with the
 * jq precompile (0x0803), compares it to the target, and settles the market.
 *
 * Payouts are pari-mutuel and pull-based: each winner claims
 * `stake * totalPool / winningPool`. Nothing loops over participants.
 *
 * Every deadline is a BLOCK NUMBER, so "betting is closed" and "the Scheduler woke us"
 * can never disagree. Human durations are converted at `blockTimeMs`, measured from the
 * live chain at deploy time (`scripts/block-time.ts`).
 */
contract RitualPredict {
    // ─────────────────────────────── Types ───────────────────────────────

    enum MarketState {
        Open, // accepting bets
        Closed, // betting window over, waiting for the scheduled wake-up
        Resolving, // a resolution attempt has run and failed; retries pending
        Resolved, // outcome final, winners can claim
        Invalid // could not be resolved (or nobody won); everyone refunds
    }

    enum Comparator {
        GT, // observed >  target
        GTE, // observed >= target
        LT, // observed <  target
        LTE // observed <= target
    }

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    /// Storage layout *and* the shape returned by `getMarket` / `getMarkets`.
    struct Market {
        uint256 id;
        address creator;
        string question;
        // ── resolution rule: fixed at creation, no setter exists ──
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        // ── mutable state ──
        uint256 totalYes;
        uint256 totalNo;
        MarketState state;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue;
        string invalidReason;
    }

    /// Arguments to `createMarket`, grouped so the whole rule reads as one unit at the
    /// call site (and to keep the stack shallow).
    struct NewMarket {
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    // ────────────────────────────── Constants ────────────────────────────

    /// Resolution attempts per market, booked up front as the Scheduler's `numCalls`,
    /// `RETRY_INTERVAL_BLOCKS` apart. `frequency * numCalls` must stay under the
    /// Scheduler's MAX_LIFESPAN of 10,000.
    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;

    /// Gas per scheduled execution — one HTTP call, one jq call, a few storage writes.
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;

    /// Scheduler TTL. Must cover trigger drift *and* async HTTP settlement, because the
    /// settlement replay re-runs Scheduler.execute() and re-checks the TTL.
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;

    /// Blocks the TEE executor has to fulfil the HTTP request.
    uint256 public constant HTTP_TTL_BLOCKS = 100;

    /// Registry slots to probe when picking a TEE executor.
    uint256 public constant EXECUTOR_PROBES = 8;

    /// Floor for the fee authorised per scheduled execution.
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;

    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;
    /// Dust filter so a 1-wei "bet" cannot grief the pool display.
    uint256 public constant MIN_STAKE = 0.001 ether;

    // ────────────────────────────── Storage ──────────────────────────────

    /// Assumed block time, used only to turn human durations into block counts.
    /// Ritual Chain ran ~195ms when this was written.
    uint256 public immutable blockTimeMs;

    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;

    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public settled;

    // ────────────────────────────── Events ───────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );
    /// The resolution rule, emitted separately from MarketCreated. None of these values
    /// can change afterwards — there is no setter.
    event ResolutionRuleSet(
        uint256 indexed marketId,
        string oracleUrl,
        string jsonPath,
        uint256 target,
        Comparator comparator
    );
    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );
    event ResolutionAttempted(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );
    event ResolutionFailed(
        uint256 indexed marketId,
        uint8 attempt,
        string reason
    );
    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 observedValue
    );
    event MarketInvalidated(uint256 indexed marketId, string reason);
    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );
    event StakeRefunded(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );

    // ────────────────────────────── Errors ───────────────────────────────

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error NotResolved();
    error NotInvalid();
    error NothingToClaim();
    error AlreadySettled();
    error BadDuration();
    error EmptyString();
    error TransferFailed();
    error FeedRejected();
    error QueryRejected();
    error DustStake();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;

        // Let the Scheduler call back into this contract and draw execution fees from
        // this contract's RitualWallet balance.
        IScheduler(RitualChain.SCHEDULER).approveScheduler(
            RitualChain.SCHEDULER
        );
    }

    // ───────────────────────── Market lifecycle ──────────────────────────

    /**
     * Create a market and, in the same transaction, book its own resolution with the
     * Scheduler: `MAX_ATTEMPTS` executions starting at `resolveBlock`.
     */
    function createMarket(
        NewMarket calldata p
    ) external returns (uint256 marketId) {
        if (bytes(p.question).length == 0) revert EmptyString();
        if (!_feedAllowed(p.oracleUrl)) revert FeedRejected();
        if (!_queryAllowed(p.jsonPath)) revert QueryRejected();
        if (
            p.bettingSeconds < MIN_BETTING_SECONDS ||
            p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS ||
            p.bettingSeconds + p.resolveDelaySeconds > MAX_MARKET_SECONDS
        ) revert BadDuration();

        marketId = ++marketCount;
        Market storage slot = _markets[marketId];
        slot.id = marketId;
        slot.creator = msg.sender;
        slot.question = p.question;
        slot.oracleUrl = p.oracleUrl;
        slot.jsonPath = p.jsonPath;
        slot.target = p.target;
        slot.comparator = p.comparator;
        (slot.closeBlock, slot.resolveBlock) = _window(
            p.bettingSeconds,
            p.resolveDelaySeconds
        );
        slot.state = MarketState.Open;
        slot.scheduleId = _bookWake(marketId, slot.resolveBlock);

        emit MarketCreated(
            marketId,
            msg.sender,
            p.question,
            slot.closeBlock,
            slot.resolveBlock,
            slot.scheduleId
        );
        emit ResolutionRuleSet(
            marketId,
            p.oracleUrl,
            p.jsonPath,
            p.target,
            p.comparator
        );
    }

    function bet(uint256 marketId, bool isYes) external payable {
        Market storage m = _market(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (msg.value < MIN_STAKE) revert DustStake();
        if (m.state != MarketState.Open || block.number >= m.closeBlock)
            revert BettingClosed();

        if (isYes) {
            yesStake[marketId][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            noStake[marketId][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    /**
     * Scheduler callback. `executionIndex` is written into calldata bytes 4-35 by the
     * Scheduler, so it must be the first parameter.
     *
     * Deliberately revert-free for anything that is not an authorisation failure: a
     * reverted execution would roll back the attempt counter, and the market could then
     * never reach `Invalid`.
     */
    function onScheduledResolve(
        uint256 executionIndex,
        uint256 marketId
    ) external {
        if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();

        Market storage slot = _markets[marketId];
        if (slot.closeBlock == 0) return;
        if (
            slot.state == MarketState.Resolved ||
            slot.state == MarketState.Invalid
        ) return;
        if (block.number < slot.resolveBlock) return;

        uint8 n = ++slot.attempts;
        slot.state = MarketState.Resolving;

        address tee = _chooseTee(marketId, executionIndex);
        emit ResolutionAttempted(marketId, n, tee);
        if (tee == address(0)) {
            _fail(slot, marketId, n, "no tee");
            return;
        }

        (bool ok, uint256 observed, string memory why) = _pullFeed(slot, tee);
        if (!ok) {
            _fail(slot, marketId, n, why);
            return;
        }

        Outcome side = _compare(observed, slot.target, slot.comparator)
            ? Outcome.Yes
            : Outcome.No;
        slot.observedValue = observed;
        slot.outcome = side;
        emit MarketResolved(marketId, side, observed);

        uint256 winners = side == Outcome.Yes ? slot.totalYes : slot.totalNo;
        if (winners == 0) {
            _invalidate(slot, marketId, "empty book");
        } else {
            slot.state = MarketState.Resolved;
        }

        try IScheduler(RitualChain.SCHEDULER).cancel(slot.scheduleId) {} catch {}
    }

    /// A failed oracle read is never interpreted as NO. Once the booked attempts are
    /// exhausted the market becomes refundable instead.
    function _fail(
        Market storage m,
        uint256 marketId,
        uint8 attempt,
        string memory reason
    ) private {
        emit ResolutionFailed(marketId, attempt, reason);
        if (attempt >= MAX_ATTEMPTS) _invalidate(m, marketId, reason);
    }

    function _invalidate(
        Market storage m,
        uint256 marketId,
        string memory reason
    ) private {
        m.state = MarketState.Invalid;
        m.invalidReason = reason;
        emit MarketInvalidated(marketId, reason);
    }

    // ────────────────────────────── Payouts ──────────────────────────────

    /// Pull-based, proportional share of the whole pool. No loops over participants.
    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Resolved) revert NotResolved();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 payout = _payout(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit WinningsClaimed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    /// Reclaim the original stake from an invalid market.
    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Invalid) revert NotInvalid();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = yesStake[marketId][msg.sender] +
            noStake[marketId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit StakeRefunded(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    /// `stake * totalPool / winningPool`, or 0 if this account backed the losing side.
    function _payout(
        Market storage m,
        uint256 marketId,
        address account
    ) private view returns (uint256) {
        bool yesWon = m.outcome == Outcome.Yes;
        uint256 stake = yesWon
            ? yesStake[marketId][account]
            : noStake[marketId][account];
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (stake == 0 || winningPool == 0) return 0;
        return (stake * (m.totalYes + m.totalNo)) / winningPool;
    }

    // ─────────────────────────────── Views ───────────────────────────────

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        // No transaction exists to flip Open → Closed, so the view does it.
        if (m.state == MarketState.Open && block.number >= m.closeBlock)
            m.state = MarketState.Closed;
    }

    /// Every market, newest first. A workshop has a handful; there is no pagination.
    function getMarkets() external view returns (Market[] memory all) {
        uint256 total = marketCount;
        all = new Market[](total);
        for (uint256 i = 0; i < total; i++) {
            all[i] = getMarket(total - i);
        }
    }

    function stakesOf(
        uint256 marketId,
        address account
    )
        external
        view
        returns (
            uint256 yes,
            uint256 no,
            bool alreadySettled,
            uint256 claimable
        )
    {
        Market storage m = _market(marketId);
        (yes, no, alreadySettled) = (
            yesStake[marketId][account],
            noStake[marketId][account],
            settled[marketId][account]
        );
        if (alreadySettled) return (yes, no, true, 0);

        if (m.state == MarketState.Resolved)
            claimable = _payout(m, marketId, account);
        else if (m.state == MarketState.Invalid) claimable = yes + no;
    }

    // ───────────────────────── Execution funding ─────────────────────────

    /// Prepay Scheduler + HTTP precompile fees. Anyone may top the contract up; the
    /// balance lives in RitualWallet under this contract's address, which is the
    /// `payer` of every scheduled execution.
    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(
            lockDurationBlocks
        );
    }

    function executionBalance() external view returns (uint256) {
        return
            IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    // ───────────────────── Ritual: oracle read path ──────────────────────

    /// HTTP (0x0801) → jq (0x0803), both inside this one scheduled transaction.
    function _pullFeed(
        Market storage m,
        address executor
    ) private returns (bool ok, uint256 value, string memory reason) {
        bytes memory payload = abi.encode(
            executor,
            new bytes[](0),
            HTTP_TTL_BLOCKS,
            new bytes[](0),
            bytes(""),
            m.oracleUrl,
            RitualChain.HTTP_GET,
            new string[](0),
            new string[](0),
            bytes(""),
            uint256(0),
            uint8(0),
            false
        );

        (bool sent, bytes memory raw) = RitualChain.HTTP_PRECOMPILE.call(
            payload
        );
        if (!sent) return (false, 0, "http miss");

        uint16 code;
        bytes memory body;
        string memory err;
        try this.decodeHttpResponse(raw) returns (
            uint16 c,
            bytes memory b,
            string memory e
        ) {
            code = c;
            body = b;
            err = e;
        } catch {
            return (false, 0, "bad envelope");
        }

        if (bytes(err).length != 0) return (false, 0, err);
        if (code != 200) return (false, 0, "status");
        if (body.length == 0) return (false, 0, "empty body");

        (bool parsed, uint256 n) = _jqUint(m.jsonPath, string(body));
        if (!parsed) return (false, 0, "jq");
        return (true, n, "");
    }

    /**
     * Unwraps the short-running async envelope `(bytes simmedInput, bytes actualOutput)`
     * and the 5-field HTTP response inside it.
     *
     * External so `_pullFeed` can call it through `try`. Reverting on malformed input
     * is exactly the signal the caller wants.
     */
    function decodeHttpResponse(
        bytes calldata raw
    )
        external
        pure
        returns (uint16 status, bytes memory body, string memory errorMessage)
    {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        // Empty during simulation, before the executor has run.
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    /// jq is synchronous. A wrong outputType returns ok=true with zero-length output,
    /// so the length check is load-bearing.
    function _jqUint(
        string memory query,
        string memory json
    ) private view returns (bool, uint256) {
        (bool ok, bytes memory result) = RitualChain.JQ_PRECOMPILE.staticcall(
            abi.encode(query, json, RitualChain.JQ_OUT_UINT256)
        );
        if (!ok || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _chooseTee(
        uint256 marketId,
        uint256 executionIndex
    ) private view returns (address) {
        uint256 seed = uint256(
            keccak256(
                abi.encode(marketId, executionIndex, block.number, address(this))
            )
        );
        try
            ITEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY)
                .pickServiceByCapability(
                    RitualChain.CAPABILITY_HTTP_CALL,
                    true,
                    seed,
                    EXECUTOR_PROBES
                )
        returns (address tee, bool ok) {
            if (!ok || tee == address(0)) return address(0);
            return tee;
        } catch {
            return address(0);
        }
    }

    function _bookWake(
        uint256 marketId,
        uint64 resolveBlock
    ) private returns (uint256 callId) {
        bytes memory data = abi.encodeWithSelector(
            this.onScheduledResolve.selector,
            uint256(0),
            marketId
        );
        uint256 feeCap = block.basefee * 3;
        if (feeCap < MIN_MAX_FEE_PER_GAS) feeCap = MIN_MAX_FEE_PER_GAS;

        return
            IScheduler(RitualChain.SCHEDULER).schedule(
                data,
                RESOLVE_GAS_LIMIT,
                uint32(resolveBlock),
                MAX_ATTEMPTS,
                RETRY_INTERVAL_BLOCKS,
                SCHEDULER_TTL_BLOCKS,
                feeCap,
                0,
                0,
                address(this)
            );
    }

    function windowsFor(
        uint256 bettingSeconds,
        uint256 resolveDelaySeconds
    ) external view returns (uint64 closeBlock, uint64 resolveBlock) {
        return _window(bettingSeconds, resolveDelaySeconds);
    }

    function ruleHolds(
        uint256 observed,
        uint256 target,
        Comparator comparator
    ) external pure returns (bool) {
        return _compare(observed, target, comparator);
    }

    function liveMarkets() external view returns (Market[] memory openOnes) {
        uint256 total = marketCount;
        uint256 n;
        for (uint256 i = 1; i <= total; i++) {
            Market memory m = getMarket(i);
            if (
                m.state == MarketState.Open || m.state == MarketState.Closed
            ) n++;
        }
        openOnes = new Market[](n);
        uint256 w;
        for (uint256 i = total; i >= 1; i--) {
            Market memory m = getMarket(i);
            if (
                m.state == MarketState.Open || m.state == MarketState.Closed
            ) {
                openOnes[w++] = m;
            }
            if (i == 1) break;
        }
    }

    function purseLock() external view returns (uint256) {
        return IRitualWallet(RitualChain.RITUAL_WALLET).lockUntil(address(this));
    }

    // ────────────────────────────── Helpers ──────────────────────────────

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _compare(
        uint256 observed,
        uint256 target,
        Comparator comparator
    ) private pure returns (bool) {
        if (comparator == Comparator.GT) return observed > target;
        if (comparator == Comparator.GTE) return observed >= target;
        if (comparator == Comparator.LT) return observed < target;
        return observed <= target;
    }

    function _secondsToBlocks(
        uint256 seconds_
    ) private view returns (uint256 blocks) {
        blocks = (seconds_ * 1000) / blockTimeMs;
        if (blocks == 0) blocks = 1;
    }

    function _window(
        uint256 bettingSeconds,
        uint256 resolveDelaySeconds
    ) private view returns (uint64 closeBlock, uint64 resolveBlock) {
        closeBlock = uint64(block.number + _secondsToBlocks(bettingSeconds));
        resolveBlock = uint64(
            block.number +
                _secondsToBlocks(bettingSeconds + resolveDelaySeconds)
        );
    }

    function _feedAllowed(string memory url) private pure returns (bool) {
        bytes memory b = bytes(url);
        if (b.length < 12) return false;
        bool http = _prefix(b, "http://");
        bool https = _prefix(b, "https://");
        if (!http && !https) return false;
        if (_has(b, "localhost") || _has(b, "127.0.0.1") || _has(b, "0.0.0.0")) {
            return false;
        }
        return true;
    }

    function _queryAllowed(string memory path) private pure returns (bool) {
        bytes memory b = bytes(path);
        if (b.length < 2 || b[0] != bytes1(".")) return false;
        bool letter;
        for (uint256 i = 1; i < b.length; i++) {
            bytes1 c = b[i];
            if (
                (c >= 0x41 && c <= 0x5A) ||
                (c >= 0x61 && c <= 0x7A)
            ) letter = true;
        }
        return letter;
    }

    function _prefix(bytes memory hay, string memory needle) private pure returns (bool) {
        bytes memory n = bytes(needle);
        if (hay.length < n.length) return false;
        for (uint256 i = 0; i < n.length; i++) {
            if (hay[i] != n[i]) return false;
        }
        return true;
    }

    function _has(bytes memory hay, string memory needle) private pure returns (bool) {
        bytes memory n = bytes(needle);
        if (hay.length < n.length) return false;
        uint256 lim = hay.length - n.length + 1;
        for (uint256 i = 0; i < lim; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (hay[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// Scheduler gas refunds land in RitualWallet, but accept plain transfers anyway.
    receive() external payable {}
}
