-- LuaHostApi binding (IMPLEMENTATION_PLAN.md Phase 3.1/3.2). Unlike
-- lua/ffi/types.lua (generated, mirrors opaque engine memory), this cdef
-- is small and hand-written: LuaHostApi is a type we fully control
-- (defined in src/luaai.h), not a projection of an engine struct.
--
-- src/luaai.cpp pushes a `LuaHostApi*` as a lightuserdata global
-- (`__host_api_ptr`) before loading init.lua. Load via dofile_once (see
-- lua/init.lua) -- the ffi.cdef below can only run once per Lua state,
-- and this file now has multiple callers (lua/api/faction.lua,
-- lua/api/tech.lua, lua/api/map.lua).
ffi.cdef[[
typedef struct {
    uint32_t api_version;
    int32_t (*rand_game)(int32_t value);
    int32_t (*rand_map)(int32_t low, int32_t high);
    bool (*is_human)(int32_t faction_id);
    int32_t (*has_treaty)(int32_t faction_id_1, int32_t faction_id_2, uint32_t status);
    int32_t (*climactic_battle)();
    int32_t (*mod_wants_to_attack)(int32_t faction_id, int32_t faction_id_tgt, int32_t faction_id_unk);
    int32_t (*has_tech)(int32_t tech_id, int32_t faction_id);
    int32_t (*tech_level)(int32_t tech_id, int32_t lvl);
    int32_t (*mod_tech_avail)(int32_t tech_id, int32_t faction_id);
    int32_t (*tech_is_preq)(int32_t preq_tech_id, int32_t parent_tech_id, int32_t range);
    int32_t (*bad_reg)(int32_t region);
    bool (*revised_tech_cost)();
    int32_t (*tech_balance_enabled)();
    void (*social_calc)(const int32_t* models, int32_t faction_id, int32_t* out_values);
    int32_t (*society_avail)(int32_t sf, int32_t sm, int32_t faction_id);
    int32_t (*social_upheaval)(int32_t faction_id, const int32_t* models);
    bool (*has_project)(int32_t item_id, int32_t faction_id);
    bool (*has_free_facility)(int32_t item_id, int32_t faction_id);
    bool (*has_aircraft)(int32_t faction_id);
    int32_t (*mineral_factor)(int32_t faction_id, int32_t se_industry);
    bool (*un_charter)();
    int32_t (*defense_modifier)(int32_t faction_id);
    int32_t (*keep_fungus)(int32_t faction_id);
    int32_t (*social_ai_bias)();
    int32_t (*great_beelzebub)(int32_t faction_id, int32_t is_aggressive);
    int32_t (*great_satan)(int32_t faction_id, int32_t is_aggressive);
    int32_t (*has_agenda)(int32_t faction_id_1, int32_t faction_id_2, uint32_t status);
    int32_t (*hq_region)(int32_t faction_id);
    int32_t (*bases_ptr)();
    int32_t (*mod_veh_avail)(int32_t unit_id, int32_t faction_id, int32_t base_id);
    int32_t (*has_abil)(int32_t unit_id, uint32_t ability);
    int32_t (*has_fac_built)(int32_t item_id, int32_t base_id);
    int32_t (*ignore_reactor_power)();
    int32_t (*long_range_artillery)();
    int32_t (*modify_unit_support)();
    int32_t (*psi_score)(int32_t faction_id);
    int32_t (*missile_units)(int32_t faction_id);
    int32_t (*median_limit)(int32_t faction_id);
    int32_t (*max_offense_value)(int32_t faction_id);
    int32_t (*max_defense_value)(int32_t faction_id);
    int32_t (*has_base_sites)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*is_ocean)(int32_t base_id);
    int32_t (*map_range)(int32_t x1, int32_t y1, int32_t x2, int32_t y2);
    int32_t (*check_probe)(int32_t base_id, int32_t triad);
    int32_t (*has_wmode)(int32_t faction_id, int32_t mode);
    int32_t (*has_pact)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*at_war)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*best_reactor)(int32_t faction_id);
    int32_t (*expansion_autoscale)();
    int32_t (*air_combat_units)(int32_t faction_id);
    int32_t (*transport_units)(int32_t faction_id);
    int32_t (*probe_units)(int32_t faction_id);
    int32_t (*sea_combat_units)(int32_t faction_id);
    int32_t (*land_combat_units)(int32_t faction_id);
    int32_t (*contacted_factions)(int32_t faction_id);
    int32_t (*ocean_colony_land_site)(int32_t base_id, int32_t land);
    int32_t (*vehs_ptr)();
    uint32_t (*game_rand_state)();
    uint32_t (*mod_rand_state)();
    uint32_t (*map_rand_state)();
    uint32_t (*game_rand_draws)();
    uint32_t (*mod_rng_draws)();
    uint32_t (*map_rng_draws)();
} LuaHostApi;
]]

local HOST_API_VERSION = 9

local api = ffi.cast("LuaHostApi*", __host_api_ptr)
assert(api.api_version == HOST_API_VERSION, string.format(
    "LuaHostApi version mismatch: host is %d, lua/ffi/funcs.lua expects %d",
    api.api_version, HOST_API_VERSION))

return {
    rand_game = function(value) return api.rand_game(value) end,
    rand_map = function(low, high) return api.rand_map(low, high) end,
    is_human = function(faction_id) return api.is_human(faction_id) end,
    has_treaty = function(f1, f2, status) return api.has_treaty(f1, f2, status) end,
    climactic_battle = function() return api.climactic_battle() end,
    mod_wants_to_attack = function(f, tgt, unk) return api.mod_wants_to_attack(f, tgt, unk) end,
    has_tech = function(tech_id, faction_id) return api.has_tech(tech_id, faction_id) end,
    tech_level = function(tech_id, lvl) return api.tech_level(tech_id, lvl) end,
    mod_tech_avail = function(tech_id, faction_id) return api.mod_tech_avail(tech_id, faction_id) end,
    tech_is_preq = function(preq, parent, range) return api.tech_is_preq(preq, parent, range) end,
    bad_reg = function(region) return api.bad_reg(region) end,
    revised_tech_cost = function() return api.revised_tech_cost() end,
    tech_balance_enabled = function() return api.tech_balance_enabled() end,
    social_calc = function(models, faction_id, out_values) return api.social_calc(models, faction_id, out_values) end,
    society_avail = function(sf, sm, faction_id) return api.society_avail(sf, sm, faction_id) end,
    social_upheaval = function(faction_id, models) return api.social_upheaval(faction_id, models) end,
    has_project = function(item_id, faction_id) return api.has_project(item_id, faction_id) end,
    has_free_facility = function(item_id, faction_id) return api.has_free_facility(item_id, faction_id) end,
    has_aircraft = function(faction_id) return api.has_aircraft(faction_id) end,
    mineral_factor = function(faction_id, se_industry) return api.mineral_factor(faction_id, se_industry) end,
    un_charter = function() return api.un_charter() end,
    defense_modifier = function(faction_id) return api.defense_modifier(faction_id) end,
    keep_fungus = function(faction_id) return api.keep_fungus(faction_id) end,
    social_ai_bias = function() return api.social_ai_bias() end,
    great_beelzebub = function(faction_id, is_aggressive) return api.great_beelzebub(faction_id, is_aggressive) end,
    great_satan = function(faction_id, is_aggressive) return api.great_satan(faction_id, is_aggressive) end,
    has_agenda = function(f1, f2, status) return api.has_agenda(f1, f2, status) end,
    hq_region = function(faction_id) return api.hq_region(faction_id) end,
    bases_ptr = function() return api.bases_ptr() end,
    mod_veh_avail = function(unit_id, faction_id, base_id) return api.mod_veh_avail(unit_id, faction_id, base_id) end,
    has_abil = function(unit_id, ability) return api.has_abil(unit_id, ability) end,
    has_fac_built = function(item_id, base_id) return api.has_fac_built(item_id, base_id) end,
    ignore_reactor_power = function() return api.ignore_reactor_power() end,
    long_range_artillery = function() return api.long_range_artillery() end,
    modify_unit_support = function() return api.modify_unit_support() end,
    psi_score = function(faction_id) return api.psi_score(faction_id) end,
    missile_units = function(faction_id) return api.missile_units(faction_id) end,
    median_limit = function(faction_id) return api.median_limit(faction_id) end,
    max_offense_value = function(faction_id) return api.max_offense_value(faction_id) end,
    max_defense_value = function(faction_id) return api.max_defense_value(faction_id) end,
    has_base_sites = function(x, y, faction_id, triad) return api.has_base_sites(x, y, faction_id, triad) end,
    is_ocean = function(base_id) return api.is_ocean(base_id) end,
    map_range = function(x1, y1, x2, y2) return api.map_range(x1, y1, x2, y2) end,
    check_probe = function(base_id, triad) return api.check_probe(base_id, triad) end,
    has_wmode = function(faction_id, mode) return api.has_wmode(faction_id, mode) end,
    has_pact = function(f1, f2) return api.has_pact(f1, f2) end,
    at_war = function(f1, f2) return api.at_war(f1, f2) end,
    best_reactor = function(faction_id) return api.best_reactor(faction_id) end,
    expansion_autoscale = function() return api.expansion_autoscale() end,
    air_combat_units = function(faction_id) return api.air_combat_units(faction_id) end,
    transport_units = function(faction_id) return api.transport_units(faction_id) end,
    probe_units = function(faction_id) return api.probe_units(faction_id) end,
    sea_combat_units = function(faction_id) return api.sea_combat_units(faction_id) end,
    land_combat_units = function(faction_id) return api.land_combat_units(faction_id) end,
    contacted_factions = function(faction_id) return api.contacted_factions(faction_id) end,
    ocean_colony_land_site = function(base_id, land) return api.ocean_colony_land_site(base_id, land) end,
    vehs_ptr = function() return api.vehs_ptr() end,
    game_rand_state = function() return api.game_rand_state() end,
    mod_rand_state = function() return api.mod_rand_state() end,
    map_rand_state = function() return api.map_rand_state() end,
    game_rand_draws = function() return api.game_rand_draws() end,
    mod_rng_draws = function() return api.mod_rng_draws() end,
    map_rng_draws = function() return api.map_rng_draws() end,
}
