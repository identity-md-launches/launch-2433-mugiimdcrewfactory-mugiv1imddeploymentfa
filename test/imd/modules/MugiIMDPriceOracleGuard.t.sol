// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Property tests for MugiIMDPriceOracle.settlementPriceValid: it never reverts,
// agrees with consult() when the cutoff is now, is bounded by observed ticks,
// and refuses any series updated after the cutoff.

import {Test} from "forge-std/Test.sol";
import {MugiIMDPriceOracle} from "../../../src/imd/modules/MugiIMDPriceOracle.sol";

contract MugiIMDPriceOracleGuardTest is Test {
    uint64 internal constant START = 1_800_000_000;
    MugiIMDPriceOracle internal prices;

    function setUp() public {
        vm.warp(START);
        prices = new MugiIMDPriceOracle(address(this));
    }

    /// @dev Drives a random update history on crew 0; returns min/max tick and end time.
    function _history(int24[8] memory ticks, uint32[8] memory gaps) internal returns (int24 lo, int24 hi, uint64 time) {
        time = START;
        lo = type(int24).max;
        hi = type(int24).min;
        for (uint256 i; i < 8; ++i) {
            int24 tick = int24(bound(ticks[i], -100_000, 100_000));
            if (tick < lo) lo = tick;
            if (tick > hi) hi = tick;
            prices.update(0, tick);
            time += uint64(bound(gaps[i], 1, 2 hours));
            vm.warp(time);
        }
    }

    function testUpdateIsHookOnlyAndValidatesInputs() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MugiIMDPriceOracle.NotHook.selector);
        prices.update(0, 0);
        vm.expectRevert(MugiIMDPriceOracle.InvalidCrew.selector);
        prices.update(10, 0);
        vm.expectRevert(MugiIMDPriceOracle.InvalidTick.selector);
        prices.update(0, 887_273);
        vm.expectRevert(MugiIMDPriceOracle.InvalidTick.selector);
        prices.update(0, -887_273);
    }

    function testGuardRejectsEdgeInputsWithoutReverting() public {
        // Empty series, cutoff 0, max cutoff, invalid tick, invalid crew.
        assertFalse(prices.settlementPriceValid(0, START, 0));
        prices.update(0, 0);
        vm.warp(START + 1 hours);
        assertFalse(prices.settlementPriceValid(0, 0, 0));
        assertFalse(prices.settlementPriceValid(0, type(uint64).max, 0));
        assertFalse(prices.settlementPriceValid(0, START + 1 hours, 887_273));
        assertFalse(prices.settlementPriceValid(0, START + 1 hours, -887_273));
        assertFalse(prices.settlementPriceValid(255, START + 1 hours, 0));
        // Less than MIN_HISTORY between the only observation and the cutoff.
        assertFalse(prices.settlementPriceValid(0, START + 15 minutes - 1, 0));
        assertTrue(prices.settlementPriceValid(0, START + 15 minutes, 0));
        assertTrue(prices.settlementPriceValid(0, START + 1 hours, 488));
        assertFalse(prices.settlementPriceValid(0, START + 1 hours, 489));
        assertTrue(prices.settlementPriceValid(0, START + 1 hours, -488));
        assertFalse(prices.settlementPriceValid(0, START + 1 hours, -489));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzGuardNeverReverts(
        int24[8] memory ticks,
        uint32[8] memory gaps,
        uint8 crew,
        uint64 cutoff,
        int24 tick
    ) public {
        _history(ticks, gaps);
        // Any crew, cutoff or tick: a boolean, never a revert that would block settlement.
        prices.settlementPriceValid(crew, cutoff, tick);
    }

    /// @dev With the cutoff at `now`, the guard is exactly consult() plus the 488-tick band.
    /// forge-config: default.fuzz.runs = 512
    function testFuzzGuardAtNowMatchesConsultBand(int24[8] memory ticks, uint32[8] memory gaps, int24 spot) public {
        (int24 lo, int24 hi, uint64 time) = _history(ticks, gaps);
        spot = int24(bound(spot, -110_000, 110_000));
        (int24 average,) = prices.consult(0);
        // A time-weighted mean (floored) of observed ticks stays inside their range.
        assertGe(average, lo);
        assertLe(average, hi);
        int256 deviation = int256(spot) - int256(average);
        bool inBand = deviation <= 488 && deviation >= -488;
        assertEq(prices.settlementPriceValid(0, time, spot), inBand);
    }

    /// @dev Any update after the cutoff makes the guard refuse that cutoff.
    /// forge-config: default.fuzz.runs = 256
    function testFuzzPostCutoffUpdateAlwaysRefuses(
        int24[8] memory ticks,
        uint32[8] memory gaps,
        uint32 back,
        int24 spot
    ) public {
        (,, uint64 time) = _history(ticks, gaps);
        prices.update(0, int24(bound(spot, -100_000, 100_000)));
        uint64 cutoff = time - uint64(bound(back, 1, time - START));
        assertFalse(prices.settlementPriceValid(0, cutoff, spot));
        // Other crews are unaffected and still have no history.
        assertFalse(prices.settlementPriceValid(1, cutoff, spot));
    }
}
