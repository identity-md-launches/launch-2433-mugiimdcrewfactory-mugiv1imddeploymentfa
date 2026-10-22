// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzzes the timing of a pre-cutoff pump against the settlement price guard.
// Pumps inside the guard's effective window must defer the matched share and
// leave the attacker with a loss. A pump held 15 minutes or longer before the
// cutoff is NOT deferred and is profitable: that is reported in .imd-findings.json
// rather than asserted here.

import {MugiGameTestBase} from "./MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract MugiSettlementGuardFuzzTest is MugiGameTestBase {
    address internal constant MALLORY = address(0xBADBAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
        vm.deal(MALLORY, 10_000 ether);
    }

    function _pump(uint8 id, uint256 amount) private {
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

    /// forge-config: default.fuzz.runs = 64
    function testFuzzLateLargePumpDefersAndLoses(uint256 lead, uint256 amount) public {
        lead = bound(lead, 1, 13 minutes);
        amount = bound(amount, 100 ether, 1_000 ether);
        for (uint8 round; round < 8; ++round) {
            _round(0);
        }
        vm.warp(game.nextCutoff() - lead);
        uint256 before = MALLORY.balance;
        _pump(9, amount);
        _requestAndFulfill(0);
        assertEq(game.defeatedCrew(), 8);
        uint128 pumped = game.positionLiquidity(9);
        uint256 hookBefore = address(game).balance;
        uint256 reserveBefore = game.unreleasedReserve(9);
        uint256 escrowBefore = game.escrowBacking(9);

        vm.expectEmit(true, false, false, false, address(game));
        emit MugiGameHook.LiquidityDeferred(9, 0);
        game.settleRound(10);

        // Deferred: no deposit, reserve released only for the loser conversion
        // escrow (not for LP), ETH kept by the hook.
        assertEq(game.positionLiquidity(9), pumped, "deposit at pumped price");
        assertEq(
            reserveBefore - game.unreleasedReserve(9),
            game.escrowBacking(9) - escrowBefore,
            "reserve released for a deferred share"
        );
        assertGe(address(game).balance, hookBefore + game.settlementLiquidityEth());
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        _sellAll(9);
        assertLt(MALLORY.balance, before, "pump round trip profitable");
        _assertSolvent();
    }

    /// @dev Below-band pumps are accepted by design (disclosed residual): the share
    /// is deposited, and nothing breaks solvency.
    /// forge-config: default.fuzz.runs = 32
    function testFuzzSmallPumpStillReinforcesAndStaysSolvent(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 1 ether);
        for (uint8 round; round < 8; ++round) {
            _round(0);
        }
        vm.warp(game.nextCutoff() - 1);
        _pump(9, amount);
        _requestAndFulfill(0);
        uint128 before = game.positionLiquidity(9);
        game.settleRound(10);
        assertGt(game.positionLiquidity(9), before);
        _assertSolvent();
    }

    /// @dev Settlement deposits record a post-cutoff observation. Settling in
    /// single-pool batches must still reinforce every unmoved survivor once.
    function testBatchedSettlementReinforcesEachSurvivorOnce() public {
        _requestAndFulfill(0);
        uint128[10] memory before;
        for (uint8 i = 1; i < 10; ++i) {
            before[i] = game.positionLiquidity(i);
        }
        for (uint256 step; step < 10 && game.phase() != MugiGameHook.Phase.Live; ++step) {
            game.settleRound(1);
        }
        assertEq(uint8(game.phase()), uint8(MugiGameHook.Phase.Live));
        for (uint8 i = 1; i < 10; ++i) {
            assertGt(game.positionLiquidity(i), before[i]);
        }
        vm.expectRevert(MugiGameHook.InvalidState.selector);
        game.settleRound(1);
        _assertSolvent();
    }
}
