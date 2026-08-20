// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// In-process stand-ins. Tests etch runtime code onto canonical Ritual addresses.

contract StubScheduler {
    struct Job {
        bytes payload;
        address target;
        bool dead;
    }

    uint256 public cursor;
    mapping(uint256 => Job) public jobs;

    function approveScheduler(address) external {}

    function schedule(
        bytes calldata payload,
        uint32,
        uint32,
        uint32,
        uint32,
        uint32,
        uint256,
        uint256,
        uint256,
        address
    ) external returns (uint256 id) {
        if (cursor == 0) cursor = 1;
        id = cursor++;
        jobs[id] = Job({payload: payload, target: msg.sender, dead: false});
    }

    function cancel(uint256 id) external {
        jobs[id].dead = true;
    }

    function getCallState(uint256 id) external view returns (uint8) {
        if (jobs[id].target == address(0)) return 4;
        if (jobs[id].dead) return 3;
        return 0;
    }

    function kick(uint256 id, uint256 executionIndex) external {
        Job storage j = jobs[id];
        require(j.target != address(0), "no job");
        bytes memory p = j.payload;
        require(p.length >= 36, "short");
        assembly {
            mstore(add(p, 36), executionIndex)
        }
        (bool ok, ) = j.target.call(p);
        require(ok, "kick failed");
    }
}

contract StubPurse {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockUntil;

    function deposit(uint256 lock) external payable {
        balanceOf[msg.sender] += msg.value;
        uint256 until = block.number + lock;
        if (until > lockUntil[msg.sender]) lockUntil[msg.sender] = until;
    }
}

contract StubRegistry {
    address public tee;
    bool public present = true;
    bool public boom;

    function configure(address tee_, bool present_) external {
        tee = tee_;
        present = present_;
    }

    function jam(bool v) external {
        boom = v;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256,
        uint256
    ) external view returns (address, bool) {
        if (boom) revert("jammed");
        return (tee, present);
    }
}

contract StubHttp {
    bool public boom;
    uint16 public code = 200;
    bytes public body = '{"price":4100}';
    string public note = "";
    bytes public raw;
    bool public useRaw;

    function tune(uint16 code_, bytes calldata body_, string calldata note_) external {
        boom = false;
        useRaw = false;
        code = code_;
        body = body_;
        note = note_;
    }

    function jam(bool v) external {
        boom = v;
    }

    function forceRaw(bytes calldata raw_) external {
        useRaw = true;
        raw = raw_;
        boom = false;
    }

    fallback() external {
        if (boom) revert();
        bytes memory out = useRaw
            ? raw
            : abi.encode(
                bytes(""),
                abi.encode(code, new string[](0), new string[](0), body, note)
            );
        assembly {
            return(add(out, 32), mload(out))
        }
    }
}

contract StubJq {
    bool public boom;
    bool public blank;
    uint256 public n;

    function set(uint256 v) external {
        boom = false;
        blank = false;
        n = v;
    }

    function jam(bool v) external {
        boom = v;
    }

    function empty(bool v) external {
        blank = v;
    }

    fallback() external {
        if (boom) revert();
        if (blank) {
            assembly {
                return(0, 0)
            }
        }
        uint256 v = n;
        assembly {
            mstore(0x00, v)
            return(0x00, 32)
        }
    }
}
