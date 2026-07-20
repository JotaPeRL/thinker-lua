/*
 * Phase 2B: production Lua AI runtime lifecycle.
 *
 * Builds on the Phase 2A feasibility spike (LuaJIT stable in-process under
 * mingw static-link + Wine, IMPLEMENTATION_PLAN.md Phase 2A). This file
 * replaces the spike's throwaway checklist code with the real runtime every
 * later phase depends on: config-gated init, a sandboxed VM, an error policy
 * (conf.lua_strict), deduplicated error logging, and safe-point hot reload.
 *
 * No AI hooks exist yet (Phase 4) and no LuaHostApi/FFI layer exists yet
 * (Phase 3) — this is infrastructure only. The only script-visible surface
 * is lua/init.lua and the sandboxed standard libraries.
 */

#include "main.h"
#include "luaai.h"
#include "random.h"
#include "faction.h"
#include "tech.h"
#include "map.h"
#include "base.h"
#include "veh.h"
#include "build.h"
#include "path.h"
#include "move.h"

#include <string>
#include <unordered_set>
#include <unordered_map>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "luajit.h"
}

// Trivial passthrough for conf.tech_balance -- a captureless lambda
// converts implicitly to a plain function pointer, so this doesn't need
// a named free function the way revised_tech_cost() (real logic, already
// existed in tech.cpp) does.
static int host_tech_balance_enabled() {
    return conf.tech_balance;
}

// Social engineering (porting-order item 2, IMPLEMENTATION_DETAILS.md 4.5).
// social_calc/social_upheaval take a flat 4-int model array from Lua and
// build a local CSocialCategory to call the real engine function with --
// CSocialCategory is 4 consecutive int32_t (models[4]), so a memcpy is
// exact. CSocialEffect's values[11] union member means out_values can be
// written through directly via reinterpret_cast, no separate marshalling.
static void host_social_calc(const int32_t* models, int32_t faction_id, int32_t* out_values) {
    CSocialCategory cat;
    memcpy(cat.models, models, sizeof(cat.models));
    social_calc(&cat, reinterpret_cast<CSocialEffect*>(out_values), faction_id, 0, 0);
}

static int32_t host_society_avail(int32_t sf, int32_t sm, int32_t faction_id) {
    return society_avail(sf, sm, faction_id);
}

static int32_t host_social_upheaval(int32_t faction_id, const int32_t* models) {
    CSocialCategory cat;
    memcpy(cat.models, models, sizeof(cat.models));
    return social_upheaval(faction_id, &cat);
}

static bool host_has_project(int32_t item_id, int32_t faction_id) {
    return has_project((FacilityId)item_id, faction_id);
}

static bool host_has_free_facility(int32_t item_id, int32_t faction_id) {
    return has_free_facility((FacilityId)item_id, faction_id);
}

static bool host_has_aircraft(int32_t faction_id) {
    return has_aircraft(faction_id);
}

static int32_t host_mineral_factor(int32_t faction_id, int32_t se_industry) {
    return mineral_factor(faction_id, se_industry);
}

static bool host_un_charter() {
    return un_charter();
}

// plans[]/conf are Thinker-internal (not FFI-mapped, see
// IMPLEMENTATION_DETAILS.md 3.4/4.5) -- exposed as single-field accessors
// rather than pulling AIPlans/Config into the FFI generator.
static int32_t host_defense_modifier(int32_t faction_id) {
    return plans[faction_id].defense_modifier;
}

static int32_t host_keep_fungus(int32_t faction_id) {
    return plans[faction_id].keep_fungus;
}

static int32_t host_social_ai_bias() {
    return conf.social_ai_bias;
}

// War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md 4.6).
static int32_t host_great_beelzebub(int32_t faction_id, int32_t is_aggressive) {
    return great_beelzebub(faction_id, is_aggressive);
}

static int32_t host_great_satan(int32_t faction_id, int32_t is_aggressive) {
    return great_satan(faction_id, is_aggressive);
}

static int32_t host_has_agenda(int32_t faction_id_1, int32_t faction_id_2, uint32_t status) {
    return has_agenda(faction_id_1, faction_id_2, status);
}

// Replicates evaluate_attack's own last-match-wins scan over Bases[]
// (faction.cpp:1630-1638) exactly, rather than calling find_hq() (which may
// tie-break differently) -- keeps the dual-run comparison exact. BASE stays
// out of the FFI (deferred to porting-order item 3); this is the one field
// Lua needs from it, computed entirely in C++.
static int32_t host_hq_region(int32_t faction_id) {
    int32_t region = -1;
    for (int i = 0; i < *BaseCount; i++) {
        if (has_fac_built(FAC_HEADQUARTERS, i) && Bases[i].faction_id == faction_id) {
            region = region_at(Bases[i].x, Bases[i].y);
        }
    }
    return region;
}

// Production/plans port, first slice (porting-order item 3,
// IMPLEMENTATION_DETAILS.md 4.7).
static int32_t host_bases_ptr() {
    return (int32_t)Bases;
}

// select_build itself (porting-order item 3, final piece,
// IMPLEMENTATION_DETAILS.md 4.10.1).
static int32_t host_vehs_ptr() {
    return (int32_t)Vehs;
}

// Phase 5.3.5 determinism diagnostics (IMPLEMENTATION_DETAILS.md):
// map_rand.get_state() and the draw counters need a wrapper since they're
// a member call / plain globals, not free functions matching the
// LuaHostApi field signature directly (game_rand_state/random_state
// already match and are assigned with no wrapper, below).
static uint32_t host_map_rand_state() {
    return map_rand.get_state();
}
static uint32_t host_game_rand_draws() {
    return g_game_rand_draws;
}
static uint32_t host_mod_rng_draws() {
    return g_mod_rng_draws;
}
static uint32_t host_map_rng_draws() {
    return g_map_rand_draws;
}

static int32_t host_mod_veh_avail(int32_t unit_id, int32_t faction_id, int32_t base_id) {
    return mod_veh_avail(unit_id, faction_id, base_id);
}

static int32_t host_has_abil(int32_t unit_id, uint32_t ability) {
    return has_abil(unit_id, (VehAblFlag)ability);
}

static int32_t host_has_fac_built(int32_t item_id, int32_t base_id) {
    return has_fac_built((FacilityId)item_id, base_id);
}

// select_build step 2 (IMPLEMENTATION_DETAILS.md 4.10.5/4.10.9, resumed
// after the Consolidation gate): mod_base_making is genuine retool-
// category engine logic (Skunkworks/FREEPROTO exemptions), not AI
// policy -- opaque wrapper, same bucket as mod_veh_avail/has_fac_built.
static int32_t host_mod_base_making(int32_t item_id, int32_t base_id) {
    return mod_base_making(item_id, base_id);
}

// conf.skip_gov_facility is a uint64_t bitmask -- exposing it through
// LuaHostApi's int32_t-only convention would need an awkward two-half
// split for no benefit, so this wraps the single-bit query skip_facility
// (build.cpp:6-9) actually needs instead of the raw config value.
static int32_t host_skip_gov_facility_bit(int32_t item_id) {
    return (item_id >= 1 && item_id <= 64
        && (conf.skip_gov_facility & (1ULL << (item_id - 1)))) ? 1 : 0;
}

// select_build step 3 sub-step 1 (IMPLEMENTATION_DETAILS.md 4.10.9/
// 4.10.12, resumed after the Consolidation gate): the shared prologue
// through Wbase/Wthreat. region_at/allow_expand are real engine
// mechanics, not AI policy. The six AIPlans accessors match the existing
// psi_score/median_limit/defense_modifier tier exactly (bare field name,
// per-faction lookup) -- enemy_mil_factor/enemy_base_range are this
// project's first float-returning LuaHostApi entries; LuaJIT's FFI
// handles float natively, nothing special needed on the Lua side.
static int32_t host_region_at(int32_t x, int32_t y) {
    return region_at(x, y);
}

static int32_t host_allow_expand(int32_t faction_id) {
    return allow_expand(faction_id);
}

static int32_t host_project_limit(int32_t faction_id) {
    return plans[faction_id].project_limit;
}

static int32_t host_main_region(int32_t faction_id) {
    return plans[faction_id].main_region;
}

static int32_t host_target_land_region(int32_t faction_id) {
    return plans[faction_id].target_land_region;
}

static int32_t host_enemy_bases(int32_t faction_id) {
    return plans[faction_id].enemy_bases;
}

static float host_enemy_mil_factor(int32_t faction_id) {
    return plans[faction_id].enemy_mil_factor;
}

static float host_enemy_base_range(int32_t faction_id) {
    return plans[faction_id].enemy_base_range;
}

// select_build step 3 sub-step 2 (IMPLEMENTATION_DETAILS.md 4.10.9/
// 4.10.13, resumed after the Consolidation gate): DefendUnit/CombatUnit.
// All three are real engine mechanics, not AI policy.
static int32_t host_need_scouts(int32_t base_id, int32_t triad) {
    return need_scouts(base_id, (Triad)triad);
}

static int32_t host_has_ships(int32_t faction_id) {
    return has_ships(faction_id);
}

// C++'s own signature takes `bool ocean`, not a Triad -- call sites pass
// TRIAD_SEA/TRIAD_LAND relying on their exact values (1/0) implicitly
// converting. Kept as a plain int here; Lua callers pass 1/0 (or
// E.TRIAD_SEA/E.TRIAD_LAND directly, same values) -- passing TRIAD_AIR
// here would silently mean `true`, same trap the original C++ has.
static int32_t host_adjacent_region(int32_t x, int32_t y, int32_t owner, int32_t threshold, int32_t ocean) {
    return adjacent_region(x, y, owner, threshold, ocean != 0);
}

// select_build step 3 sub-step 3 (IMPLEMENTATION_DETAILS.md 4.10.9/
// 4.10.14, resumed after the Consolidation gate): the build_order loop's
// per-item base score. Both real engine mechanics, not AI policy.
static int32_t host_can_build(int32_t base_id, int32_t item_id) {
    return can_build(base_id, item_id);
}

static int32_t host_energy_limit(int32_t faction_id) {
    return plans[faction_id].energy_limit;
}

// select_build itself, facility-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.17): FAC_BIOLOGY_LAB's own branch (build.cpp:1302-1306).
static int32_t host_biology_lab_bonus() {
    return conf.biology_lab_bonus;
}

// select_build itself, facility-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.18): the shared FAC_RECREATION_COMMONS/FAC_HOLOGRAM_
// THEATRE/FAC_RESEARCH_HOSPITAL/FAC_PARADISE_GARDEN branch. Real engine
// mechanics (diff-level content_pop table lookup + a base_limit formula),
// not AI policy -- same precedent as social_calc.
static void host_mod_psych_check(int32_t faction_id, int32_t* content_pop, int32_t* base_limit) {
    mod_psych_check(faction_id, content_pop, base_limit);
}

// select_build itself, facility-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.19): FAC_PSI_GATE's own branch. Same AIPlans-accessor
// pattern as main_region/target_land_region above.
static int32_t host_naval_start_x(int32_t faction_id) {
    return plans[faction_id].naval_start_x;
}

static int32_t host_naval_start_y(int32_t faction_id) {
    return plans[faction_id].naval_start_y;
}

// select_build itself, facility-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.22): FAC_CHILDREN_CRECHE's own branch.
static int32_t host_base_unused_space(int32_t base_id) {
    return base_unused_space(base_id);
}

// select_build itself, facility-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.23): FAC_TREE_FARM/FAC_HYBRID_FOREST's shared branch.
static int32_t host_nearby_items(int32_t x, int32_t y, int32_t start_index, int32_t end_index, uint32_t item) {
    return nearby_items(x, y, (size_t)start_index, (size_t)end_index, item);
}

// select_build itself, facility-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.24): the FAC_GENEJACK_FACTORY group's shared branch.
static int32_t host_mineral_output_modifier(int32_t base_id) {
    return mineral_output_modifier(base_id);
}

static int32_t host_clean_minerals() {
    return conf.clean_minerals;
}

// select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
// 4.10.27): SeaProbeUnit's own AIPlans accessor.
static int32_t host_unknown_factions(int32_t faction_id) {
    return plans[faction_id].unknown_factions;
}

// Satellites branch, via find_satellite (build.cpp:286-330).
static int32_t host_has_facility(int32_t item_id, int32_t base_id) {
    return has_facility((FacilityId)item_id, base_id);
}

static int32_t host_is_alive(int32_t faction_id) {
    return is_alive(faction_id);
}

static int32_t host_enemy_odp(int32_t faction_id) {
    return plans[faction_id].enemy_odp;
}

static int32_t host_enemy_sat(int32_t faction_id) {
    return plans[faction_id].enemy_sat;
}

static int32_t host_satellite_goal_setting(int32_t faction_id) {
    return plans[faction_id].satellite_goal;
}

static int32_t host_max_satellites() {
    return conf.max_satellites;
}

// select_build itself, unit-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.28): faction_might, via find_project's SecretProject
// branch.
static int32_t host_mil_strength(int32_t faction_id) {
    return plans[faction_id].mil_strength;
}

// select_build itself, step 4 (wiring the real hook, IMPLEMENTATION_
// DETAILS.md 4.10): allow_units's own can_build_unit(base_id, -1) call
// (build.cpp:872) reduces, for unit_id == -1, to this one conf-gated
// expression (base.cpp:4829) -- ported directly to Lua rather than
// wrapped (same "cheap enough once actually read" precedent as
// facility_count/prod_count), since only conf.max_veh_num itself is
// Thinker-internal and not otherwise exposed.
static int32_t host_max_veh_num() {
    return conf.max_veh_num;
}

// Movement port, stage 0 (IMPLEMENTATION_DETAILS.md 4.12): tracks whether
// the current Class 3 hook invocation has mutated engine state yet. Reset
// to false at the start of every lua_ai_command_hook call, set to true by
// each mutating wrapper below as its first action. Single global is safe
// because movement dispatch is strictly sequential (one veh at a time,
// no reentrant Lua calls mid-mover).
static bool g_mutation_issued = false;

// Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12): artifact_move's
// own dependencies, all pure reads.
static int32_t host_base_at(int32_t x, int32_t y) {
    return base_at(x, y);
}

static int32_t host_can_link_artifact(int32_t base_id) {
    return can_link_artifact(base_id);
}

static int32_t host_map_safety(int32_t x, int32_t y) {
    return mapdata[{x, y}].safety;
}

static void host_search_route(int32_t veh_id, int32_t x, int32_t y,
int32_t* found, int32_t* tx, int32_t* ty) {
    TileSearch ts;
    int local_tx = x;
    int local_ty = y;
    *found = search_route(ts, veh_id, &local_tx, &local_ty);
    *tx = local_tx;
    *ty = local_ty;
}

// Mutating wrappers (the first ever added -- every prior LuaHostApi entry
// was a pure read). Each sets g_mutation_issued before doing anything
// else, so lua_ai_command_hook can tell, even after a Lua error, whether
// real state changed and the no-fallback rule applies.
static int32_t host_mod_study_artifact(int32_t veh_id) {
    g_mutation_issued = true;
    return mod_study_artifact(veh_id);
}

static int32_t host_set_move_to(int32_t veh_id, int32_t x, int32_t y) {
    g_mutation_issued = true;
    return set_move_to(veh_id, x, y);
}

static int32_t host_mod_veh_skip(int32_t veh_id) {
    g_mutation_issued = true;
    return mod_veh_skip(veh_id);
}

// select_build itself, unit-branch catalog continued (IMPLEMENTATION_
// DETAILS.md 4.10.29): FormerUnit's own tile-quality tally
// (build.cpp:1157-1166), reproduced verbatim.
static void host_former_tile_tally(int32_t base_id, int32_t* num, int32_t* sea) {
    BASE* base = &Bases[base_id];
    int faction_id = base->faction_id;
    *num = 0;
    *sea = 0;
    for (const auto& m : iterate_tiles(base->x, base->y, 1, 21)) {
        if (m.sq->owner == faction_id
        && select_item(m.x, m.y, faction_id, FM_Auto_Full, m.sq) >= 0) {
            *num += (base->worked_tiles & (1 << m.i)
                && !(m.sq->items & (BIT_SIMPLE|BIT_ADVANCED)) ? 2 : 1);
            *sea += is_ocean(m.sq);
        }
    }
}

static int32_t host_ignore_reactor_power() {
    return conf.ignore_reactor_power;
}

static int32_t host_long_range_artillery() {
    return conf.long_range_artillery;
}

static int32_t host_modify_unit_support() {
    return conf.modify_unit_support;
}

static int32_t host_psi_score(int32_t faction_id) {
    return plans[faction_id].psi_score;
}

static int32_t host_missile_units(int32_t faction_id) {
    return plans[faction_id].missile_units;
}

static int32_t host_median_limit(int32_t faction_id) {
    return plans[faction_id].median_limit;
}

static int32_t host_max_offense_value(int32_t faction_id) {
    return plans[faction_id].max_offense_value;
}

static int32_t host_max_defense_value(int32_t faction_id) {
    return plans[faction_id].max_defense_value;
}

// Production/plans port, second slice (porting-order item 3,
// IMPLEMENTATION_DETAILS.md 4.8).
static int32_t host_has_base_sites(int32_t x, int32_t y, int32_t faction_id, int32_t triad) {
    TileSearch ts;
    return has_base_sites(ts, x, y, faction_id, triad);
}

static int32_t host_is_ocean(int32_t base_id) {
    return is_ocean(&Bases[base_id]);
}

static int32_t host_map_range(int32_t x1, int32_t y1, int32_t x2, int32_t y2) {
    return map_range(x1, y1, x2, y2);
}

static int32_t host_check_probe(int32_t base_id, int32_t triad) {
    return check_probe(&Bases[base_id], (Triad)triad);
}

static int32_t host_has_wmode(int32_t faction_id, int32_t mode) {
    return has_wmode(faction_id, (VehWeaponMode)mode);
}

static int32_t host_has_pact(int32_t faction_id_1, int32_t faction_id_2) {
    return has_pact(faction_id_1, faction_id_2);
}

static int32_t host_at_war(int32_t faction_id_1, int32_t faction_id_2) {
    return at_war(faction_id_1, faction_id_2);
}

static int32_t host_best_reactor(int32_t faction_id) {
    return best_reactor(faction_id);
}

static int32_t host_expansion_autoscale() {
    return conf.expansion_autoscale;
}

static int32_t host_air_combat_units(int32_t faction_id) {
    return plans[faction_id].air_combat_units;
}

static int32_t host_transport_units(int32_t faction_id) {
    return plans[faction_id].transport_units;
}

static int32_t host_probe_units(int32_t faction_id) {
    return plans[faction_id].probe_units;
}

static int32_t host_sea_combat_units(int32_t faction_id) {
    return plans[faction_id].sea_combat_units;
}

static int32_t host_land_combat_units(int32_t faction_id) {
    return plans[faction_id].land_combat_units;
}

static int32_t host_contacted_factions(int32_t faction_id) {
    return plans[faction_id].contacted_factions;
}

// select_colony's own iterate_tiles scan (build.cpp), replicated here
// rather than opening MAP/iterate_tiles to Lua for one loop -- see
// IMPLEMENTATION_DETAILS.md 4.8.
static int32_t host_ocean_colony_land_site(int32_t base_id, int32_t land) {
    BASE* base = &Bases[base_id];
    bool aquatic = MFactions[base->faction_id].is_aquatic();
    for (const auto& m : iterate_tiles(base->x, base->y, 1, 9)) {
        if (land && (m.sq->veh_owner() < 0 || m.sq->veh_owner() == base->faction_id)
        && (!m.sq->is_owned() || (m.sq->owner == base->faction_id && !random(4)))
        && (!aquatic || !random(8))) {
            return true;
        }
    }
    return false;
}

// Populated once; every entry already matches the LuaHostApi pointer
// signature exactly, so no wrapper/trampoline functions are needed
// (see src/luaai.h for why extern "C" doesn't matter here).
static LuaHostApi g_host_api = {
    /* api_version          */ 24,
    /* rand_game            */ game_randv,
    /* rand_map             */ random_get,
    /* is_human             */ is_human,
    /* has_treaty           */ has_treaty,
    /* climactic_battle     */ climactic_battle,
    /* mod_wants_to_attack  */ mod_wants_to_attack,
    /* has_tech             */ has_tech,
    /* tech_level           */ tech_level,
    /* mod_tech_avail       */ mod_tech_avail,
    /* tech_is_preq         */ tech_is_preq,
    /* bad_reg              */ bad_reg,
    /* revised_tech_cost    */ revised_tech_cost,
    /* tech_balance_enabled */ host_tech_balance_enabled,
    /* social_calc          */ host_social_calc,
    /* society_avail        */ host_society_avail,
    /* social_upheaval      */ host_social_upheaval,
    /* has_project          */ host_has_project,
    /* has_free_facility    */ host_has_free_facility,
    /* has_aircraft         */ host_has_aircraft,
    /* mineral_factor       */ host_mineral_factor,
    /* un_charter           */ host_un_charter,
    /* defense_modifier     */ host_defense_modifier,
    /* keep_fungus          */ host_keep_fungus,
    /* social_ai_bias       */ host_social_ai_bias,
    /* great_beelzebub      */ host_great_beelzebub,
    /* great_satan          */ host_great_satan,
    /* has_agenda           */ host_has_agenda,
    /* hq_region            */ host_hq_region,
    /* bases_ptr            */ host_bases_ptr,
    /* mod_veh_avail        */ host_mod_veh_avail,
    /* has_abil             */ host_has_abil,
    /* has_fac_built        */ host_has_fac_built,
    /* ignore_reactor_power */ host_ignore_reactor_power,
    /* long_range_artillery */ host_long_range_artillery,
    /* modify_unit_support  */ host_modify_unit_support,
    /* psi_score            */ host_psi_score,
    /* missile_units        */ host_missile_units,
    /* median_limit         */ host_median_limit,
    /* max_offense_value    */ host_max_offense_value,
    /* max_defense_value    */ host_max_defense_value,
    /* has_base_sites       */ host_has_base_sites,
    /* is_ocean             */ host_is_ocean,
    /* map_range            */ host_map_range,
    /* check_probe          */ host_check_probe,
    /* has_wmode            */ host_has_wmode,
    /* has_pact             */ host_has_pact,
    /* at_war               */ host_at_war,
    /* best_reactor         */ host_best_reactor,
    /* expansion_autoscale  */ host_expansion_autoscale,
    /* air_combat_units     */ host_air_combat_units,
    /* transport_units      */ host_transport_units,
    /* probe_units          */ host_probe_units,
    /* sea_combat_units     */ host_sea_combat_units,
    /* land_combat_units    */ host_land_combat_units,
    /* contacted_factions   */ host_contacted_factions,
    /* ocean_colony_land_site */ host_ocean_colony_land_site,
    /* vehs_ptr             */ host_vehs_ptr,
    /* game_rand_state      */ game_rand_state,
    /* mod_rand_state       */ random_state,
    /* map_rand_state       */ host_map_rand_state,
    /* game_rand_draws      */ host_game_rand_draws,
    /* mod_rng_draws        */ host_mod_rng_draws,
    /* map_rng_draws        */ host_map_rng_draws,
    /* mod_base_making      */ host_mod_base_making,
    /* skip_gov_facility_bit */ host_skip_gov_facility_bit,
    /* region_at            */ host_region_at,
    /* allow_expand         */ host_allow_expand,
    /* project_limit        */ host_project_limit,
    /* main_region          */ host_main_region,
    /* target_land_region   */ host_target_land_region,
    /* enemy_bases          */ host_enemy_bases,
    /* enemy_mil_factor     */ host_enemy_mil_factor,
    /* enemy_base_range     */ host_enemy_base_range,
    /* need_scouts          */ host_need_scouts,
    /* has_ships            */ host_has_ships,
    /* adjacent_region      */ host_adjacent_region,
    /* can_build            */ host_can_build,
    /* energy_limit         */ host_energy_limit,
    /* biology_lab_bonus    */ host_biology_lab_bonus,
    /* mod_psych_check      */ host_mod_psych_check,
    /* naval_start_x        */ host_naval_start_x,
    /* naval_start_y        */ host_naval_start_y,
    /* base_unused_space    */ host_base_unused_space,
    /* nearby_items         */ host_nearby_items,
    /* mineral_output_modifier */ host_mineral_output_modifier,
    /* clean_minerals       */ host_clean_minerals,
    /* unknown_factions     */ host_unknown_factions,
    /* has_facility         */ host_has_facility,
    /* is_alive             */ host_is_alive,
    /* enemy_odp            */ host_enemy_odp,
    /* enemy_sat            */ host_enemy_sat,
    /* satellite_goal_setting */ host_satellite_goal_setting,
    /* max_satellites       */ host_max_satellites,
    /* mil_strength         */ host_mil_strength,
    /* former_tile_tally    */ host_former_tile_tally,
    /* max_veh_num          */ host_max_veh_num,
    /* base_at              */ host_base_at,
    /* can_link_artifact    */ host_can_link_artifact,
    /* map_safety           */ host_map_safety,
    /* search_route         */ host_search_route,
    /* mod_study_artifact   */ host_mod_study_artifact,
    /* set_move_to          */ host_set_move_to,
    /* mod_veh_skip         */ host_mod_veh_skip,
};

static lua_State* L = NULL;
static FILE* lua_log = NULL;
static bool init_attempted = false;
static bool disabled_for_session = false;
static bool reload_requested = false;
static int generation = -1;
static std::unordered_set<size_t> logged_errors;

// Class 1 hook registry: hook name -> LUA_REGISTRYINDEX ref, resolved once
// per (re)load (register_hooks(), called from create_lua_state()) so
// per-turn dispatch is a single lua_rawgeti, never a per-call string
// lookup (IMPLEMENTATION_PLAN.md Phase 4.1).
static std::unordered_map<std::string, int> hook_refs;

// Runtime logging: its own file, always available (debug.txt only exists in
// debug builds), mirrored to debug.txt when that log is open.
static void lua_logf(const char* fmt, ...) {
    va_list args;
    if (lua_log) {
        va_start(args, fmt);
        vfprintf(lua_log, fmt, args);
        va_end(args);
        fflush(lua_log);
    }
    if (debug_log) {
        va_start(args, fmt);
        fprintf(debug_log, "lua: ");
        vfprintf(debug_log, fmt, args);
        va_end(args);
    }
}

static int traceback_handler(lua_State* LS) {
    const char* msg = lua_tostring(LS, 1);
    luaL_traceback(LS, LS, msg, 1);
    return 1;
}

static int host_log(lua_State* LS) {
    lua_logf("%s\n", luaL_checkstring(LS, 1));
    return 0;
}

// Verbose counterpart, gated the same way the C++ side's debug_ver() macro
// is: only writes when conf.debug_verbose is set (the Alt+M toggle,
// src/gui.cpp). Kept as its own host function rather than a flag checked
// in Lua so the AI code never needs to know about conf directly.
static int host_log_ver(lua_State* LS) {
    if (conf.debug_verbose) {
        lua_logf("%s\n", luaL_checkstring(LS, 1));
    }
    return 0;
}

static int forbidden_math_random(lua_State* LS) {
    return luaL_error(LS, "math.random/randomseed is forbidden in Lua AI"
        " scripts; determinism requires the engine RNG bindings (rand.*,"
        " Phase 3)");
}

// Opens only the libraries the AI needs (IMPLEMENTATION_DETAILS.md 2.8).
// io/os/debug/package(require) are development-build only: BUILD_DEBUG
// script authors get the escape hatch, shipped scripts never do. `ffi` is
// opened unconditionally as of Phase 3.1 (lua/ffi and lua/api need it) --
// LuaJIT has no per-module sandboxing, so "lua/ai/ never touches ffi"
// stays a lint/review convention (Phase 4.4/6's luacheck pass), not a
// runtime wall; every build has `package`/`require` disabled, so lua/
// modules load each other via the base-library `dofile`/`loadfile`
// instead (those stay available in every build).
// LuaJIT's own luaL_openlibs (lib_init.c) opens a library by pushing the
// opener as a C function with the module name as its sole argument and
// calling it — there is no luaL_requiref in this LuaJIT version (it
// predates that Lua 5.2 addition). Mirror that exact pattern here so only
// the chosen subset ends up in _G.
static void open_lib(lua_State* LS, const char* name, lua_CFunction fn) {
    lua_pushcfunction(LS, fn);
    lua_pushstring(LS, name);
    lua_call(LS, 1, 0);
}

// luaopen_ffi is different from the libraries above: LuaJIT lists it in its
// own "preload" table rather than the eagerly-global-registering set (see
// lib_ffi.c's luaopen_ffi, which literally comments "no global 'ffi'
// created!" and instead returns the module table for require() to place
// wherever it likes). Since package/require is never open in this sandbox,
// open_lib()'s 0-result call would silently discard that table -- request
// 1 result instead and set the global ourselves.
static void open_ffi(lua_State* LS) {
    lua_pushcfunction(LS, luaopen_ffi);
    lua_pushstring(LS, LUA_FFILIBNAME);
    lua_call(LS, 1, 1);
    lua_setglobal(LS, LUA_FFILIBNAME);
}

static void open_sandbox(lua_State* LS) {
    static const luaL_Reg sandboxed_libs[] = {
        {"", luaopen_base},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_BITLIBNAME, luaopen_bit},
        {NULL, NULL}
    };
    for (const luaL_Reg* lib = sandboxed_libs; lib->func; lib++) {
        open_lib(LS, lib->name, lib->func);
    }
    open_ffi(LS);
#if DEBUG
    static const luaL_Reg dev_only_libs[] = {
        {LUA_IOLIBNAME, luaopen_io},
        {LUA_OSLIBNAME, luaopen_os},
        {LUA_DBLIBNAME, luaopen_debug},
        {LUA_LOADLIBNAME, luaopen_package},
        {NULL, NULL}
    };
    for (const luaL_Reg* lib = dev_only_libs; lib->func; lib++) {
        open_lib(LS, lib->name, lib->func);
    }
#endif
    lua_getglobal(LS, LUA_MATHLIBNAME);
    lua_pushcfunction(LS, forbidden_math_random);
    lua_setfield(LS, -2, "random");
    lua_pushcfunction(LS, forbidden_math_random);
    lua_setfield(LS, -2, "randomseed");
    lua_pop(LS, 1);

    lua_register(LS, "host_log", host_log);
    lua_register(LS, "host_log_ver", host_log_ver);
}

// Applies conf.lua_strict and the once-per-(hook,turn,traceback) dedup rule.
// `hook_name` identifies the call site for the log line; with no AI hooks
// registered yet (Phase 4), the only caller today is the init.lua load step.
static void handle_lua_error(const char* hook_name, const char* traceback) {
    std::string key = std::string(hook_name) + "|" + std::to_string(*CurrentTurn)
        + "|" + (traceback ? traceback : "(no message)");
    size_t h = std::hash<std::string>{}(key);
    if (logged_errors.insert(h).second) {
        lua_logf("error in '%s' (turn %d): %s\n", hook_name, *CurrentTurn,
            traceback ? traceback : "(no message)");
    }
    if (conf.lua_strict == 1) {
        disabled_for_session = true;
        lua_logf("lua_strict=1: Lua AI disabled for the rest of the session\n");
    } else if (conf.lua_strict == 2) {
        lua_logf("lua_strict=2: aborting (development use only)\n");
        if (lua_log) {
            fclose(lua_log);
        }
        abort();
    }
}

// Loads lua/ai/init.lua (if present) and registers every entry of the
// table it returns as a Class 1 hook. Runs after lua/init.lua so the
// sandbox and every lua/api/* module it may need are already usable.
// Absence of the file (no AI hooks ported yet) is not an error -- an
// empty hook_refs just means lua_ai_hook() always reports "not handled".
static void register_hooks() {
    hook_refs.clear();

    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    if (luaL_loadfile(L, "lua/ai/init.lua") != 0 || lua_pcall(L, 0, 1, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error("lua_ai_hooks_init", msg);
        lua_settop(L, errfunc - 1);
        return;
    }
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            // key at -2, value at -1
            if (lua_type(L, -2) == LUA_TSTRING && lua_isfunction(L, -1)) {
                const char* name = lua_tostring(L, -2);
                lua_pushvalue(L, -1); // luaL_ref pops its argument
                int ref = luaL_ref(L, LUA_REGISTRYINDEX);
                hook_refs[name] = ref;
            }
            lua_pop(L, 1); // pop value, keep key for lua_next
        }
    }
    lua_settop(L, errfunc - 1);
    // TEMPORARY M4 diagnostic: confirm hooks actually registered (lua.log
    // only records errors, so silence elsewhere doesn't prove this ran).
    lua_logf("register_hooks: %d hook(s) registered\n", (int)hook_refs.size());
}

// (Re)creates the Lua state: opens the sandbox, then loads lua/init.lua.
// Used both for the first lazy init and for every later reload, so a
// failed/erroring init.lua behaves identically in both cases.
static void create_lua_state() {
    generation++;

    L = luaL_newstate();
    if (!L) {
        lua_logf("luaL_newstate failed\n");
        return;
    }
    open_sandbox(L);

    lua_pushlightuserdata(L, &g_host_api);
    lua_setglobal(L, "__host_api_ptr");

    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    if (luaL_loadfile(L, "lua/init.lua") != 0 || lua_pcall(L, 0, 0, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error("lua_ai_init", msg);
        lua_close(L);
        L = NULL;
        return;
    }
    lua_settop(L, 0);
    register_hooks();
    lua_logf("Lua AI runtime initialized (gen %d)\n", generation);
    // Echo the flags that change AI behavior/observability but produce no
    // other startup evidence in lua.log -- found live, 2026-07-16: a run's
    // own logs can't otherwise distinguish "lua_shadow=1 and zero
    // mismatches" from "lua_shadow=0 the whole time" (shadow mode restores
    // RNG state after every comparison by design, so it's not visible in
    // state_hashes.log either). One line at init removes the ambiguity.
    lua_logf("config: lua_ai=%d lua_shadow=%d lua_strict=%d autoplay=%d\n",
        conf.lua_ai, conf.lua_shadow, conf.lua_strict, conf.autoplay);
}

static void ensure_log_open() {
    if (!lua_log) {
        lua_log = fopen("lua.log", "w");
    }
}

void lua_ai_turn_upkeep() {
    if (!conf.lua_ai || disabled_for_session) {
        return;
    }
    ensure_log_open();
    if (reload_requested) {
        reload_requested = false;
        init_attempted = true;
        if (L) {
            lua_close(L);
            L = NULL;
        }
        create_lua_state();
    } else if (!init_attempted) {
        init_attempted = true;
        create_lua_state();
    }
}

void lua_ai_shutdown() {
    hook_refs.clear();
    if (L) {
        lua_close(L);
        L = NULL;
    }
    if (lua_log) {
        fclose(lua_log);
        lua_log = NULL;
    }
}

void lua_ai_request_reload() {
    reload_requested = true;
}

bool lua_ai_hook(const char* name, int* out, int out_count, std::initializer_list<int> args) {
    if (!conf.lua_ai || disabled_for_session || !L) {
        return false;
    }
    auto it = hook_refs.find(name);
    if (it == hook_refs.end()) {
        return false;
    }

    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, it->second);
    for (int arg : args) {
        lua_pushinteger(L, arg);
    }
    if (lua_pcall(L, (int)args.size(), 1, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error(name, msg);
        lua_settop(L, errfunc - 1);
        return false;
    }

    // out_count == 1: a single Lua number, as every hook before this one
    // returned. out_count > 1: a 1-indexed Lua table of out_count numbers
    // (Consolidation gate typed-descriptor generalization -- see luaai.h).
    bool handled = false;
    if (out_count == 1 && lua_isnumber(L, -1)) {
        out[0] = lua_tointeger(L, -1);
        handled = true;
    } else if (out_count > 1 && lua_istable(L, -1)) {
        handled = true;
        for (int i = 0; i < out_count; i++) {
            lua_rawgeti(L, -1, i + 1);
            if (!lua_isnumber(L, -1)) {
                handled = false;
                lua_pop(L, 1);
                break;
            }
            out[i] = lua_tointeger(L, -1);
            lua_pop(L, 1);
        }
    }
    lua_settop(L, errfunc - 1);

    // TEMPORARY M4 diagnostic: confirm each hook is actually being
    // *invoked*, not just registered (register_hooks() only proves the
    // latter). Logged once per hook name so this doesn't spam lua.log --
    // mod_tech_val can be called hundreds of times per turn.
    static std::unordered_set<std::string> logged_first_call;
    if (handled && logged_first_call.insert(name).second) {
        lua_logf("lua_ai_hook: '%s' invoked and handled (result[0]=%d)\n", name, out[0]);
    }
    return handled;
}

// Movement port, stage 0 (IMPLEMENTATION_DETAILS.md 4.12): Class 3
// (command/effect) hook dispatch -- see luaai.h's own comment for the
// contract. Structurally close to lua_ai_hook (same registry lookup,
// same pcall/traceback shape, same single-int-arg-in/single-int-out
// convention) but with no RNG snapshot/restore -- Class 3 never runs
// both sides, so there's nothing to keep aligned -- and the added
// no-fallback-after-mutation rule the loop below implements.
bool lua_ai_command_hook(const char* name, int* out, int veh_id) {
    if (!conf.lua_ai || disabled_for_session || !L) {
        return false;
    }
    auto it = hook_refs.find(name);
    if (it == hook_refs.end()) {
        return false;
    }

    g_mutation_issued = false;
    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, it->second);
    lua_pushinteger(L, veh_id);
    if (lua_pcall(L, 1, 1, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error(name, msg);
        lua_settop(L, errfunc - 1);
        if (g_mutation_issued) {
            // Real state already changed -- cannot fall back to the
            // caller's own C++ body over a partially-mutated vehicle.
            // Finish it safely instead (same veh_skip the C++ fallback
            // itself would use on an unrecoverable path).
            *out = mod_veh_skip(veh_id);
            return true;
        }
        return false;
    }

    bool handled = lua_isnumber(L, -1);
    if (handled) {
        *out = lua_tointeger(L, -1);
    }
    lua_settop(L, errfunc - 1);

    if (!handled && g_mutation_issued) {
        // Lua mutated state but returned something other than a plain
        // number -- same no-fallback rule applies; a malformed return is
        // not evidence "nothing happened" once a mutation already did.
        *out = mod_veh_skip(veh_id);
        handled = true;
    }

    static std::unordered_set<std::string> logged_first_command_call;
    if (handled && logged_first_command_call.insert(name).second) {
        lua_logf("lua_ai_command_hook: '%s' invoked and handled (result=%d)\n", name, *out);
    }
    return handled;
}

// See luaai.h for the full contract. Zero-overhead when conf.lua_shadow
// is off: returns immediately, never touches the Lua state or either RNG
// stream.
LuaShadowCall lua_ai_shadow_call(const char* name, int out_count, std::initializer_list<int> args) {
    LuaShadowCall shadow;
    if (!conf.lua_shadow) {
        return shadow;
    }
    shadow.active = true;
    for (int a : args) {
        if (shadow.arg_count >= (int)(sizeof(shadow.args) / sizeof(shadow.args[0]))) {
            break;
        }
        shadow.args[shadow.arg_count++] = a;
    }

    uint32_t saved_game_rand = game_rand_state();
    uint32_t saved_mod_rng = random_state();
    uint32_t game_draws_before = g_game_rand_draws;
    uint32_t mod_draws_before = g_mod_rng_draws;

    shadow.handled = lua_ai_hook(name, shadow.out, out_count, args);

    shadow.game_rand_draws = g_game_rand_draws - game_draws_before;
    shadow.mod_rng_draws = g_mod_rng_draws - mod_draws_before;
    // Restore both streams so the C++ computation the caller runs next
    // sees the RNG exactly as if this Lua call never happened -- Plan 5.1
    // Class 1/2 procedure, step "restore RNGs" before "run C++".
    game_rand_restore(saved_game_rand);
    random_reseed(saved_mod_rng);
    return shadow;
}

void lua_ai_shadow_check(const char* name, const LuaShadowCall& shadow,
        const int* cpp_out, int out_count) {
    if (!shadow.active || !shadow.handled) {
        return;
    }
    bool mismatch = false;
    for (int i = 0; i < out_count; i++) {
        if (shadow.out[i] != cpp_out[i]) {
            mismatch = true;
            break;
        }
    }
    if (!mismatch) {
        return;
    }
    char args_buf[96] = {0};
    char lua_buf[64] = {0};
    char cpp_buf[64] = {0};
    int pos = 0;
    for (int i = 0; i < shadow.arg_count; i++) {
        pos += snprintf(args_buf + pos, sizeof(args_buf) - pos, "%s%d", i ? "," : "", shadow.args[i]);
    }
    pos = 0;
    for (int i = 0; i < out_count; i++) {
        pos += snprintf(lua_buf + pos, sizeof(lua_buf) - pos, "%s%d", i ? "," : "", shadow.out[i]);
    }
    pos = 0;
    for (int i = 0; i < out_count; i++) {
        pos += snprintf(cpp_buf + pos, sizeof(cpp_buf) - pos, "%s%d", i ? "," : "", cpp_out[i]);
    }
    lua_logf("lua/cpp %s mismatch: args=[%s] lua=[%s] cpp=[%s] rng_draws: game=%u mod=%u\n",
        name, args_buf, lua_buf, cpp_buf, shadow.game_rand_draws, shadow.mod_rng_draws);
}
