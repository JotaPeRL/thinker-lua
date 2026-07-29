#pragma once
/*
 * Phase 5.4 performance baseline (IMPLEMENTATION_PLAN.md). Accumulates
 * per-turn wall-clock time across four phase buckets, roughly matching
 * the plan's own "upkeep, production, movement" language:
 *
 *   PERF_PRODUCTION        -- mod_production_phase, per faction
 *   PERF_MOVEMENT_PLAN     -- move_upkeep, per faction (land_raise_plan/
 *                              invasion_plan/update_main_region, not the
 *                              per-vehicle movers)
 *   PERF_MOVEMENT_DISPATCH -- mod_enemy_turn, per faction (the actual
 *                              per-vehicle Class 3 movers -- the heaviest
 *                              bucket)
 *   PERF_BASE_UPKEEP       -- mod_base_upkeep, per base
 *
 * One line logged per turn to perf_trace.log, then all four accumulators
 * reset. Compare two autoplay runs on the same save/seed/turn count with
 * conf.lua_ai=0 vs conf.lua_ai=1 for the C++-vs-Lua performance delta.
 *
 * Zero overhead when conf.perf_trace is 0, same convention as
 * golden_trace/lua_shadow -- PerfScope skips the clock read entirely,
 * not just the accumulation, and perf_trace_log_turn no-ops immediately.
 * conf.perf_trace is deliberately not documented in modmenu.txt (same
 * "unlisted option" tier as golden_trace): a deliberate benchmark tool,
 * not a player-facing setting.
 */

#include <chrono>

enum PerfPhase {
    PERF_PRODUCTION = 0,
    PERF_MOVEMENT_PLAN = 1,
    PERF_MOVEMENT_DISPATCH = 2,
    PERF_BASE_UPKEEP = 3,
    PERF_PHASE_COUNT = 4,
};

// RAII scope timer. Construct at the top of a { } block wrapping exactly
// the call(s) to measure; destructor adds the elapsed time to that
// phase's running total.
class PerfScope {
public:
    explicit PerfScope(PerfPhase phase);
    ~PerfScope();

private:
    PerfPhase phase_;
    bool active_;
    std::chrono::high_resolution_clock::time_point start_;
};

// Appends the current turn's accumulated per-phase totals to
// perf_trace.log and resets all four accumulators to zero. Called once
// per turn from mod_turn_upkeep, before that call's own processing
// advances *CurrentTurn -- so it reports the turn that just finished,
// not the one about to start.
void perf_trace_log_turn(int turn);
