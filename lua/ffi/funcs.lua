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
    int32_t (*mod_base_making)(int32_t item_id, int32_t base_id);
    int32_t (*skip_gov_facility_bit)(int32_t item_id);
    int32_t (*region_at)(int32_t x, int32_t y);
    int32_t (*allow_expand)(int32_t faction_id);
    int32_t (*project_limit)(int32_t faction_id);
    int32_t (*main_region)(int32_t faction_id);
    int32_t (*target_land_region)(int32_t faction_id);
    int32_t (*enemy_bases)(int32_t faction_id);
    float (*enemy_mil_factor)(int32_t faction_id);
    float (*enemy_base_range)(int32_t faction_id);
    int32_t (*need_scouts)(int32_t base_id, int32_t triad);
    int32_t (*has_ships)(int32_t faction_id);
    int32_t (*adjacent_region)(int32_t x, int32_t y, int32_t owner, int32_t threshold, int32_t ocean);
    int32_t (*can_build)(int32_t base_id, int32_t item_id);
    int32_t (*energy_limit)(int32_t faction_id);
    int32_t (*biology_lab_bonus)();
    void (*mod_psych_check)(int32_t faction_id, int32_t* content_pop, int32_t* base_limit);
    int32_t (*naval_start_x)(int32_t faction_id);
    int32_t (*naval_start_y)(int32_t faction_id);
    int32_t (*base_unused_space)(int32_t base_id);
    int32_t (*nearby_items)(int32_t x, int32_t y, int32_t start_index, int32_t end_index, uint32_t item);
    int32_t (*mineral_output_modifier)(int32_t base_id);
    int32_t (*clean_minerals)();
    int32_t (*unknown_factions)(int32_t faction_id);
    int32_t (*has_facility)(int32_t item_id, int32_t base_id);
    int32_t (*is_alive)(int32_t faction_id);
    int32_t (*enemy_odp)(int32_t faction_id);
    int32_t (*enemy_sat)(int32_t faction_id);
    int32_t (*satellite_goal_setting)(int32_t faction_id);
    int32_t (*max_satellites)();
    int32_t (*mil_strength)(int32_t faction_id);
    void (*former_tile_tally)(int32_t base_id, int32_t* num, int32_t* sea);
    int32_t (*max_veh_num)();
    int32_t (*base_at)(int32_t x, int32_t y);
    int32_t (*can_link_artifact)(int32_t base_id);
    int32_t (*map_safety)(int32_t x, int32_t y);
    void (*search_route)(int32_t veh_id, int32_t x, int32_t y,
        int32_t* found, int32_t* tx, int32_t* ty);
    int32_t (*mod_study_artifact)(int32_t veh_id);
    int32_t (*set_move_to)(int32_t veh_id, int32_t x, int32_t y);
    int32_t (*mod_veh_skip)(int32_t veh_id);
    void (*crawler_home_base_check)(int32_t veh_id, int32_t* applicable, int32_t* action);
    void (*crawler_at_target_check)(int32_t veh_id, int32_t* applicable, int32_t* action);
    void (*mark_convoy_site)(int32_t x, int32_t y);
    int32_t (*set_convoy)(int32_t veh_id, int32_t res);
    int32_t (*move_to_base)(int32_t veh_id, int32_t ally);
    int32_t (*mod_crop_yield)(int32_t faction_id, int32_t base_id, int32_t x, int32_t y, int32_t flag);
    int32_t (*mod_mine_yield)(int32_t faction_id, int32_t base_id, int32_t x, int32_t y, int32_t flag);
    int32_t (*mod_energy_yield)(int32_t faction_id, int32_t base_id, int32_t x, int32_t y, int32_t flag);
    int32_t (*tile_is_base)(int32_t x, int32_t y);
    int32_t (*tile_owner)(int32_t x, int32_t y);
    int32_t (*tile_is_base_radius)(int32_t x, int32_t y);
    int32_t (*project_base)(int32_t item_id);
    void (*crawler_search_start)(int32_t veh_id, int32_t limit);
    void (*crawler_search_next)(int32_t faction_id, int32_t* valid,
        int32_t* tx, int32_t* ty, int32_t* dist);
} LuaHostApi;
]]

local HOST_API_VERSION = 26

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
    mod_base_making = function(item_id, base_id) return api.mod_base_making(item_id, base_id) end,
    skip_gov_facility_bit = function(item_id) return api.skip_gov_facility_bit(item_id) end,
    region_at = function(x, y) return api.region_at(x, y) end,
    allow_expand = function(faction_id) return api.allow_expand(faction_id) ~= 0 end,
    project_limit = function(faction_id) return api.project_limit(faction_id) end,
    main_region = function(faction_id) return api.main_region(faction_id) end,
    target_land_region = function(faction_id) return api.target_land_region(faction_id) end,
    enemy_bases = function(faction_id) return api.enemy_bases(faction_id) end,
    enemy_mil_factor = function(faction_id) return api.enemy_mil_factor(faction_id) end,
    enemy_base_range = function(faction_id) return api.enemy_base_range(faction_id) end,
    need_scouts = function(base_id, triad) return api.need_scouts(base_id, triad) ~= 0 end,
    has_ships = function(faction_id) return api.has_ships(faction_id) ~= 0 end,
    adjacent_region = function(x, y, owner, threshold, ocean)
        return api.adjacent_region(x, y, owner, threshold, ocean) ~= 0
    end,
    can_build = function(base_id, item_id) return api.can_build(base_id, item_id) ~= 0 end,
    energy_limit = function(faction_id) return api.energy_limit(faction_id) end,
    biology_lab_bonus = function() return api.biology_lab_bonus() end,
    mod_psych_check = function(faction_id, content_pop, base_limit)
        return api.mod_psych_check(faction_id, content_pop, base_limit)
    end,
    naval_start_x = function(faction_id) return api.naval_start_x(faction_id) end,
    naval_start_y = function(faction_id) return api.naval_start_y(faction_id) end,
    base_unused_space = function(base_id) return api.base_unused_space(base_id) end,
    nearby_items = function(x, y, start_index, end_index, item)
        return api.nearby_items(x, y, start_index, end_index, item)
    end,
    mineral_output_modifier = function(base_id) return api.mineral_output_modifier(base_id) end,
    clean_minerals = function() return api.clean_minerals() end,
    unknown_factions = function(faction_id) return api.unknown_factions(faction_id) end,
    has_facility = function(item_id, base_id) return api.has_facility(item_id, base_id) end,
    is_alive = function(faction_id) return api.is_alive(faction_id) end,
    enemy_odp = function(faction_id) return api.enemy_odp(faction_id) end,
    enemy_sat = function(faction_id) return api.enemy_sat(faction_id) end,
    satellite_goal_setting = function(faction_id) return api.satellite_goal_setting(faction_id) end,
    max_satellites = function() return api.max_satellites() end,
    mil_strength = function(faction_id) return api.mil_strength(faction_id) end,
    former_tile_tally = function(base_id, num, sea)
        return api.former_tile_tally(base_id, num, sea)
    end,
    max_veh_num = function() return api.max_veh_num() end,
    base_at = function(x, y) return api.base_at(x, y) end,
    can_link_artifact = function(base_id) return api.can_link_artifact(base_id) ~= 0 end,
    map_safety = function(x, y) return api.map_safety(x, y) end,
    search_route = function(veh_id, x, y, found, tx, ty)
        return api.search_route(veh_id, x, y, found, tx, ty)
    end,
    mod_study_artifact = function(veh_id) return api.mod_study_artifact(veh_id) end,
    set_move_to = function(veh_id, x, y) return api.set_move_to(veh_id, x, y) end,
    mod_veh_skip = function(veh_id) return api.mod_veh_skip(veh_id) end,
    crawler_home_base_check = function(veh_id, applicable, action)
        return api.crawler_home_base_check(veh_id, applicable, action)
    end,
    crawler_at_target_check = function(veh_id, applicable, action)
        return api.crawler_at_target_check(veh_id, applicable, action)
    end,
    mark_convoy_site = function(x, y) return api.mark_convoy_site(x, y) end,
    set_convoy = function(veh_id, res) return api.set_convoy(veh_id, res) end,
    move_to_base = function(veh_id, ally) return api.move_to_base(veh_id, ally) end,
    mod_crop_yield = function(faction_id, base_id, x, y, flag)
        return api.mod_crop_yield(faction_id, base_id, x, y, flag)
    end,
    mod_mine_yield = function(faction_id, base_id, x, y, flag)
        return api.mod_mine_yield(faction_id, base_id, x, y, flag)
    end,
    mod_energy_yield = function(faction_id, base_id, x, y, flag)
        return api.mod_energy_yield(faction_id, base_id, x, y, flag)
    end,
    tile_is_base = function(x, y) return api.tile_is_base(x, y) ~= 0 end,
    tile_owner = function(x, y) return api.tile_owner(x, y) end,
    tile_is_base_radius = function(x, y) return api.tile_is_base_radius(x, y) ~= 0 end,
    project_base = function(item_id) return api.project_base(item_id) end,
    crawler_search_start = function(veh_id, limit) return api.crawler_search_start(veh_id, limit) end,
    crawler_search_next = function(faction_id, valid, tx, ty, dist)
        return api.crawler_search_next(faction_id, valid, tx, ty, dist)
    end,
}
