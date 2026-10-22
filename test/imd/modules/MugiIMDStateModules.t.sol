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
