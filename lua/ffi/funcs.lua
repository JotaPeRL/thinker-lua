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
    int32_t (*map_target)(int32_t x, int32_t y);
    uint32_t (*tile_items)(int32_t x, int32_t y);
    int32_t (*tile_is_rocky)(int32_t x, int32_t y);
    int32_t (*has_map_node)(int32_t x, int32_t y, int32_t node_type);
    void (*mark_map_node)(int32_t x, int32_t y, int32_t node_type);
    int32_t (*veh_need_monolith)(int32_t veh_id);
    int32_t (*veh_need_refuel)(int32_t veh_id);
    int32_t (*veh_speed)(int32_t veh_id, int32_t skip_morale);
    int32_t (*allow_move)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*non_ally_in_tile)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*defend_tile)(int32_t veh_id);
    int32_t (*set_order_none)(int32_t veh_id);
    void (*search_escape_start)(int32_t veh_id);
    void (*search_escape_next)(int32_t faction_id, int32_t* valid,
        int32_t* tx, int32_t* ty, int32_t* dist);
    void (*search_base_start)(int32_t veh_id, int32_t ally,
        int32_t* already_there, int32_t* max_dist);
    void (*search_base_next)(int32_t faction_id, int32_t triad, int32_t ally, int32_t found,
        int32_t* kind, int32_t* tx, int32_t* ty, int32_t* dist);
    int32_t (*tile_alt_level)(int32_t x, int32_t y);
    int32_t (*tile_bonus)(int32_t x, int32_t y);
    uint32_t (*tile_lm_items)(int32_t x, int32_t y);
    int32_t (*tile_is_land_region)(int32_t x, int32_t y);
    int32_t (*tile_region)(int32_t x, int32_t y);
    int32_t (*tile_is_rainy)(int32_t x, int32_t y);
    int32_t (*tile_is_moist)(int32_t x, int32_t y);
    int32_t (*tile_is_rolling)(int32_t x, int32_t y);
    int32_t (*both_non_enemy)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*ocean_coast_tiles)(int32_t x, int32_t y);
    int32_t (*can_build_base)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*near_ocean_coast)(int32_t x, int32_t y);
    int32_t (*has_transport)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*allow_civ_move)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*can_airdrop)(int32_t veh_id);
    int32_t (*drop_range)(int32_t faction_id);
    int32_t (*allow_airdrop)(int32_t x, int32_t y, int32_t faction_id, int32_t combat);
    int32_t (*action_airdrop)(int32_t veh_id, int32_t tx, int32_t ty, int32_t flags);
    int32_t (*mod_veh_kill)(int32_t veh_id);
    int32_t (*path_cost)(int32_t x1, int32_t y1, int32_t x2, int32_t y2,
        int32_t unit_id, int32_t faction_id, int32_t max_cost);
    int32_t (*invasion_unit)(int32_t veh_id);
    int32_t (*net_action_build)(int32_t veh_id);
    void (*connect_roads)(int32_t x, int32_t y, int32_t faction_id);
    void (*colony_search_start)(int32_t veh_id, int32_t skip_owner,
        int32_t* airdrop, int32_t* veh_region, int32_t* triad);
    void (*colony_search_next)(int32_t faction_id, int32_t triad, int32_t skip_owner,
        int32_t airdrop, int32_t veh_region,
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist);
    int32_t (*tile_neighbor)(int32_t x, int32_t y, int32_t i, int32_t* tx, int32_t* ty);
    void (*mark_base_site_radius)(int32_t x, int32_t y);
    void (*set_colony_automation_flags)(int32_t veh_id);
    void (*colony_transport_check)(int32_t veh_id, int32_t* has_transport,
        int32_t* tx, int32_t* ty);
    int32_t (*tile_is_visible)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*tile_is_ocean)(int32_t x, int32_t y);
    int32_t (*can_use_teleport)(int32_t base_id);
    int32_t (*net_action_gate)(int32_t veh_id, int32_t base_id);
    int32_t (*main_region_x)(int32_t faction_id);
    int32_t (*main_region_y)(int32_t faction_id);
    int32_t (*naval_end_x)(int32_t faction_id);
    int32_t (*naval_end_y)(int32_t faction_id);
    int32_t (*tile_is_fungus)(int32_t x, int32_t y);
    int32_t (*cargo_capacity)(int32_t x, int32_t y, int32_t faction_id);
    void (*route_search_sea_start)(int32_t veh_id);
    void (*route_search_sea_next)(int32_t faction_id,
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist);
    void (*route_search_pact_start)(int32_t veh_id);
    void (*route_search_pact_next)(int32_t faction_id, int32_t combat, int32_t scout,
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* naval_pick, int32_t* is_base_safe);
    void (*route_search_naval_seed)(int32_t veh_id, int32_t px, int32_t py,
        int32_t* redirect, int32_t* tx, int32_t* ty);
    void (*route_search_naval_pickup_start)();
    void (*route_search_naval_pickup_next)(
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* prev_x, int32_t* prev_y);
    void (*add_goal)(int32_t faction_id, int32_t type, int32_t priority,
        int32_t x, int32_t y, int32_t base_id);
    int32_t (*has_terra)(int32_t item_id, int32_t ocean, int32_t faction_id);
    int32_t (*coast_tiles)(int32_t x, int32_t y);
    int32_t (*both_neutral)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*map_former)(int32_t x, int32_t y);
    int32_t (*map_roads)(int32_t x, int32_t y);
    int32_t (*tile_near8)(int32_t x, int32_t y, int32_t i, int32_t* tx, int32_t* ty);
    int32_t (*tile_output_limit_nutrient)();
    int32_t (*can_bridge)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*plant_fungus_flag)(int32_t faction_id);
    int32_t (*build_tubes)(int32_t faction_id);
    int32_t (*tile_is_volcano_center)(int32_t x, int32_t y);
    int32_t (*terraform_cost)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*item_yield)(int32_t x, int32_t y, int32_t faction_id, int32_t bonus, int32_t item);
    int32_t (*bonus_yield)(int32_t res_type);
    void (*former_search_start)(int32_t veh_id);
    void (*former_search_next)(int32_t* valid, int32_t* tx, int32_t* ty);
    void (*former_consume)(int32_t x, int32_t y);
    int32_t (*former_apply_action)(int32_t veh_id, int32_t item);
    void (*former_request_new_orders)(int32_t veh_id);
    int32_t (*reg_enemy_at)(int32_t region, int32_t is_probe);
    int32_t (*veh_cargo)(int32_t veh_id);
    int32_t (*veh_need_heals)(int32_t veh_id);
    void (*veh_wake)(int32_t veh_id);
    int32_t (*unmark_map_node)(int32_t x, int32_t y, int32_t node_type);
    void (*set_board_to)(int32_t veh_id, int32_t trans_veh_id);
    int32_t (*tile_veh_who)(int32_t x, int32_t y);
    int32_t (*map_unit_near)(int32_t x, int32_t y);
    int32_t (*choose_defender)(int32_t x, int32_t y, int32_t veh_id_atk);
    double (*battle_priority)(int32_t veh_id_atk, int32_t veh_id_def, int32_t dist, int32_t moves,
        int32_t x, int32_t y);
    int32_t (*goody_at)(int32_t x, int32_t y);
    int32_t (*allow_scout)(int32_t faction_id, int32_t x, int32_t y);
    void (*trans_search_start)(int32_t veh_id);
    void (*trans_search_next)(int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist);
    int32_t (*map_enemy)(int32_t x, int32_t y);
    int32_t (*map_enemy_near)(int32_t x, int32_t y);
    int32_t (*map_enemy_dist)(int32_t x, int32_t y);
    int32_t (*is_objective)(int32_t base_id);
    int32_t (*veh_high_damage)(int32_t veh_id);
    int32_t (*enemy_factions)(int32_t faction_id);
    int32_t (*mod_stack_check)(int32_t veh_id, int32_t type, int32_t cond1, int32_t cond2,
        int32_t cond3);
    int32_t (*mod_zoc_move)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*has_orbital_drops)(int32_t faction_id);
    int32_t (*veh_at)(int32_t x, int32_t y);
    void (*map_target_incr)(int32_t x, int32_t y);
    int32_t (*map_enemy_rank)(int32_t x, int32_t y);
    int32_t (*map_flags)(int32_t x, int32_t y);
    int32_t (*can_arty)(int32_t unit_id, int32_t arty);
    int32_t (*arty_range)(int32_t unit_id);
    int32_t (*arty_table_range)(int32_t unit_id);
    int32_t (*tile_is_airbase)(int32_t x, int32_t y);
    int32_t (*veh_mid_damage)(int32_t veh_id);
    void (*update_move_path)(int32_t veh_id, int32_t tx, int32_t ty);
    int32_t (*net_action_destroy)(int32_t veh_id, int32_t flag, int32_t x, int32_t y);
    int32_t (*mod_battle_fight)(int32_t veh_id, int32_t offset, int32_t table_offset,
        int32_t option);
    int32_t (*probe_action)(int32_t veh_id, int32_t tgt_base_id, int32_t tgt_veh_id, int32_t toggle);
    void (*combat_search_start)(int32_t veh_id, int32_t ts_type, int32_t ts_skip);
    void (*combat_search_next)(int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* prev_x, int32_t* prev_y);
    int32_t (*combat_search_has_zoc)(int32_t faction_id);
    int32_t (*main_sea_region)(int32_t faction_id);
    int32_t (*naval_airbase_x)(int32_t faction_id);
    int32_t (*naval_airbase_y)(int32_t faction_id);
    int32_t (*naval_scout_x)(int32_t faction_id);
    int32_t (*naval_scout_y)(int32_t faction_id);
    int32_t (*prioritize_naval)(int32_t faction_id);
} LuaHostApi;
]]

local HOST_API_VERSION = 40

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
    map_target = function(x, y) return api.map_target(x, y) end,
    tile_items = function(x, y) return api.tile_items(x, y) end,
    tile_is_rocky = function(x, y) return api.tile_is_rocky(x, y) ~= 0 end,
    has_map_node = function(x, y, node_type) return api.has_map_node(x, y, node_type) ~= 0 end,
    mark_map_node = function(x, y, node_type) return api.mark_map_node(x, y, node_type) end,
    veh_need_monolith = function(veh_id) return api.veh_need_monolith(veh_id) ~= 0 end,
    veh_need_refuel = function(veh_id) return api.veh_need_refuel(veh_id) ~= 0 end,
    veh_speed = function(veh_id, skip_morale) return api.veh_speed(veh_id, skip_morale) end,
    allow_move = function(x, y, faction_id, triad) return api.allow_move(x, y, faction_id, triad) ~= 0 end,
    non_ally_in_tile = function(x, y, faction_id) return api.non_ally_in_tile(x, y, faction_id) ~= 0 end,
    defend_tile = function(veh_id) return api.defend_tile(veh_id) ~= 0 end,
    set_order_none = function(veh_id) return api.set_order_none(veh_id) end,
    search_escape_start = function(veh_id) return api.search_escape_start(veh_id) end,
    search_escape_next = function(faction_id, valid, tx, ty, dist)
        return api.search_escape_next(faction_id, valid, tx, ty, dist)
    end,
    search_base_start = function(veh_id, ally, already_there, max_dist)
        return api.search_base_start(veh_id, ally, already_there, max_dist)
    end,
    search_base_next = function(faction_id, triad, ally, found, kind, tx, ty, dist)
        return api.search_base_next(faction_id, triad, ally, found, kind, tx, ty, dist)
    end,
    tile_alt_level = function(x, y) return api.tile_alt_level(x, y) end,
    tile_bonus = function(x, y) return api.tile_bonus(x, y) end,
    tile_lm_items = function(x, y) return api.tile_lm_items(x, y) end,
    tile_is_land_region = function(x, y) return api.tile_is_land_region(x, y) ~= 0 end,
    tile_region = function(x, y) return api.tile_region(x, y) end,
    tile_is_rainy = function(x, y) return api.tile_is_rainy(x, y) ~= 0 end,
    tile_is_moist = function(x, y) return api.tile_is_moist(x, y) ~= 0 end,
    tile_is_rolling = function(x, y) return api.tile_is_rolling(x, y) ~= 0 end,
    both_non_enemy = function(f1, f2) return api.both_non_enemy(f1, f2) ~= 0 end,
    ocean_coast_tiles = function(x, y) return api.ocean_coast_tiles(x, y) end,
    can_build_base = function(x, y, faction_id, triad) return api.can_build_base(x, y, faction_id, triad) ~= 0 end,
    near_ocean_coast = function(x, y) return api.near_ocean_coast(x, y) ~= 0 end,
    has_transport = function(x, y, faction_id) return api.has_transport(x, y, faction_id) ~= 0 end,
    allow_civ_move = function(x, y, faction_id, triad) return api.allow_civ_move(x, y, faction_id, triad) ~= 0 end,
    can_airdrop = function(veh_id) return api.can_airdrop(veh_id) ~= 0 end,
    drop_range = function(faction_id) return api.drop_range(faction_id) end,
    allow_airdrop = function(x, y, faction_id, combat)
        return api.allow_airdrop(x, y, faction_id, combat) ~= 0
    end,
    action_airdrop = function(veh_id, tx, ty, flags) return api.action_airdrop(veh_id, tx, ty, flags) end,
    mod_veh_kill = function(veh_id) return api.mod_veh_kill(veh_id) end,
    path_cost = function(x1, y1, x2, y2, unit_id, faction_id, max_cost)
        return api.path_cost(x1, y1, x2, y2, unit_id, faction_id, max_cost)
    end,
    invasion_unit = function(veh_id) return api.invasion_unit(veh_id) ~= 0 end,
    net_action_build = function(veh_id) return api.net_action_build(veh_id) end,
    connect_roads = function(x, y, faction_id) return api.connect_roads(x, y, faction_id) end,
    colony_search_start = function(veh_id, skip_owner, airdrop, veh_region, triad)
        return api.colony_search_start(veh_id, skip_owner, airdrop, veh_region, triad)
    end,
    colony_search_next = function(faction_id, triad, skip_owner, airdrop, veh_region, valid, tx, ty, dist)
        return api.colony_search_next(faction_id, triad, skip_owner, airdrop, veh_region, valid, tx, ty, dist)
    end,
    tile_neighbor = function(x, y, i, tx, ty) return api.tile_neighbor(x, y, i, tx, ty) ~= 0 end,
    mark_base_site_radius = function(x, y) return api.mark_base_site_radius(x, y) end,
    set_colony_automation_flags = function(veh_id) return api.set_colony_automation_flags(veh_id) end,
    colony_transport_check = function(veh_id, has_transport, tx, ty)
        return api.colony_transport_check(veh_id, has_transport, tx, ty)
    end,
    tile_is_visible = function(x, y, faction_id) return api.tile_is_visible(x, y, faction_id) ~= 0 end,
    tile_is_ocean = function(x, y) return api.tile_is_ocean(x, y) ~= 0 end,
    can_use_teleport = function(base_id) return api.can_use_teleport(base_id) ~= 0 end,
    net_action_gate = function(veh_id, base_id) return api.net_action_gate(veh_id, base_id) end,
    main_region_x = function(faction_id) return api.main_region_x(faction_id) end,
    main_region_y = function(faction_id) return api.main_region_y(faction_id) end,
    naval_end_x = function(faction_id) return api.naval_end_x(faction_id) end,
    naval_end_y = function(faction_id) return api.naval_end_y(faction_id) end,
    tile_is_fungus = function(x, y) return api.tile_is_fungus(x, y) ~= 0 end,
    cargo_capacity = function(x, y, faction_id) return api.cargo_capacity(x, y, faction_id) end,
    route_search_sea_start = function(veh_id) return api.route_search_sea_start(veh_id) end,
    route_search_sea_next = function(faction_id, valid, tx, ty, dist)
        return api.route_search_sea_next(faction_id, valid, tx, ty, dist)
    end,
    route_search_pact_start = function(veh_id) return api.route_search_pact_start(veh_id) end,
    route_search_pact_next = function(faction_id, combat, scout, valid, tx, ty, dist, naval_pick, is_base_safe)
        return api.route_search_pact_next(faction_id, combat, scout, valid, tx, ty, dist, naval_pick, is_base_safe)
    end,
    route_search_naval_seed = function(veh_id, px, py, redirect, tx, ty)
        return api.route_search_naval_seed(veh_id, px, py, redirect, tx, ty)
    end,
    route_search_naval_pickup_start = function() return api.route_search_naval_pickup_start() end,
    route_search_naval_pickup_next = function(valid, tx, ty, dist, prev_x, prev_y)
        return api.route_search_naval_pickup_next(valid, tx, ty, dist, prev_x, prev_y)
    end,
    add_goal = function(faction_id, type, priority, x, y, base_id)
        return api.add_goal(faction_id, type, priority, x, y, base_id)
    end,
    has_terra = function(item_id, ocean, faction_id) return api.has_terra(item_id, ocean, faction_id) ~= 0 end,
    coast_tiles = function(x, y) return api.coast_tiles(x, y) end,
    both_neutral = function(faction_id_1, faction_id_2) return api.both_neutral(faction_id_1, faction_id_2) ~= 0 end,
    map_former = function(x, y) return api.map_former(x, y) end,
    map_roads = function(x, y) return api.map_roads(x, y) end,
    tile_near8 = function(x, y, i, tx, ty) return api.tile_near8(x, y, i, tx, ty) ~= 0 end,
    tile_output_limit_nutrient = function() return api.tile_output_limit_nutrient() end,
    can_bridge = function(x, y, faction_id) return api.can_bridge(x, y, faction_id) ~= 0 end,
    plant_fungus_flag = function(faction_id) return api.plant_fungus_flag(faction_id) end,
    build_tubes = function(faction_id) return api.build_tubes(faction_id) end,
    tile_is_volcano_center = function(x, y) return api.tile_is_volcano_center(x, y) ~= 0 end,
    terraform_cost = function(x, y, faction_id) return api.terraform_cost(x, y, faction_id) end,
    item_yield = function(x, y, faction_id, bonus, item) return api.item_yield(x, y, faction_id, bonus, item) end,
    bonus_yield = function(res_type) return api.bonus_yield(res_type) end,
    former_search_start = function(veh_id) return api.former_search_start(veh_id) end,
    former_search_next = function(valid, tx, ty) return api.former_search_next(valid, tx, ty) end,
    former_consume = function(x, y) return api.former_consume(x, y) end,
    former_apply_action = function(veh_id, item) return api.former_apply_action(veh_id, item) end,
    former_request_new_orders = function(veh_id) return api.former_request_new_orders(veh_id) end,
    reg_enemy_at = function(region, is_probe) return api.reg_enemy_at(region, is_probe) ~= 0 end,
    veh_cargo = function(veh_id) return api.veh_cargo(veh_id) end,
    veh_need_heals = function(veh_id) return api.veh_need_heals(veh_id) ~= 0 end,
    veh_wake = function(veh_id) return api.veh_wake(veh_id) end,
    unmark_map_node = function(x, y, node_type) return api.unmark_map_node(x, y, node_type) ~= 0 end,
    set_board_to = function(veh_id, trans_veh_id) return api.set_board_to(veh_id, trans_veh_id) end,
    tile_veh_who = function(x, y) return api.tile_veh_who(x, y) end,
    map_unit_near = function(x, y) return api.map_unit_near(x, y) end,
    choose_defender = function(x, y, veh_id_atk) return api.choose_defender(x, y, veh_id_atk) end,
    battle_priority = function(veh_id_atk, veh_id_def, dist, moves, x, y)
        return api.battle_priority(veh_id_atk, veh_id_def, dist, moves, x, y)
    end,
    goody_at = function(x, y) return api.goody_at(x, y) ~= 0 end,
    allow_scout = function(faction_id, x, y) return api.allow_scout(faction_id, x, y) ~= 0 end,
    trans_search_start = function(veh_id) return api.trans_search_start(veh_id) end,
    trans_search_next = function(valid, tx, ty, dist) return api.trans_search_next(valid, tx, ty, dist) end,
    map_enemy = function(x, y) return api.map_enemy(x, y) end,
    map_enemy_near = function(x, y) return api.map_enemy_near(x, y) end,
    map_enemy_dist = function(x, y) return api.map_enemy_dist(x, y) end,
    is_objective = function(base_id) return api.is_objective(base_id) ~= 0 end,
    veh_high_damage = function(veh_id) return api.veh_high_damage(veh_id) ~= 0 end,
    enemy_factions = function(faction_id) return api.enemy_factions(faction_id) end,
    mod_stack_check = function(veh_id, type, cond1, cond2, cond3)
        return api.mod_stack_check(veh_id, type, cond1, cond2, cond3)
    end,
    mod_zoc_move = function(x, y, faction_id) return api.mod_zoc_move(x, y, faction_id) end,
    has_orbital_drops = function(faction_id) return api.has_orbital_drops(faction_id) ~= 0 end,
    veh_at = function(x, y) return api.veh_at(x, y) end,
    map_target_incr = function(x, y) return api.map_target_incr(x, y) end,
    map_enemy_rank = function(x, y) return api.map_enemy_rank(x, y) end,
    map_flags = function(x, y) return api.map_flags(x, y) end,
    can_arty = function(unit_id, arty) return api.can_arty(unit_id, arty) end,
    arty_range = function(unit_id) return api.arty_range(unit_id) end,
    arty_table_range = function(unit_id) return api.arty_table_range(unit_id) end,
    tile_is_airbase = function(x, y) return api.tile_is_airbase(x, y) ~= 0 end,
    veh_mid_damage = function(veh_id) return api.veh_mid_damage(veh_id) ~= 0 end,
    update_move_path = function(veh_id, tx, ty) return api.update_move_path(veh_id, tx, ty) end,
    net_action_destroy = function(veh_id, flag, x, y)
        return api.net_action_destroy(veh_id, flag, x, y)
    end,
    mod_battle_fight = function(veh_id, offset, table_offset, option)
        return api.mod_battle_fight(veh_id, offset, table_offset, option)
    end,
    probe_action = function(veh_id, tgt_base_id, tgt_veh_id, toggle)
        return api.probe_action(veh_id, tgt_base_id, tgt_veh_id, toggle)
    end,
    combat_search_start = function(veh_id, ts_type, ts_skip)
        return api.combat_search_start(veh_id, ts_type, ts_skip)
    end,
    combat_search_next = function(valid, tx, ty, dist, prev_x, prev_y)
        return api.combat_search_next(valid, tx, ty, dist, prev_x, prev_y)
    end,
    combat_search_has_zoc = function(faction_id) return api.combat_search_has_zoc(faction_id) ~= 0 end,
    main_sea_region = function(faction_id) return api.main_sea_region(faction_id) end,
    naval_airbase_x = function(faction_id) return api.naval_airbase_x(faction_id) end,
    naval_airbase_y = function(faction_id) return api.naval_airbase_y(faction_id) end,
    naval_scout_x = function(faction_id) return api.naval_scout_x(faction_id) end,
    naval_scout_y = function(faction_id) return api.naval_scout_y(faction_id) end,
    prioritize_naval = function(faction_id) return api.prioritize_naval(faction_id) end,
}
