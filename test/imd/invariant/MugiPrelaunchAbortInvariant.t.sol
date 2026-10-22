// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Stateful invariants for the prelaunch window: random owner seeding, stranger
// attempts, launch attempts and abortPrelaunch. Seeded ETH is conserved and
// returned to the owner on abort; an aborted season retires every reserve and
// LP token it held and never reopens; abort is impossible after launch.

import {Test} from "forge-std/Test.sol";
import {MugiGameTestBase} from "../lifecycle/MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

interface IPrelaunchOwner {
    function ownerSeed(uint8 crew, uint256 amount) external;
    function ownerAbort() external;
}

contract MugiPrelaunchHandler is Test {
    MugiGameHook internal immutable game;
    IPrelaunchOwner internal immutable owner;
    address[10] internal crew;

    uint256 public seededEth;
    uint256 public refundedEth;
    uint16 public seededMask;
    bool public aborted;
    bool public launched;
    bool public strangerSucceeded;
    bool public reopened;
    mapping(bytes32 => uint256) public successes;

    constructor(MugiGameHook game_, IPrelaunchOwner owner_) {
        game = game_;
        owner = owner_;
        for (uint8 i; i < 10; ++i) {
            crew[i] = game_.tokens(i);
        }
    }

    function seed(uint256 crewSeed, uint256 amount) external {
        uint8 id = uint8(crewSeed % 10);
        amount = bound(amount, 1, 50 ether);
        bool expectOk = !aborted && !launched && (seededMask & (uint16(1) << id)) == 0;
        try owner.ownerSeed(id, amount) {
            if (!expectOk) reopened = true;
            seededEth += amount;
            seededMask |= uint16(1) << id;
            ++successes["seed"];
        } catch {
            // Only a reseed, a closed season or a too-small amount may fail.
        }
        assertEq(game.seededMask(), seededMask, "seeded mask drift");
    }

    function seedAll(uint256 amount) external {
        for (uint256 i; i < 10; ++i) {
            this.seed(i, amount);
        }
    }

    function abort(uint256 gate) external {
        // Rare, so most sequences seed pools (or launch) before closing.
        if (gate % 4 != 0) return;
        bool wasSetup = game.phase() == MugiGameHook.Phase.Setup;
        uint256 before = address(owner).balance;
        try owner.ownerAbort() {
            assertTrue(wasSetup, "abort outside Setup");
            aborted = true;
            refundedEth += address(owner).balance - before;
            ++successes["abort"];
        } catch {
            assertFalse(wasSetup, "owner abort failed in Setup");
        }
    }

    function strangerActions(uint256 who, uint256 crewSeed) external {
        // Hashed so a stranger is never the hook, the engine or another graph address.
        address stranger = address(uint160(uint256(keccak256(abi.encode("stranger", who)))));
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        try game.abortPrelaunch() {
            strangerSucceeded = true;
        } catch {}
        try game.seedPool{value: 1 ether}(uint8(crewSeed % 10)) {
            strangerSucceeded = true;
        } catch {}
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
    }

    function tryLaunch() external {
        try game.launch() {
            assertFalse(aborted, "launch after abort");
            assertEq(seededMask, 1023, "launch with an unseeded pool");
            launched = true;
            ++successes["launch"];
        } catch {}
    }
}

contract MugiPrelaunchAbortInvariantTest is MugiGameTestBase {
    MugiGameHook internal prelaunch;
    address[10] internal prelaunchCrew;
    MugiPrelaunchHandler internal handler;
    uint256 internal ownerStart;

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        vm.deal(address(this), 1_000 ether);
        ownerStart = address(this).balance;
        (prelaunch, prelaunchCrew,) = _deployGameAt(address(uint160(0x1236000000) | uint160(0x2aec)), SUPPLY, manager);
        airdrop = prelaunch.airdrop();
        handler = new MugiPrelaunchHandler(prelaunch, IPrelaunchOwner(address(this)));
        targetContract(address(handler));
    }

    function ownerSeed(uint8 id, uint256 amount) external {
        require(msg.sender == address(handler), "handler only");
        prelaunch.seedPool{value: amount}(id);
    }

    function ownerAbort() external {
        require(msg.sender == address(handler), "handler only");
        prelaunch.abortPrelaunch();
    }

    function afterInvariant() public {
        emit log_named_uint("seeds", handler.successes("seed"));
        emit log_named_uint("aborts", handler.successes("abort"));
        emit log_named_uint("launches", handler.successes("launch"));
    }

    function _checkAll() private view {
        invariant_seededEthIsConservedAndRefundedOnAbort();
        invariant_abortRetiresReserveAndSupplyIsFinite();
        invariant_closedSeasonNeverReopensAndStrangersHaveNoPower();
    }

    /// @dev Pinned sequence: partial seeding, stranger attempts, abort, then retries.
    function testPartialSeedAbortRetiresAndRefunds() public {
        handler.seed(2, 7 ether);
        handler.seed(5, 1 ether);
        handler.seed(5, 3 ether); // reseed refused
        handler.strangerActions(1, 2);
        _checkAll();
        handler.abort(0);
        assertTrue(handler.aborted());
        // The airdrop's 5% plus at most one wei of LP rounding dust.
        assertApproxEqAbs(MugiCrewToken(prelaunchCrew[2]).totalSupply(), SUPPLY / 20, 1);
        assertEq(MugiCrewToken(prelaunchCrew[0]).totalSupply(), 0);
        handler.seed(0, 1 ether);
        handler.abort(0);
        handler.tryLaunch();
        _checkAll();
        vm.prank(address(handler));
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        this.ownerAbort();
    }

    /// @dev Pinned sequence: all ten seeded, launch after seven days, abort refused.
    function testLaunchedSeasonCannotAbort() public {
        handler.seedAll(3 ether);
        vm.warp(uint256(prelaunch.configuredAt()) + 7 days);
        handler.tryLaunch();
        assertTrue(handler.launched());
        uint256 ownerBefore = address(this).balance;
        handler.abort(0);
        assertFalse(handler.aborted());
        assertEq(address(this).balance, ownerBefore);
        vm.prank(address(handler));
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        this.ownerAbort();
        _checkAll();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_seededEthIsConservedAndRefundedOnAbort() public view {
        uint256 held = address(manager).balance + address(prelaunch).balance + address(prelaunch.engine()).balance;
        // Every wei the owner seeded is either in the pools/hook or refunded.
        assertEq(address(this).balance + held, ownerStart, "ETH created or lost");
        assertEq(handler.seededEth() - handler.refundedEth(), held, "seeded ETH not accounted");
        if (handler.aborted()) {
            assertEq(address(prelaunch).balance, 0, "hook kept ETH after abort");
            // Full-range LP removal may round away at most a few wei per pool.
            assertLe(held, 10, "abort did not refund the seeded ETH");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_abortRetiresReserveAndSupplyIsFinite() public view {
        for (uint8 i; i < 10; ++i) {
            MugiCrewToken token = MugiCrewToken(prelaunchCrew[i]);
            bool seeded = (handler.seededMask() & (uint16(1) << i)) != 0;
            uint256 supply = token.totalSupply();
            assertLe(supply, token.reserveCap(), "supply above the constructor reserve");
            uint256 held = token.balanceOf(address(prelaunch)) + token.balanceOf(address(airdrop))
                + token.balanceOf(address(manager)) + token.balanceOf(address(prelaunch.engine()));
            assertEq(held, supply, "supply outside the prelaunch graph");
            if (handler.aborted()) {
                assertEq(prelaunch.unreleasedReserve(i), 0, "aborted season keeps reserve");
                assertEq(token.balanceOf(address(prelaunch)), 0, "aborted hook keeps tokens");
                // Only the airdrop's undistributed 5% (disclosed) survives, plus LP rounding dust.
                assertEq(token.balanceOf(address(airdrop)), seeded ? SUPPLY / 20 : 0);
                assertLe(supply - token.balanceOf(address(airdrop)), 1, "LP tokens not retired");
            } else {
                assertEq(supply, token.reserveCap(), "supply burned before close");
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_closedSeasonNeverReopensAndStrangersHaveNoPower() public view {
        assertFalse(handler.strangerSucceeded(), "stranger seeded or aborted");
        assertFalse(handler.reopened(), "seeding after close or reseed");
        assertFalse(handler.aborted() && handler.launched(), "both aborted and launched");
        MugiGameHook.Phase phase = prelaunch.phase();
        if (handler.aborted()) assertEq(uint8(phase), uint8(MugiGameHook.Phase.Aborted));
        else if (handler.launched()) assertEq(uint8(phase), uint8(MugiGameHook.Phase.Live));
        else assertEq(uint8(phase), uint8(MugiGameHook.Phase.Setup));
    }
}
