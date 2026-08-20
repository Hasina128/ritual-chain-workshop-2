// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RitualPredict} from "./RitualPredict.sol";
import {RitualChain} from "./ritual/RitualChain.sol";
import {StubScheduler, StubPurse, StubRegistry, StubHttp, StubJq} from "./harness/Stubs.sol";

contract PredictHarness is Test {
    uint256 constant MS = 1000;
    RitualPredict desk;
    address kay;
    address leo;
    address tee;

    function setUp() public {
        kay = makeAddr("kay");
        leo = makeAddr("leo");
        tee = makeAddr("tee");

        vm.etch(RitualChain.SCHEDULER, address(new StubScheduler()).code);
        vm.etch(RitualChain.RITUAL_WALLET, address(new StubPurse()).code);
        vm.etch(RitualChain.TEE_SERVICE_REGISTRY, address(new StubRegistry()).code);
        vm.etch(RitualChain.HTTP_PRECOMPILE, address(new StubHttp()).code);
        vm.etch(RitualChain.JQ_PRECOMPILE, address(new StubJq()).code);

        StubRegistry(RitualChain.TEE_SERVICE_REGISTRY).configure(tee, true);
        StubHttp(RitualChain.HTTP_PRECOMPILE).tune(200, bytes('{"price":4100}'), "");
        StubJq(RitualChain.JQ_PRECOMPILE).set(4100);

        desk = new RitualPredict(MS);
        vm.deal(address(this), 50 ether);
        vm.deal(kay, 50 ether);
        vm.deal(leo, 50 ether);
    }

    function _spec() internal pure returns (RitualPredict.NewMarket memory) {
        return
            RitualPredict.NewMarket({
                question: "ETH at least 4000 by close?",
                oracleUrl: "https://feed.example/eth",
                jsonPath: ".price",
                target: 4000,
                comparator: RitualPredict.Comparator.GTE,
                bettingSeconds: 30,
                resolveDelaySeconds: 15
            });
    }

    function _open() internal returns (uint256 id) {
        return desk.createMarket(_spec());
    }

    function _wake(uint256 id) internal {
        RitualPredict.Market memory m = desk.getMarket(id);
        vm.roll(m.resolveBlock);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 0);
    }

    function testCtorRejectsZeroMs() public {
        vm.expectRevert(RitualPredict.BadDuration.selector);
        new RitualPredict(0);
    }

    function testOpenStoresRuleAndJob() public {
        uint256 id = _open();
        RitualPredict.Market memory m = desk.getMarket(id);
        assertEq(m.creator, address(this));
        assertEq(m.target, 4000);
        assertEq(m.closeBlock, uint64(block.number + 30));
        assertEq(m.resolveBlock, uint64(block.number + 45));
        assertEq(m.scheduleId, 1);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Open));
    }

    function testOpenRejectsBlankQuestion() public {
        RitualPredict.NewMarket memory p = _spec();
        p.question = "";
        vm.expectRevert(RitualPredict.EmptyString.selector);
        desk.createMarket(p);
    }

    function testOpenRejectsLoopbackFeed() public {
        RitualPredict.NewMarket memory p = _spec();
        p.oracleUrl = "https://127.0.0.1/x";
        vm.expectRevert(RitualPredict.FeedRejected.selector);
        desk.createMarket(p);
    }

    function testOpenRejectsLocalhostFeed() public {
        RitualPredict.NewMarket memory p = _spec();
        p.oracleUrl = "http://localhost:9/x";
        vm.expectRevert(RitualPredict.FeedRejected.selector);
        desk.createMarket(p);
    }

    function testOpenRejectsBareHost() public {
        RitualPredict.NewMarket memory p = _spec();
        p.oracleUrl = "feed.example/eth";
        vm.expectRevert(RitualPredict.FeedRejected.selector);
        desk.createMarket(p);
    }

    function testOpenRejectsQueryWithoutDot() public {
        RitualPredict.NewMarket memory p = _spec();
        p.jsonPath = "price";
        vm.expectRevert(RitualPredict.QueryRejected.selector);
        desk.createMarket(p);
    }

    function testOpenRejectsQueryWithoutLetter() public {
        RitualPredict.NewMarket memory p = _spec();
        p.jsonPath = ".1";
        vm.expectRevert(RitualPredict.QueryRejected.selector);
        desk.createMarket(p);
    }

    function testOpenRejectsShortWindow() public {
        RitualPredict.NewMarket memory p = _spec();
        p.bettingSeconds = 10;
        vm.expectRevert(RitualPredict.BadDuration.selector);
        desk.createMarket(p);
    }

    function testTicketYesAndNo() public {
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 0.2 ether}(id, true);
        vm.prank(leo);
        desk.bet{value: 0.05 ether}(id, false);
        (uint256 y, uint256 n, , ) = desk.stakesOf(id, kay);
        assertEq(y, 0.2 ether);
        assertEq(n, 0);
        assertEq(desk.getMarket(id).totalNo, 0.05 ether);
    }

    function testDustTicketReverts() public {
        uint256 id = _open();
        vm.prank(kay);
        vm.expectRevert(RitualPredict.DustStake.selector);
        desk.bet{value: 0.0001 ether}(id, true);
    }

    function testZeroTicketReverts() public {
        uint256 id = _open();
        vm.expectRevert(RitualPredict.ZeroStake.selector);
        desk.bet{value: 0}(id, true);
    }

    function testTicketAfterCloseReverts() public {
        uint256 id = _open();
        vm.roll(desk.getMarket(id).closeBlock);
        vm.prank(kay);
        vm.expectRevert(RitualPredict.BettingClosed.selector);
        desk.bet{value: 0.01 ether}(id, true);
    }

    function testViewFlipsToClosed() public {
        uint256 id = _open();
        vm.roll(desk.getMarket(id).closeBlock);
        assertEq(uint8(desk.getMarket(id).state), uint8(RitualPredict.MarketState.Closed));
    }

    function testStrangerCannotWake() public {
        uint256 id = _open();
        vm.expectRevert(RitualPredict.OnlyScheduler.selector);
        desk.onScheduledResolve(0, id);
    }

    function testEarlyKickIsNoop() public {
        uint256 id = _open();
        StubScheduler(RitualChain.SCHEDULER).kick(desk.getMarket(id).scheduleId, 0);
        assertEq(desk.getMarket(id).attempts, 0);
    }

    function testYesWhenFeedClearsTarget() public {
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 1 ether}(id, true);
        vm.prank(leo);
        desk.bet{value: 1 ether}(id, false);
        _wake(id);
        RitualPredict.Market memory m = desk.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Resolved));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.observedValue, 4100);
    }

    function testNoWhenFeedMissesTarget() public {
        StubJq(RitualChain.JQ_PRECOMPILE).set(3900);
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 1 ether}(id, true);
        vm.prank(leo);
        desk.bet{value: 1 ether}(id, false);
        _wake(id);
        assertEq(uint8(desk.getMarket(id).outcome), uint8(RitualPredict.Outcome.No));
    }

    function testHttpJamIsNotNo() public {
        StubHttp(RitualChain.HTTP_PRECOMPILE).jam(true);
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 1 ether}(id, true);
        _wake(id);
        assertEq(uint8(desk.getMarket(id).state), uint8(RitualPredict.MarketState.Resolving));
        assertEq(uint8(desk.getMarket(id).outcome), uint8(RitualPredict.Outcome.Unresolved));
    }

    function testBadEnvelopeIsNotNo() public {
        StubHttp(RitualChain.HTTP_PRECOMPILE).forceRaw(hex"abcd");
        uint256 id = _open();
        _wake(id);
        assertEq(uint8(desk.getMarket(id).outcome), uint8(RitualPredict.Outcome.Unresolved));
    }

    function testThreeMissesVoidTheBook() public {
        StubHttp(RitualChain.HTTP_PRECOMPILE).jam(true);
        uint256 id = _open();
        RitualPredict.Market memory m = desk.getMarket(id);
        vm.roll(m.resolveBlock);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 0);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 1);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 2);
        assertEq(uint8(desk.getMarket(id).state), uint8(RitualPredict.MarketState.Invalid));
        assertEq(desk.getMarket(id).attempts, 3);
    }

    function testEmptyWinningSideVoids() public {
        uint256 id = _open();
        vm.prank(leo);
        desk.bet{value: 1 ether}(id, false);
        _wake(id);
        RitualPredict.Market memory m = desk.getMarket(id);
        assertEq(uint8(m.state), uint8(RitualPredict.MarketState.Invalid));
        assertEq(uint8(m.outcome), uint8(RitualPredict.Outcome.Yes));
        assertEq(m.invalidReason, "empty book");
    }

    function testWinnerTakesPool() public {
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 3 ether}(id, true);
        vm.prank(leo);
        desk.bet{value: 1 ether}(id, false);
        _wake(id);
        uint256 before = kay.balance;
        vm.prank(kay);
        desk.claimWinnings(id);
        assertEq(kay.balance - before, 4 ether);
    }

    function testLoserCannotClaim() public {
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 1 ether}(id, true);
        vm.prank(leo);
        desk.bet{value: 1 ether}(id, false);
        _wake(id);
        vm.prank(leo);
        vm.expectRevert(RitualPredict.NothingToClaim.selector);
        desk.claimWinnings(id);
    }

    function testRefundAfterVoid() public {
        StubHttp(RitualChain.HTTP_PRECOMPILE).jam(true);
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 2 ether}(id, true);
        RitualPredict.Market memory m = desk.getMarket(id);
        vm.roll(m.resolveBlock);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 0);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 1);
        StubScheduler(RitualChain.SCHEDULER).kick(m.scheduleId, 2);
        uint256 before = kay.balance;
        vm.prank(kay);
        desk.claimRefund(id);
        assertEq(kay.balance - before, 2 ether);
    }

    function testSecondClaimReverts() public {
        uint256 id = _open();
        vm.prank(kay);
        desk.bet{value: 1 ether}(id, true);
        _wake(id);
        vm.prank(kay);
        desk.claimWinnings(id);
        vm.prank(kay);
        vm.expectRevert(RitualPredict.AlreadySettled.selector);
        desk.claimWinnings(id);
    }

    function testWindowsForMatchesCreate() public {
        (uint64 c, uint64 r) = desk.windowsFor(30, 15);
        uint256 id = _open();
        RitualPredict.Market memory m = desk.getMarket(id);
        assertEq(m.closeBlock, c);
        assertEq(m.resolveBlock, r);
    }

    function testRuleHoldsGte() public view {
        assertTrue(desk.ruleHolds(4000, 4000, RitualPredict.Comparator.GTE));
        assertFalse(desk.ruleHolds(3999, 4000, RitualPredict.Comparator.GTE));
    }

    function testPurseDeposit() public {
        desk.fundExecution{value: 0.4 ether}(80);
        assertEq(desk.executionBalance(), 0.4 ether);
        assertEq(desk.purseLock(), block.number + 80);
    }

    function testLiveMarketsDropsResolved() public {
        uint256 a = _open();
        vm.prank(kay);
        desk.bet{value: 1 ether}(a, true);
        _wake(a);
        _open();
        RitualPredict.Market[] memory live = desk.liveMarkets();
        assertEq(live.length, 1);
        assertEq(live[0].id, 2);
    }

    function testNoTeeIsMiss() public {
        StubRegistry(RitualChain.TEE_SERVICE_REGISTRY).configure(address(0), false);
        uint256 id = _open();
        _wake(id);
        assertEq(uint8(desk.getMarket(id).state), uint8(RitualPredict.MarketState.Resolving));
    }

    function testJqBlankIsMiss() public {
        StubJq(RitualChain.JQ_PRECOMPILE).empty(true);
        uint256 id = _open();
        _wake(id);
        assertEq(uint8(desk.getMarket(id).outcome), uint8(RitualPredict.Outcome.Unresolved));
    }

    function testGtComparator() public {
        RitualPredict.NewMarket memory p = _spec();
        p.comparator = RitualPredict.Comparator.GT;
        p.target = 4100;
        StubJq(RitualChain.JQ_PRECOMPILE).set(4100);
        uint256 id = desk.createMarket(p);
        vm.prank(kay);
        desk.bet{value: 1 ether}(id, true);
        vm.prank(leo);
        desk.bet{value: 1 ether}(id, false);
        _wake(id);
        assertEq(uint8(desk.getMarket(id).outcome), uint8(RitualPredict.Outcome.No));
    }
}
