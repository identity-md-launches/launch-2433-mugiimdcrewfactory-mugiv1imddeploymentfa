// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Cumulative-tick price protection for native-ETH/currency1 game buybacks.
/// @dev The controller updates before AND after every pool swap, including its own swaps.
/// The minimum history is 15 minutes. We use the closest observation at or before the
/// cutoff and its actual age, rather than inventing ticks by interpolating sparse samples.
/// Settlement deposits are checked against an exact round-long TWAP from hourly checkpoints.
contract MugiIMDPriceOracle {
    uint32 public constant MIN_HISTORY = 15 minutes;
    uint32 public constant MIN_SAMPLE_INTERVAL = 60;
    uint16 public constant CAPACITY = 128;
    uint24 public constant LP_FEE = 3_000;
    uint256 public constant SLIPPAGE_BPS = 300;
    int24 public constant MAX_SPOT_DEVIATION_TICKS = 488;
    // 304 ticks are just under a 3% price change. currentTick rounds the actual tick down,
    // so moving 303 complete ticks accounts conservatively for its fractional remainder.
    int24 private constant PRICE_LIMIT_TICKS = 303;
    /// @notice Settlement reference length: the hook's fixed round, from the previous
    /// round's final settlement (or launch) to the cutoff.
    uint32 public constant SETTLEMENT_WINDOW = 1 days;
    /// @notice Hour-boundary checkpoints keep that reference exact. Swaps cannot evict them:
    /// a window holds at most 26 boundaries and CHECKPOINT_SLOTS is 32.
    uint32 public constant CHECKPOINT_INTERVAL = 1 hours;
    uint8 private constant CHECKPOINT_SLOTS = 32;

    struct Observation {
        uint64 timestamp;
        int128 cumulativeTick;
    }

    /// @dev `tick` held from the previous update through `timestamp`. A `first` checkpoint
    /// is the series' first update; no price exists before it.
    struct Checkpoint {
        uint64 timestamp;
        int128 cumulativeTick;
        int24 tick;
        bool first;
    }

    struct Series {
        int24 currentTick;
        uint64 lastUpdate;
        uint16 index;
        uint16 count;
        int128 cumulativeTick;
        Observation[128] observations;
        Checkpoint[32] checkpoints;
    }

    struct State {
        mapping(uint8 => Series) pools;
    }

    address public immutable hook;
    State private self;
    error InvalidHook();
    error NotHook();

    constructor(address hook_) {
        if (hook_ == address(0)) revert InvalidHook();
        hook = hook_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    error InvalidCrew();
    error InvalidTick();
    error InvalidTime();
    error InsufficientHistory();
    error SpotDeviation();
    error QuoteTooSmall();
    error InvalidPriceLimit();

    /// @notice Accumulates time at the prior tick, then records the current pool tick.
    /// @dev Repeated calls in one block cannot manufacture elapsed time or evict history.
    function update(uint8 crew, int24 currentTick) external onlyHook {
        if (crew >= 10) revert InvalidCrew();
        _validTick(currentTick);
        uint64 nowTime = _timestamp();
        Series storage series = self.pools[crew];
        if (series.count == 0) {
            series.currentTick = currentTick;
            series.lastUpdate = nowTime;
            series.count = 1;
            series.observations[0] = Observation(nowTime, 0);
            series.checkpoints[_checkpointSlot(nowTime)] = Checkpoint(nowTime, 0, currentTick, true);
            return;
        }
        uint64 hourStart = nowTime - nowTime % CHECKPOINT_INTERVAL;
        if (hourStart > series.lastUpdate) {
            // The prior tick held from lastUpdate until now, so this boundary is exact.
            series.checkpoints[_checkpointSlot(hourStart)] =
                Checkpoint(hourStart, _cumulativeAt(series, hourStart), series.currentTick, false);
        }
        int128 cumulative = _cumulativeAt(series, nowTime);
        series.cumulativeTick = cumulative;
        series.lastUpdate = nowTime;
        series.currentTick = currentTick;
        if (nowTime - series.observations[series.index].timestamp >= MIN_SAMPLE_INTERVAL) {
            uint16 next = (series.index + 1) % CAPACITY;
            series.observations[next] = Observation(nowTime, cumulative);
            series.index = next;
            if (series.count < CAPACITY) series.count++;
        }
    }

    function consult(uint8 crew) public view returns (int24 averageTick, uint32 secondsUsed) {
        if (crew >= 10) revert InvalidCrew();
        Series storage series = self.pools[crew];
        uint64 nowTime = _timestamp();
        if (series.count == 0 || nowTime < MIN_HISTORY) revert InsufficientHistory();
        bool found;
        (found, averageTick, secondsUsed) = _meanBefore(series, nowTime);
        if (!found) revert InsufficientHistory();
    }

    /// @notice Settlement reinforcement guard. Official-pool swaps stop at the round cutoff,
    /// so the price a settlement deposit meets is the one the last pre-cutoff trade left.
    /// It is accepted only within MAX_SPOT_DEVIATION_TICKS of the TWAP over the whole round
    /// ending at that cutoff, so a pump has to be held for most of the round to pass.
    /// @dev Never reverts for missing or post-cutoff history; the hook defers instead.
    function settlementPriceValid(uint8 crew, uint64 cutoff, int24 currentTick) external view returns (bool) {
        if (crew >= 10 || currentTick < TickMath.MIN_TICK || currentTick > TickMath.MAX_TICK) return false;
        Series storage series = self.pools[crew];
        if (series.count == 0 || cutoff < SETTLEMENT_WINDOW || cutoff > _timestamp() || series.lastUpdate > cutoff) {
            return false;
        }
        (bool found, int24 averageTick) = _roundMean(series, cutoff);
        int256 deviation = int256(currentTick) - int256(averageTick);
        return found && deviation <= MAX_SPOT_DEVIATION_TICKS && deviation >= -int256(MAX_SPOT_DEVIATION_TICKS);
    }

    /// @dev Exact mean tick from the hour boundary at or before `end - SETTLEMENT_WINDOW`
    /// (or the series' first update, if later) to `end`. The first update at or after that
    /// boundary wrote the earliest checkpoint at or after it, inside one constant-tick span.
    function _roundMean(Series storage series, uint64 end) private view returns (bool found, int24 averageTick) {
        uint64 start = end - SETTLEMENT_WINDOW;
        start -= start % CHECKPOINT_INTERVAL;
        int128 startCumulative;
        bool located;
        for (uint64 hourStart = start; hourStart <= end; hourStart += CHECKPOINT_INTERVAL) {
            Checkpoint storage checkpoint = series.checkpoints[_checkpointSlot(hourStart)];
            // Empty or stale (an earlier hour sharing the slot).
            if (
                checkpoint.timestamp == 0 || checkpoint.timestamp < hourStart
                    || checkpoint.timestamp >= hourStart + CHECKPOINT_INTERVAL
            ) continue;
            if (checkpoint.first) {
                start = checkpoint.timestamp;
                startCumulative = checkpoint.cumulativeTick;
            } else {
                startCumulative = int128(
                    int256(checkpoint.cumulativeTick) - int256(checkpoint.tick)
                        * int256(uint256(checkpoint.timestamp - start))
                );
            }
            located = true;
            break;
        }
        // No checkpoint means no update since `start`; the live tick has held since before it.
        if (!located) {
            if (series.lastUpdate > start) return (false, 0);
            startCumulative = _cumulativeAt(series, start);
        }
        if (end - start < MIN_HISTORY) return (false, 0);
        int256 elapsedTick = int256(_cumulativeAt(series, end)) - int256(startCumulative);
        return (true, _floorMean(elapsedTick, end - start));
    }

    /// @dev Mean tick from the newest observation at least MIN_HISTORY before `end` up to `end`.
    function _meanBefore(Series storage series, uint64 end)
        private
        view
        returns (bool found, int24 averageTick, uint32 secondsUsed)
    {
        int128 cumulative = _cumulativeAt(series, end);
        uint64 cutoff = end - MIN_HISTORY;
        for (uint16 offset; offset < series.count; offset++) {
            uint16 index = (series.index + CAPACITY - offset) % CAPACITY;
            Observation storage observation = series.observations[index];
            if (observation.timestamp > cutoff) continue;
            uint64 age = end - observation.timestamp;
            if (age > type(uint32).max) revert InvalidTime();
            secondsUsed = uint32(age);
            int256 elapsedTick = int256(cumulative) - int256(observation.cumulativeTick);
            return (true, _floorMean(elapsedTick, age), secondsUsed);
        }
    }

    function _floorMean(int256 elapsedTick, uint64 age) private pure returns (int24) {
        int256 mean = elapsedTick / int256(uint256(age));
        // Solidity truncates negative division toward zero; ticks require mathematical floor.
        if (elapsedTick < 0 && elapsedTick % int256(uint256(age)) != 0) mean--;
        return int24(mean); // A time-weighted mean stays within validated TickMath bounds.
    }

    /// @notice Identical read ABI to the hook; aggregation avoids redundant CALLs.
    function buybackTwap(uint8 crew) external view returns (int24 tick, uint32 secondsUsed, uint16 observations) {
        (tick, secondsUsed) = consult(crew);
        observations = self.pools[crew].count;
    }

    /// @notice Minimum token output after 0.3% LP fee and 3% slippage; no game fee on hook buybacks.
    /// @dev Quotes base units; all crew tokens and native ETH use 18 decimals.
    function quoteMinimum(uint8 crew, uint256 ethAmount, int24 currentTick)
        public
        view
        returns (uint256 minTokens, uint160 sqrtPriceLimitX96)
    {
        _validTick(currentTick);
        (int24 averageTick,) = consult(crew);
        int256 deviation = int256(currentTick) - int256(averageTick);
        if (deviation > MAX_SPOT_DEVIATION_TICKS || deviation < -int256(MAX_SPOT_DEVIATION_TICKS)) {
            revert SpotDeviation();
        }
        int256 limitTick = int256(currentTick) - PRICE_LIMIT_TICKS;
        if (limitTick <= TickMath.MIN_TICK) revert InvalidPriceLimit();
        sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(int24(limitTick));
        uint256 netEth = FullMath.mulDiv(ethAmount, 1_000_000 - LP_FEE, 1_000_000);
        uint160 price = TickMath.getSqrtPriceAtTick(averageTick);
        uint256 quote;
        if (price <= type(uint128).max) {
            uint256 ratioX192 = uint256(price) * price;
            quote = FullMath.mulDiv(netEth, ratioX192, uint256(1) << 192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(price, price, uint256(1) << 64);
            quote = FullMath.mulDiv(netEth, ratioX128, uint256(1) << 128);
        }
        minTokens = FullMath.mulDiv(quote, 10_000 - SLIPPAGE_BPS, 10_000);
        if (minTokens == 0) revert QuoteTooSmall();
    }

    function observationCount(uint8 crew) public view returns (uint16) {
        if (crew >= 10) revert InvalidCrew();
        return self.pools[crew].count;
    }

    function _cumulativeAt(Series storage series, uint64 timestamp) private view returns (int128) {
        if (timestamp < series.lastUpdate) revert InvalidTime();
        // MAX_TICK * uint64.max is well below int128.max.
        return
            series.cumulativeTick + int128(int256(series.currentTick) * int256(uint256(timestamp - series.lastUpdate)));
    }

    function _checkpointSlot(uint64 timestamp) private pure returns (uint256) {
        return (timestamp / CHECKPOINT_INTERVAL) % CHECKPOINT_SLOTS;
    }

    function _timestamp() private view returns (uint64) {
        if (block.timestamp > type(uint64).max) revert InvalidTime();
        return uint64(block.timestamp);
    }

    function _validTick(int24 tick) private pure {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert InvalidTick();
    }
}
