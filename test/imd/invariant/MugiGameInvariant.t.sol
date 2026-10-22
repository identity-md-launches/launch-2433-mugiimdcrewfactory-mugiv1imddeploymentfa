// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Stateful invariant suite over the whole value-holding V1 game: the hook, its
// engine/ledger/budget modules, the ten crew tokens, a real v4 PoolManager and
// the production MugiIMDSwapRouter. A handler drives player trades, wallet
// transfers, burns, claims, buybacks, fee collection, VRF rounds, settlement,
// stalled-randomness recovery, finale, V2 handoff and expiry in random order.

import {Test} from "forge-std/Test.sol";
import {MugiGameTestBase, GameRandomnessMock} from "../lifecycle/MugiGameHook.t.sol";
import {MugiIMDGameHook as MugiGameHook} from "../../../src/imd/MugiIMDGameHook.sol";
import {MugiIMDSwapRouter} from "../../../src/imd/MugiIMDSwapRouter.sol";
import {MugiCrewToken} from "../../../src/game/MugiCrewToken.sol";
import {MugiIMDBuybacks as MugiBuybacks} from "../../../src/imd/modules/MugiIMDBuybacks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";

interface IOwnerHarness {
    function ownerMigrate() external;
}

contract MugiGameHandler is Test {
    MugiGameHook internal immutable game;
    MugiIMDSwapRouter internal immutable router;
    GameRandomnessMock internal immutable randomness;
    address internal immutable ownerHarness;
    address[5] internal actors;
    address[10] internal crew;

    // Ghosts checked by the invariants.
    uint256[10] public lastSupply;
    bool public supplyIncreased;
    bool public terminalReopened;
    bool public eliminationsDecreased;
    bool public migrationOutsideFinale;
    uint8 public lastEliminations;
    uint8 public lastPhase;
    uint256 public ethPaidToActors;
    uint256 public ethPaidByActors;
    mapping(bytes32 => uint256) public calls;
    mapping(bytes32 => uint256) public successes;

    constructor(
        MugiGameHook game_,
        MugiIMDSwapRouter router_,
        GameRandomnessMock randomness_,
        address[5] memory actors_
    ) {
        game = game_;
        router = router_;
        randomness = randomness_;
        ownerHarness = msg.sender;
        actors = actors_;
        for (uint8 i; i < 10; ++i) {
            crew[i] = game_.tokens(i);
            lastSupply[i] = MugiCrewToken(crew[i]).totalSupply();
        }
        lastPhase = uint8(game_.phase());
    }

    modifier track(bytes32 name) {
        _;
        _afterCall(name);
    }

    function _afterCall(bytes32 name) private {
        ++calls[name];
        for (uint8 i; i < 10; ++i) {
            uint256 supply = MugiCrewToken(crew[i]).totalSupply();
            if (supply > lastSupply[i]) supplyIncreased = true;
            lastSupply[i] = supply;
        }
        uint8 phase = uint8(game.phase());
        bool wasTerminal = lastPhase == uint8(MugiGameHook.Phase.Finalized)
            || lastPhase == uint8(MugiGameHook.Phase.EmergencyClosed) || lastPhase == uint8(MugiGameHook.Phase.Aborted);
        if (wasTerminal && phase != lastPhase) terminalReopened = true;
        lastPhase = phase;
        if (game.eliminations() < lastEliminations) eliminationsDecreased = true;
        lastEliminations = game.eliminations();
        if (game.migrated() && game.phase() != MugiGameHook.Phase.Finalized) migrationOutsideFinale = true;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _crew(uint256 seed) private pure returns (uint8) {
        return uint8(seed % 10);
    }

    function _now() private view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function buy(uint256 actorSeed, uint256 crewSeed, uint256 amount) external track("buy") {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1e12, 5 ether);
        vm.deal(actor, actor.balance + amount);
        uint256 before = actor.balance;
        vm.prank(actor);
        try router.buy{value: amount}(_crew(crewSeed), 0, uint64(_now())) {
            ethPaidByActors += before - actor.balance;
            ++successes["buy"];
        } catch {}
    }

    function sell(uint256 actorSeed, uint256 crewSeed, uint256 amount) external track("sell") {
        address actor = _actor(actorSeed);
        uint8 id = _crew(crewSeed);
        uint256 balance = MugiCrewToken(crew[id]).balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.startPrank(actor);
        MugiCrewToken(crew[id]).approve(address(router), amount);
        uint256 before = actor.balance;
        try router.sell(id, amount, 0, uint64(_now())) returns (uint256 out) {
            assertEq(actor.balance - before, out, "router pays exactly the reported ETH");
            ethPaidToActors += out;
            ++successes["sell"];
        } catch {}
        vm.stopPrank();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 crewSeed, uint256 amount) external track("transfer") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint8 id = _crew(crewSeed);
        uint256 balance = MugiCrewToken(crew[id]).balanceOf(from);
        amount = bound(amount, 0, balance);
        uint256 toBefore = MugiCrewToken(crew[id]).balanceOf(to);
        // Tokens transfer freely at all times: no phase, cutoff or elimination gate.
        vm.prank(from);
        MugiCrewToken(crew[id]).transfer(to, amount);
        if (from != to) assertEq(MugiCrewToken(crew[id]).balanceOf(to), toBefore + amount);
    }

    function burn(uint256 actorSeed, uint256 crewSeed, uint256 amount) external track("burn") {
        address actor = _actor(actorSeed);
        uint8 id = _crew(crewSeed);
        uint256 balance = MugiCrewToken(crew[id]).balanceOf(actor);
        amount = bound(amount, 0, balance);
        uint256 hookBefore = MugiCrewToken(crew[id]).balanceOf(address(game));
        vm.prank(actor);
        MugiCrewToken(crew[id]).burn(amount);
        assertEq(MugiCrewToken(crew[id]).balanceOf(address(game)), hookBefore, "burn touches only the caller");
    }

    function claimEth(uint256 actorSeed) external track("claimEth") {
        address actor = _actor(actorSeed);
        uint256 before = actor.balance;
        vm.prank(actor);
        try game.claimEth(payable(actor)) returns (uint256 amount) {
            assertEq(actor.balance - before, amount);
            ethPaidToActors += amount;
            if (amount != 0) ++successes["claimEth"];
            // A second claim in the same state yields nothing more.
            vm.prank(actor);
            try game.claimEth(payable(actor)) returns (uint256 again) {
                assertEq(again, 0, "double ETH claim");
            } catch {}
        } catch {}
    }

    function claimTokens(uint256 actorSeed) external track("claimTokens") {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try game.claimTokens() returns (uint256[10] memory got) {
            for (uint8 i; i < 10; ++i) {
                if (got[i] != 0) {
                    ++successes["claimTokens"];
                    break;
                }
            }
            vm.prank(actor);
            try game.claimTokens() returns (uint256[10] memory again) {
                for (uint8 i; i < 10; ++i) {
                    assertEq(again[i], 0, "double token claim");
                }
            } catch {}
        } catch {}
    }

    function ownBuyback(uint256 crewSeed, uint256 callerSeed) external track("ownBuyback") {
        uint8 id = _crew(crewSeed);
        uint256 budget = game.ownBurnBudget(id);
        if (budget == 0) return;
        uint256 amount = (budget + 19) / 20;
        uint256 supplyBefore = MugiCrewToken(crew[id]).totalSupply();
        vm.prank(_actor(callerSeed));
        try game.executeOwnBuyback(id, amount) {
            assertLe(budget - game.ownBurnBudget(id), amount, "own buyback overspent its slice");
            assertLe(MugiCrewToken(crew[id]).totalSupply(), supplyBefore);
            ++successes["ownBuyback"];
        } catch {}
    }

    function collectTeamFees(uint256 crewSeed) external track("collectTeamFees") {
        try game.collectTeamFees(_crew(crewSeed)) {} catch {}
    }

    function withdrawTeamFees() external track("withdrawTeamFees") {
        try game.withdrawTeamFees() {
            assertEq(game.teamEth(), 0);
            for (uint8 i; i < 10; ++i) {
                assertEq(game.teamTokens(i), 0);
            }
        } catch {}
    }

    function retireAirdrop() external track("retireAirdrop") {
        try game.retireAirdrop() {} catch {}
    }

    function warp(uint256 seconds_) external track("warp") {
        vm.warp(_now() + bound(seconds_, 1, 2 hours));
    }

    /// @dev Drives the next step of the season clock: request + fulfil at the
    /// cutoff, bounded settlement, or the finale after nine eliminations.
    function advance(uint256 word, uint256 batch) external track("advance") {
        MugiGameHook.Phase phase = game.phase();
        if (phase == MugiGameHook.Phase.Live) {
            if (_now() < game.nextCutoff()) vm.warp(game.nextCutoff());
            if (game.eliminations() == 9) {
                try game.finalize() {
                    ++successes["finalize"];
                } catch {}
                return;
            }
            try game.requestElimination() {
                uint16 aliveBefore = game.aliveMask();
                randomness.fulfill(game.pendingRequest(), word);
                if (game.phase() == MugiGameHook.Phase.OutcomeReady) {
                    assertTrue((aliveBefore & (uint16(1) << game.defeatedCrew())) != 0, "loser must be alive");
                }
            } catch {}
            phase = game.phase();
        }
        if (phase == MugiGameHook.Phase.OutcomeReady || phase == MugiGameHook.Phase.Settling) {
            uint8 before = game.eliminations();
            // Odd batches settle in one call; even batches leave partial progress.
            game.settleRound(batch % 2 == 1 ? 10 : uint8(bound(batch, 1, 10)));
            assertLe(game.eliminations(), before + 1);
            if (game.phase() == MugiGameHook.Phase.Live) ++successes["round"];
        }
    }

    /// @dev Plays up to three complete rounds so random sequences reach the finale.
    function advanceRounds(uint256 word, uint256 rounds) external track("advanceRounds") {
        rounds = bound(rounds, 1, 3);
        for (uint256 r; r < rounds; ++r) {
            if (game.phase() != MugiGameHook.Phase.Live || game.eliminations() == 9) return;
            if (_now() < game.nextCutoff()) vm.warp(game.nextCutoff());
            try game.requestElimination() {}
            catch {
                return;
            }
            randomness.fulfill(game.pendingRequest(), uint256(keccak256(abi.encode(word, r))));
            game.settleRound(10);
            ++successes["round"];
        }
    }

    function stall(uint256 batch) external track("stall") {
        // Rare: once the deadline passes the season can only close in emergency.
        if (batch % 8 != 0 && game.phase() != MugiGameHook.Phase.EmergencyUnwinding) return;
        MugiGameHook.Phase phase = game.phase();
        if (phase == MugiGameHook.Phase.Live || phase == MugiGameHook.Phase.AwaitingRandomness) {
            uint256 deadline = game.randomnessDeadline();
            if (_now() < deadline) vm.warp(deadline);
        }
        try game.recoverStalledRandomness(uint8(bound(batch / 8, 1, 10))) {
            if (game.phase() == MugiGameHook.Phase.EmergencyClosed) ++successes["emergency"];
        } catch {}
    }

    function migrate() external track("migrate") {
        if (game.phase() != MugiGameHook.Phase.Finalized || game.migrated()) return;
        uint256 reserved = game.reservedPlayerEth();
        uint256 team = game.teamEth();
        IOwnerHarness(ownerHarness).ownerMigrate();
        assertTrue(game.migrated());
        assertEq(address(game).balance, reserved + team, "handoff takes only available ETH");
        ++successes["migrate"];
    }

    function sweep() external track("sweep") {
        MugiGameHook.Phase phase = game.phase();
        if (phase != MugiGameHook.Phase.Finalized && phase != MugiGameHook.Phase.EmergencyClosed) return;
        uint256 deadline = game.claimsExpireAt();
        if (deadline == 0) return;
        if (_now() < deadline) vm.warp(deadline);
        game.sweepExpiredFinalClaims();
        assertEq(game.claimsExpireAt(), 0);
        ++successes["sweep"];
    }
}

contract MugiGameInvariantTest is MugiGameTestBase {
    MugiGameHandler internal handler;
    MugiIMDSwapRouter internal playerRouter;
    uint256 internal migrations;

    function setUp() public {
        vm.warp(1_800_000_000);
        _setup(new PoolManager(address(this)));
        playerRouter = new MugiIMDSwapRouter(game, manager);
        handler = new MugiGameHandler(game, playerRouter, randomness, [ALICE, BOB, CAROL, EARLY, LATE]);
        targetContract(address(handler));
    }

    function ownerMigrate() external {
        require(msg.sender == address(handler), "handler only");
        ++migrations;
        game.migrateToV2(address(this));
    }

    /// @dev Coverage report so a vacuous run is visible with -vv.
    function afterInvariant() public {
        bytes32[10] memory names = [
            bytes32("buy"),
            "sell",
            "claimEth",
            "claimTokens",
            "ownBuyback",
            "round",
            "finalize",
            "migrate",
            "sweep",
            "emergency"
        ];
        for (uint256 i; i < names.length; ++i) {
            emit log_named_uint(string(abi.encodePacked(names[i])), handler.successes(names[i]));
        }
        emit log_named_uint("eliminations", game.eliminations());
        emit log_named_uint("phase", uint8(game.phase()));
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](12);
        h[0] = ALICE;
        h[1] = BOB;
        h[2] = CAROL;
        h[3] = EARLY;
        h[4] = LATE;
        h[5] = address(game);
        h[6] = address(game.engine());
        h[7] = address(manager);
        h[8] = address(airdrop);
        h[9] = TEAM;
        h[10] = address(this);
        h[11] = address(playerRouter);
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_hookEthCoversPlayerAndTeamLiabilities() public view {
        uint256 held = address(game).balance + game.unredeemedGameFees();
        uint256 owed = game.reservedPlayerEth() + game.teamEth();
        MugiGameHook.Phase phase = game.phase();
        if (
            phase == MugiGameHook.Phase.Live || phase == MugiGameHook.Phase.AwaitingRandomness
                || phase == MugiGameHook.Phase.OutcomeReady
        ) {
            for (uint8 i; i < 10; ++i) {
                owed += game.treasure(i) + game.ownBurnBudget(i);
            }
            for (uint64 round = 1; round <= game.eliminations(); ++round) {
                MugiBuybacks.Budget memory budget = game.roundBudget(round);
                owed += budget.total - budget.spent;
            }
        }
        assertGe(held, owed, "hook ETH below its recorded liabilities");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_hookTokensBackEscrowReserveAndTeamFees() public view {
        for (uint8 i; i < 10; ++i) {
            assertGe(
                MugiCrewToken(crew[i]).balanceOf(address(game)),
                game.escrowBacking(i) + game.unreleasedReserve(i) + game.teamTokens(i),
                "token liabilities unbacked"
            );
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_finiteSupplyNeverGrowsAndIsFullyHeld() public view {
        assertFalse(handler.supplyIncreased(), "a crew totalSupply increased");
        address[] memory holders = _holders();
        for (uint8 i; i < 10; ++i) {
            MugiCrewToken token = MugiCrewToken(crew[i]);
            uint256 sum;
            for (uint256 h; h < holders.length; ++h) {
                sum += token.balanceOf(holders[h]);
            }
            assertEq(sum, token.totalSupply(), "supply held outside the known graph");
            assertLe(token.totalSupply(), token.reserveCap());
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_closedCrewsRetainNoUnusedReserve() public view {
        MugiGameHook.Phase phase = game.phase();
        bool terminal = phase == MugiGameHook.Phase.Finalized || phase == MugiGameHook.Phase.EmergencyClosed;
        for (uint8 i; i < 10; ++i) {
            bool alive = (game.aliveMask() & (uint16(1) << i)) != 0;
            if (!alive || terminal) assertEq(game.unreleasedReserve(i), 0, "closed crew keeps reserve");
            if (!alive) assertEq(game.ledger().eligibleSupply(i), 0, "dead crew keeps eligibility");
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_seasonOnlyMovesForward() public view {
        assertFalse(handler.terminalReopened(), "terminal phase reopened");
        assertFalse(handler.eliminationsDecreased(), "eliminations decreased");
        assertFalse(handler.migrationOutsideFinale(), "migration outside ordinary finale");
        assertLe(migrations, 1, "V2 handoff ran twice");
        uint16 mask = game.aliveMask();
        uint8 alive;
        for (uint8 i; i < 10; ++i) {
            if ((mask & (uint16(1) << i)) != 0) ++alive;
        }
        assertEq(alive, 10 - game.eliminations(), "alive crews and eliminations disagree");
        assertLe(game.eliminations(), 9);
        assertGe(alive, 1);
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_routerNeverRetainsCustody() public view {
        assertEq(address(playerRouter).balance, 0, "router holds ETH");
        for (uint8 i; i < 10; ++i) {
            assertEq(MugiCrewToken(crew[i]).balanceOf(address(playerRouter)), 0, "router holds tokens");
        }
    }
}
