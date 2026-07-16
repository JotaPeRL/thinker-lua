#pragma once
/*
 * Golden traces (IMPLEMENTATION_PLAN.md Phase 5.2, Consolidation gate item
 * c) -- offline regression fixtures for the Lua port, independent of
 * lua_shadow: this doesn't invoke the Lua side at all, it just records what
 * the C++ implementation already computed, so a golden_trace=1 run needs no
 * live game to re-check later, only tools/golden_trace_replay.lua under
 * native luajit.
 *
 * Two purpose-built functions, not a generic JSON-value abstraction --
 * only two call sites exist today (src/plan.cpp). Flattened ints only, no
 * engine-struct dependency in this header, same precedent as
 * lua_ai_shadow_call flattening WItem rather than taking the struct
 * (src/luaai.h).
 *
 * Both no-op immediately when conf.golden_trace is 0 (zero overhead beyond
 * that one flag check, same convention as lua_shadow).
 */

void golden_trace_facility_score(int item_id,
    int wgov_growth, int wgov_tech, int wgov_wealth, int wgov_power, int wgov_fight,
    int p_growth, int p_tech, int p_wealth, int p_power, int p_fight,
    int result);

void golden_trace_governor_priorities(int base_id,
    int governor_flags, int defend_goal, int faction_id, int is_human,
    int f_growth, int f_tech, int f_wealth, int f_power, int f_fight,
    int result_growth, int result_tech, int result_wealth, int result_power, int result_fight);
