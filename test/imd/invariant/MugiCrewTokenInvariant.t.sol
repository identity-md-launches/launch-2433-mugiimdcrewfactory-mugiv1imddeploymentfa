// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MugiIMDCrewToken} from "../../../src/imd/MugiIMDCrewToken.sol";

/// @dev Drives one fixed-reserve crew token through random transfers,
/// allowance spends and own-balance burns, and records historical snapshots
/// that must never change once their cutoff is in the past.
contract MugiCrewTokenHandler is Test {
    MugiIMDCrewToken public immutable token;
    address[4] internal actors;
    uint256 public ghostBurned;
    bool public historyRewritten;
    bool public foreignBurn;

    struct Snapshot {
        uint64 cutoff;
        uint256 supply;
        uint256[5] balances;
    }

    Snapshot[] internal snapshots;

    constructor(MugiIMDCrewToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function _holder(uint256 seed) internal view returns (address) {
        seed %= 5;
        return seed == 4 ? token.hook() : actors[seed];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
        _checkHistory();
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 allowance_, uint256 amount)
        external
    {
        address owner = _holder(ownerSeed);
        address spender = _holder(spenderSeed);
        address to = _holder(toSeed);
        allowance_ = bound(allowance_, 0, token.balanceOf(owner));
        amount = bound(amount, 0, allowance_);
        vm.prank(owner);
        token.approve(spender, allowance_);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        assertEq(token.allowance(owner, spender), allowance_ - amount, "finite allowance not decremented");
        _checkHistory();
    }

    function overspend(uint256 fromSeed, uint256 toSeed, uint256 extra) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + bound(extra, 1, 1e30);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "transfer above balance succeeded");
        } catch {}
        assertEq(token.balanceOf(from), balance);
        assertEq(token.balanceOf(to), toBefore);
    }

    function burn(uint256 holderSeed, uint256 amount) external {
        address holder = _holder(holderSeed);
        uint256[5] memory before = _balances();
        amount = bound(amount, 0, token.balanceOf(holder));
        vm.prank(holder);
        token.burn(amount);
        ghostBurned += amount;
        uint256[5] memory afterBurn = _balances();
        for (uint256 i; i < 5; ++i) {
            if (_holder(i) != holder && afterBurn[i] != before[i]) foreignBurn = true;
        }
        _checkHistory();
    }

    function snapshot(uint256 seconds_) external {
        // Every write at or after this cutoff must be excluded from the snapshot.
        Snapshot storage s = snapshots.push();
        s.cutoff = uint64(_now());
        s.supply = token.totalSupply();
        s.balances = _balances();
        vm.warp(_now() + bound(seconds_, 1, 3 days));
        // Same-second writes before the warp were part of this timestamp and are
        // therefore excluded; record what was strictly before instead.
        s.supply = token.totalSupplyBefore(s.cutoff);
        for (uint256 i; i < 5; ++i) {
            s.balances[i] = token.balanceBefore(_holder(i), s.cutoff);
        }
    }

    function warp(uint256 seconds_) external {
        vm.warp(_now() + bound(seconds_, 1, 1 days));
    }

    function _balances() internal view returns (uint256[5] memory b) {
        for (uint256 i; i < 5; ++i) {
            b[i] = token.balanceOf(_holder(i));
        }
    }

    function _checkHistory() internal {
        for (uint256 j; j < snapshots.length; ++j) {
            Snapshot storage s = snapshots[j];
            if (token.totalSupplyBefore(s.cutoff) != s.supply) historyRewritten = true;
            for (uint256 i; i < 5; ++i) {
                if (token.balanceBefore(_holder(i), s.cutoff) != s.balances[i]) historyRewritten = true;
            }
        }
    }

    function snapshotCount() external view returns (uint256) {
        return snapshots.length;
    }
}

contract MugiCrewTokenInvariantTest is Test {
    address internal constant HOOK = address(0x1234000000000000000000000000000000002aeC);
    uint256 internal constant SUPPLY = 1_000_000 ether;
    MugiIMDCrewToken internal token;
    MugiCrewTokenHandler internal handler;
    address[4] internal actors = [address(0xA11CE), address(0xB0B), address(0xCA201), address(0xD00D)];

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MugiIMDCrewToken(3, HOOK, SUPPLY);
        handler = new MugiCrewTokenHandler(token, actors);
        // Spread part of the reserve so every actor starts with a balance.
        for (uint256 i; i < 4; ++i) {
            vm.prank(HOOK);
            token.transfer(actors[i], SUPPLY);
        }
        vm.warp(1_800_000_001);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesSumToTotalSupply() public view {
        uint256 sum = token.balanceOf(HOOK);
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyOnlyFallsByBurns() public view {
        assertEq(token.totalSupply(), token.reserveCap() - handler.ghostBurned());
        assertEq(token.reserveCap(), 10 * SUPPLY + 100 * uint256(uint128(type(int128).max)));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_pastSnapshotsAreImmutable() public view {
        assertFalse(handler.historyRewritten(), "a strictly-earlier balance or supply changed");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_burnOnlyAffectsCaller() public view {
        assertFalse(handler.foreignBurn(), "burn changed another holder's balance");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_genesisHasNoEarlierHistory() public view {
        assertEq(token.totalSupplyBefore(1_800_000_000), 0);
        assertEq(token.balanceBefore(HOOK, 1_800_000_000), 0);
        assertEq(token.totalSupplyBefore(type(uint64).max), token.totalSupply());
    }
}
