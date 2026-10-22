// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Settlement matched liquidity must not be priced at a spot that the last
// pre-cutoff trader set and nobody could arbitrage before settlement.

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract MugiSettlementPricingTest is MugiGameTestBase {
    address internal constant MALLORY = address(0xBADBAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
        vm.deal(MALLORY, 10_000 ether);
    }

    function _buy(uint8 id, uint256 amount) private {
        PoolKey memory key = game.poolKey(id);
        vm.prank(MALLORY);
        router.swap{value: amount}(
            key,
            IPoolManager.SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            bytes("")
        );
    }

    function _sellAll(uint8 id) private {
        PoolKey memory key = game.poolKey(id);
        uint256 balance = MugiCrewToken(crew[id]).balanceOf(MALLORY);
        vm.startPrank(MALLORY);
        MugiCrewToken(crew[id]).approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams(false, -int256(balance), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            bytes("")
        );
        vm.stopPrank();
    }

    /// @dev Reviewer reproduction: crews 0..7 eliminated, a 300 ETH pump of crew 9
    /// one second before the cutoff, crew 8 eliminated. Before the fix the matched
    /// 117.46 ETH entered crew 9 at the pumped price and the round trip gained 19.06 ETH.
    function testLastSecondPumpDefersMatchedLiquidityAndRoundTripLoses() public {
        for (uint8 round; round < 8; ++round) {
            _round(0);
        }
        vm.warp(game.nextCutoff() - 1);
        uint256 before = MALLORY.balance;
        _buy(9, 300 ether);
        _requestAndFulfill(0);
        assertEq(game.defeatedCrew(), 8);
        uint128 pumpedLiquidity = game.positionLiquidity(9);
        uint256 hookBefore = address(game).balance;

        vm.expectEmit(true, false, false, false, address(game));
        emit MugiGameHook.LiquidityDeferred(9, 0);
        game.settleRound(10);

        uint256 matched = game.settlementLiquidityEth();
        assertGt(matched, 0);
        assertEq(game.positionLiquidity(9), pumpedLiquidity);
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        assertGe(address(game).balance, hookBefore + matched);
        _sellAll(9);
        assertLt(MALLORY.balance, before);
        _assertSolvent();
    }

    /// @dev Follow-up reviewer reproduction (cbd2b1fb): the same pump 16 minutes before the
    /// cutoff became the start of the old 15-minute window, so its mean equalled the pumped
    /// spot and crew-9 liquidity rose to 27991789041817648579719 (+19.06 ETH round trip).
    /// The round-long reference defers it, and so does a pump held for half the round.
    function testPumpHeldBeforeFifteenMinuteTailStillDefers() public {
        for (uint8 round; round < 8; ++round) {
            _round(0);
        }
        uint256 snapshot = vm.snapshotState();
        uint32[2] memory heldFor = [uint32(16 minutes), uint32(12 hours)];
        for (uint256 i; i < heldFor.length; ++i) {
            vm.revertToState(snapshot);
            vm.warp(game.nextCutoff() - heldFor[i]);
            uint256 before = MALLORY.balance;
            _buy(9, 300 ether);
            _requestAndFulfill(0);
            assertEq(game.defeatedCrew(), 8);
            uint128 pumpedLiquidity = game.positionLiquidity(9);
            assertEq(pumpedLiquidity, 22898085733661968682982);

            vm.expectEmit(true, false, false, false, address(game));
            emit MugiGameHook.LiquidityDeferred(9, 0);
            game.settleRound(10);

            assertEq(game.positionLiquidity(9), pumpedLiquidity);
            _sellAll(9);
            assertLt(MALLORY.balance, before);
            _assertSolvent();
        }
    }

    /// @dev The same pump settled into a crew whose price did not move still reinforces.
    function testUnmovedSurvivorStillReceivesMatchedLiquidity() public {
        for (uint8 round; round < 8; ++round) {
            _round(0);
        }
        vm.warp(game.nextCutoff() - 1);
        _buy(9, 300 ether);
        _requestAndFulfill(1);
        assertEq(game.defeatedCrew(), 9);
        uint128 beforeLiquidity = game.positionLiquidity(8);
        game.settleRound(10);
        assertGt(game.positionLiquidity(8), beforeLiquidity);
        _assertSolvent();
    }

    /// @dev Ordinary rounds with trading well before the cutoff reinforce every survivor.
    function testOrdinaryTradingKeepsSettlementReinforcement() public {
        _swap(ALICE, 3, true, -int256(5 ether));
        _requestAndFulfill(0);
        uint128[10] memory beforeLiquidity;
        for (uint8 i = 1; i < 10; ++i) {
            beforeLiquidity[i] = game.positionLiquidity(i);
        }
        game.settleRound(10);
        for (uint8 i = 1; i < 10; ++i) {
            assertGt(game.positionLiquidity(i), beforeLiquidity[i]);
        }
        _assertSolvent();
    }
}
