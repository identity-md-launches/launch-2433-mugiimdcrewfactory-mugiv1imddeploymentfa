// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiIMDBuybacks, IMugiIMDBuybackPlanVerifier} from "../../../src/imd/modules/MugiIMDBuybacks.sol";
import {MugiIMDPriceOracle} from "../../../src/imd/modules/MugiIMDPriceOracle.sol";

contract MugiIMDModuleVerifier is IMugiIMDBuybackPlanVerifier {
    address public immutable hook;
    address public immutable module;
    bytes32 public immutable expectedHash;

    constructor(address hook_, address module_, bytes32 hash_) {
        hook = hook_;
        module = module_;
        expectedHash = hash_;
    }

    function verify(bytes32 planHash, bytes calldata proof, address consumer) external view returns (bool) {
        return consumer == hook && msg.sender == module && planHash == expectedHash
            && keccak256(proof) == keccak256(hex"1234");
    }
}

contract MugiIMDStateModulesTest is Test {
    MugiIMDBuybacks internal budgets;
    MugiIMDPriceOracle internal prices;

    function setUp() public {
        vm.warp(1 days);
        budgets = new MugiIMDBuybacks(address(this));
        prices = new MugiIMDPriceOracle(address(this));
    }

    function testConstructorsAcceptCounterfactualHookAndRejectZero() public {
        address futureHook = address(0x123456);
        assertEq(futureHook.code.length, 0);
        assertEq(new MugiIMDBuybacks(futureHook).hook(), futureHook);
        assertEq(new MugiIMDPriceOracle(futureHook).hook(), futureHook);
        vm.expectRevert(MugiIMDBuybacks.InvalidHook.selector);
        new MugiIMDBuybacks(address(0));
        vm.expectRevert(MugiIMDPriceOracle.InvalidHook.selector);
        new MugiIMDPriceOracle(address(0));
    }

    function testAllBudgetMutatorsRequireHook() public {
        MugiIMDBuybacks.BuybackPlan memory plan;
        vm.startPrank(address(0xBAD));
        vm.expectRevert(MugiIMDBuybacks.NotHook.selector);
        budgets.create(1, 100 ether, 3);
        vm.expectRevert(MugiIMDBuybacks.NotHook.selector);
        budgets.approve(plan, address(1), "");
        vm.expectRevert(MugiIMDBuybacks.NotHook.selector);
        budgets.authorize(1, 0, 5 ether);
        vm.expectRevert(MugiIMDBuybacks.NotHook.selector);
        budgets.account(1, 0, 5 ether);
        vm.stopPrank();
    }

    function testApprovalUsesHookHashDomainAndConsumerThroughOrdinaryCall() public {
        budgets.create(1, 100 ether, 3);
        MugiIMDBuybacks.BuybackPlan memory plan;
        plan.roundId = 1;
        plan.nonce = 1;
        plan.deadline = uint64(block.timestamp + 1 hours);
        plan.allocations[0] = 50 ether;
        plan.allocations[1] = 50 ether;
        bytes32 expected = keccak256(
            abi.encode(block.chainid, address(this), plan.roundId, plan.nonce, plan.deadline, plan.allocations)
        );
        assertEq(budgets.hash(plan), expected);
        assertNotEq(
            expected,
            keccak256(
                abi.encode(block.chainid, address(budgets), plan.roundId, plan.nonce, plan.deadline, plan.allocations)
            )
        );
        MugiIMDModuleVerifier verifier = new MugiIMDModuleVerifier(address(this), address(budgets), expected);
        budgets.approve(plan, address(verifier), hex"1234");
        MugiIMDBuybacks.Budget memory b = budgets.roundBudget(1);
        assertEq(b.nonce, 1);
        assertEq(b.planValidUntil, plan.deadline);
        assertEq(b.allocation[0], 50 ether);
    }

    function testBudgetAuthorizesAccountsAndPreservesTradeCadence() public {
        budgets.create(1, 100 ether, 3);
        budgets.authorize(1, 0, 5 ether);
        MugiIMDBuybacks.Budget memory b = budgets.roundBudget(1);
        assertTrue(b.authorizationPending);
        assertEq(b.authorizedAmount, 5 ether);
        assertEq(b.spent, 0);
        vm.expectRevert(MugiIMDBuybacks.InvalidExecution.selector);
        budgets.authorize(1, 1, 5 ether);
        vm.expectRevert(MugiIMDBuybacks.InvalidExecution.selector);
        budgets.account(1, 1, 4 ether);
        budgets.account(1, 0, 4 ether);
        b = budgets.roundBudget(1);
        assertFalse(b.authorizationPending);
        assertEq(b.spent, 4 ether);
        assertEq(b.crewSpent[0], 4 ether);
        vm.expectRevert(MugiIMDBuybacks.InvalidExecution.selector);
        budgets.authorize(1, 0, 5 ether);
        vm.warp(block.timestamp + 5 minutes);
        budgets.authorize(1, 0, 5 ether);
        budgets.account(1, 0, 5 ether);
        assertEq(budgets.roundBudget(1).spent, 9 ether);
    }

    function testOracleOnlyHookCanUpdateButAnyoneCanRead() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MugiIMDPriceOracle.NotHook.selector);
        prices.update(0, 0);
        prices.update(0, 0);
        vm.warp(block.timestamp + 15 minutes);
        vm.startPrank(address(0xBAD));
        assertEq(prices.observationCount(0), 1);
        (int24 tick, uint32 age) = prices.consult(0);
        assertEq(tick, 0);
        assertEq(age, 15 minutes);
        (uint256 minimum, uint160 limit) = prices.quoteMinimum(0, 1 ether, 0);
        assertEq(minimum, 96709 * 1e13);
        assertLt(limit, uint160(1 << 96));
        vm.stopPrank();
    }

    function testOracleRequiresHistoryAndRejectsSpotDeviation() public {
        prices.update(0, 0);
        prices.update(0, 100);
        assertEq(prices.observationCount(0), 1);
        vm.expectRevert(MugiIMDPriceOracle.InsufficientHistory.selector);
        prices.quoteMinimum(0, 1 ether, 100);
        vm.warp(block.timestamp + 15 minutes);
        vm.expectRevert(MugiIMDPriceOracle.SpotDeviation.selector);
        prices.quoteMinimum(0, 1 ether, 600);
    }

    /// @dev Settlement guard: TWAP ends at the cutoff, never reverts, and rejects
    /// missing history, future cutoffs and series already updated after the cutoff.
    function testSettlementPriceGuardUsesTwapEndingAtCutoff() public {
        // Absolute times: via-IR may reuse an earlier block.timestamp read after a warp.
        uint64 cutoff = 1 days + 30 minutes;
        assertFalse(prices.settlementPriceValid(0, 1 days, 0));
        prices.update(0, 0);
        // A last-second move to tick 2000 adds one second of weight before the cutoff.
        vm.warp(cutoff - 1);
        prices.update(0, 2000);
        vm.warp(cutoff + 6 hours);
        assertFalse(prices.settlementPriceValid(0, cutoff, 2000));
        // Mean over the 30 minutes ending at the cutoff is floor(2000 / 1800) = 1.
        assertTrue(prices.settlementPriceValid(0, cutoff, 489));
        assertFalse(prices.settlementPriceValid(0, cutoff, 490));
        assertTrue(prices.settlementPriceValid(0, cutoff, -487));
        assertFalse(prices.settlementPriceValid(0, cutoff, -488));
        assertFalse(prices.settlementPriceValid(0, cutoff + 6 hours + 1, 0));
        assertFalse(prices.settlementPriceValid(10, cutoff, 0));
        assertFalse(prices.settlementPriceValid(1, cutoff, 0));
        prices.update(0, 2000);
        assertFalse(prices.settlementPriceValid(0, cutoff, 0));
    }

    // Round-long settlement reference. Cutoff C is 20 minutes past an hour, so the window
    // runs from the hour boundary GS = C - 1 day - 20 minutes to C (87,600 seconds).
    uint64 internal constant GS = 10 days;
    uint64 internal constant C = GS + 1 days + 20 minutes;

    /// @dev Reviewer finding cbd2b1fb: a pump 16 minutes before the cutoff equalled the old
    /// 15-minute mean. Over the round it weighs 960/87600 seconds. Only a tick held across
    /// the whole window passes (disclosed residual).
    function testSettlementGuardAveragesWholeRoundNotFifteenMinuteTail() public {
        vm.warp(GS - 5 hours);
        prices.update(1, 0);
        prices.update(2, 0);
        prices.update(3, 0);
        vm.warp(GS - 1 hours);
        prices.update(2, 2000);
        vm.warp(C - 12 hours);
        prices.update(3, 2000);
        vm.warp(C - 16 minutes);
        prices.update(1, 2000);
        vm.warp(C + 1 hours);
        // floor(2000 * 960 / 87600) = 21.
        assertFalse(prices.settlementPriceValid(1, C, 2000));
        assertTrue(prices.settlementPriceValid(1, C, 21 + 488));
        assertFalse(prices.settlementPriceValid(1, C, 21 + 489));
        // floor(2000 * 43200 / 87600) = 986.
        assertFalse(prices.settlementPriceValid(3, C, 2000));
        assertTrue(prices.settlementPriceValid(3, C, 986 + 488));
        assertFalse(prices.settlementPriceValid(3, C, 986 + 489));
        assertTrue(prices.settlementPriceValid(2, C, 2000));
    }

    /// @dev The first update after GS lands in the next hour; its checkpoint is projected back
    /// to GS with the tick that held across it. A series starting inside the window uses its
    /// first update; a quiet series ignores a stale checkpoint 32 hours older sharing a slot.
    function testSettlementGuardRoundMeanIsExact() public {
        uint64 stale = (GS / 1 hours + 5 - 32) * 1 hours + 100;
        vm.warp(stale);
        prices.update(6, -700);
        vm.warp(GS - 5 hours);
        prices.update(0, 1000);
        vm.warp(GS + 90 minutes);
        prices.update(0, 0);
        vm.warp(C - 20 hours);
        prices.update(5, 500);
        vm.warp(C - 6 hours);
        prices.update(0, 4000);
        vm.warp(C + 1 hours);
        // (1000 * 5400 + 4000 * 21600) / 87600 = 1047.9 -> 1047.
        assertTrue(prices.settlementPriceValid(0, C, 1047 + 488));
        assertFalse(prices.settlementPriceValid(0, C, 1047 + 489));
        assertTrue(prices.settlementPriceValid(0, C, 1047 - 488));
        assertFalse(prices.settlementPriceValid(0, C, 1047 - 489));
        assertTrue(prices.settlementPriceValid(5, C, 500 + 488));
        assertFalse(prices.settlementPriceValid(5, C, 500 + 489));
        assertTrue(prices.settlementPriceValid(5, C, 500 - 488));
        assertFalse(prices.settlementPriceValid(5, C, 500 - 489));
        assertTrue(prices.settlementPriceValid(6, C, -700 - 488));
        assertFalse(prices.settlementPriceValid(6, C, -700 - 489));
        assertTrue(prices.settlementPriceValid(6, C, -700 + 488));
        assertFalse(prices.settlementPriceValid(6, C, -700 + 489));
    }

    /// @dev Swap spam refills the 128-entry observation ring after a pump, but cannot evict
    /// the hourly checkpoint at the start of the round.
    function testSettlementGuardCheckpointsSurviveObservationSpam() public {
        vm.warp(GS - 5 hours);
        prices.update(4, 0);
        uint64 pumpedAt = C - 4 hours;
        for (uint64 i; i <= 200; ++i) {
            vm.warp(pumpedAt + i * 61);
            prices.update(4, 2000);
        }
        assertEq(prices.observationCount(4), 128);
        vm.warp(C + 1 hours);
        // floor(2000 * 14400 / 87600) = 328.
        assertFalse(prices.settlementPriceValid(4, C, 2000));
        assertTrue(prices.settlementPriceValid(4, C, 328 + 488));
        assertFalse(prices.settlementPriceValid(4, C, 328 + 489));
    }

    function testOracleNegativeMeanRoundsDown() public {
        prices.update(0, -2);
        vm.warp(1 days + 10 minutes);
        prices.update(0, -1);
        vm.warp(1 days + 20 minutes);
        (int24 average, uint32 age) = prices.consult(0);
        assertEq(average, -2);
        assertEq(age, 20 minutes);
    }
}
