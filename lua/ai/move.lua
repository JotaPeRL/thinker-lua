-- Movement port (porting-order item 4, IMPLEMENTATION_PLAN.md Phase 4.2
-- item 4, IMPLEMENTATION_DETAILS.md 4.12). Stage 1: artifact_move
-- (move.cpp:2204-2225), the pilot for the whole phase's Class 3 hook
-- mechanism (src/luaai.h's lua_ai_command_hook) -- smallest and simplest
-- mover, chosen specifically to prove the mechanism before anything
-- bigger. Class 3: calls host mutators directly as it executes
-- (mod_study_artifact/set_move_to/mod_veh_skip) and returns the action
-- code (VEH_SYNC/VEH_SKIP) the C++ caller uses as-is -- no separate
-- commit step, unlike select_build's Class 2 propose-then-commit.
--
-- TileSearch stays entirely in C++ (Phase 4.3), exposed only via the
-- incremental start/next iterator primitives each mover's own scoring
-- needs (crawler_search_*/search_escape_*/search_base_*/route_search_*).
-- The old opaque path.search_route (a whole-scan host wrapper with no
-- iterator) is superseded by this file's own search_route (below,
-- IMPLEMENTATION_DETAILS.md 4.12's route_score sub-stage) but kept
-- around, unused, until that port is live-verified.
local port = {
    source = {
        artifact_move = { file = "src/move.cpp", func = "artifact_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        crawler_move = { file = "src/move.cpp", func = "crawler_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        want_convoy = { file = "src/move.cpp", func = "want_convoy",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        escape_score = { file = "src/path.cpp", func = "escape_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        search_escape = { file = "src/path.cpp", func = "search_escape",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        search_base = { file = "src/path.cpp", func = "search_base",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        escape_move = { file = "src/path.cpp", func = "escape_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        base_tile_score = { file = "src/move.cpp", func = "base_tile_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        defender_count = { file = "src/path.cpp", func = "defender_count",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        colony_move = { file = "src/move.cpp", func = "colony_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        route_score = { file = "src/path.cpp", func = "route_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        search_route = { file = "src/path.cpp", func = "search_route",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_borehole = { file = "src/move.cpp", func = "can_borehole",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_farm = { file = "src/move.cpp", func = "can_farm",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_solar = { file = "src/move.cpp", func = "can_solar",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_mine = { file = "src/move.cpp", func = "can_mine",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_forest = { file = "src/move.cpp", func = "can_forest",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_sensor = { file = "src/move.cpp", func = "can_sensor",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        former_keep_fungus = { file = "src/move.cpp", func = "keep_fungus",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        former_plant_fungus = { file = "src/move.cpp", func = "plant_fungus",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_level = { file = "src/move.cpp", func = "can_level",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_river = { file = "src/move.cpp", func = "can_river",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_road = { file = "src/move.cpp", func = "can_road",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        can_magtube = { file = "src/move.cpp", func = "can_magtube",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        select_item = { file = "src/move.cpp", func = "select_item",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        former_tile_score = { file = "src/move.cpp", func = "former_tile_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        former_move = { file = "src/move.cpp", func = "former_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local veh = dofile("lua/api/veh.lua")
local base_api = dofile("lua/api/base.lua")
local map = dofile("lua/api/map.lua")
local log = dofile("lua/api/log.lua")
local cmath = dofile("lua/api/cmath.lua")
local game = dofile("lua/api/game.lua")
local rand = dofile("lua/api/rand.lua")
local faction = dofile("lua/api/faction.lua")
local tech = dofile("lua/api/tech.lua")

local E = types.enums
local idiv = cmath.idiv
local imod = cmath.imod
local clamp = cmath.clamp
local min = math.min
local max = math.max

-- former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13):
-- GamePreferences/GameMorePreferences are plain int* globals (like
-- CurrentTurn), read via [0]. ResInfoForestSq is the one ResValue member
-- can_solar needs -- same one-field-address technique as tech.lua's
-- ResInfoRecyclingTanks (the FIELD()/FieldShape mechanism can't emit_struct
-- a nested-struct member), read as int32_t[3] (nutrient, mineral, energy,
-- skipping the unused 4th) -- only .energy (index 2) is used here.
local GamePreferences = ffi.cast("int32_t*", types.globals.GamePreferences)
local GameMorePreferences = ffi.cast("int32_t*", types.globals.GameMorePreferences)
local ResInfoForestSq = ffi.cast("int32_t*", types.globals.ResInfoForestSq)
-- former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
-- select_item's own borehole/sea-solar branches, same technique/index
-- convention as ResInfoForestSq above.
local ResInfoBoreholeSq = ffi.cast("int32_t*", types.globals.ResInfoBoreholeSq)
local ResInfoImprovedSea = ffi.cast("int32_t*", types.globals.ResInfoImprovedSea)
-- former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
-- Terraform[item].rate (turns remaining for an in-progress terraform
-- order) -- same cast pattern as tech.lua's Rules/ResInfo-style rule
-- tables, indexed by FormerItem (0-based, matching VehOrderFormerFirst).
local Terraform = ffi.cast("CTerraform*", types.globals.Terraform)

-- engine_types.h:287-289's MFaction::is_aquatic() (rule_flags &
-- RFLAG_AQUATIC) -- same tier as war.lua's/build.lua's own local
-- is_aquatic/is_alien helpers, kept local here too rather than added to
-- faction.lua's shared surface.
local function is_aquatic(faction_id)
    return bit.band(faction.meta(faction_id).rule_flags, E.RFLAG_AQUATIC) ~= 0
end

-- Forward declaration: artifact_move (below) calls the fully-assembled
-- search_route (IMPLEMENTATION_DETAILS.md 4.12, route_score sub-stage B),
-- defined later in this file next to the route_score/route_best_home_base/
-- route_gate_teleport pieces it's built from.
local search_route
-- Forward declaration: former_move (sub-stage 4, defined further up in
-- this file than escape_move's/search_base's own definitions -- unlike
-- colony_move, which is defined after both) calls escape_move for its
-- own !safe branch and search_base for its own tail-end fallback.
-- Found live (IMPLEMENTATION_DETAILS.md 4.13): without these, former_move
-- treated both as undefined globals, caught safely by
-- lua_ai_command_hook's pcall (no mutation had occurred yet) but
-- incorrectly falling back to former_move's own C++ body every time
-- either branch was reached. A systematic sweep for the same forward-
-- reference pattern across the rest of the file found no other instances.
local escape_move
local search_base

-- former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13): the 12
-- can_*/keep_fungus/plant_fungus tile-eligibility helpers select_item
-- (sub-stage 2) will choose among -- real AI policy (only here does
-- *which* terraform action gets picked matter, per select_build's own
-- former_tile_tally note deferring this exact port), unlike the engine-
-- eligibility gates (has_terra, can_bridge) they call, which stay opaque.
-- None of these take a VEH -- all are pure tile+faction-level queries,
-- same signatures as the C++ originals minus the MAP* (recomputed from
-- x, y via the tile_* fact wrappers instead). keep_fungus/plant_fungus
-- are named former_keep_fungus/former_plant_fungus here to avoid
-- colliding with the existing funcs.keep_fungus AIPlans accessor.

-- move.cpp:1568-1595.
local function can_borehole(x, y, faction_id, bonus)
    if not funcs.has_terra(E.FORMER_THERMAL_BORE, funcs.tile_is_ocean(x, y) and 1 or 0, faction_id) then
        return false
    end
    if funcs.is_human(faction_id) and bit.band(GamePreferences[0], E.PREF_AUTO_FORMER_BUILD_ADV) == 0 then
        return false
    end
    local items = funcs.tile_items(x, y)
    if bit.band(items, bit.bor(E.BIT_BASE_IN_TILE, E.BIT_MONOLITH, E.BIT_THERMAL_BORE)) ~= 0
        or bonus == E.RES_NUTRIENT then
        return false
    end
    if bonus == E.RES_NONE and funcs.tile_is_rolling(x, y) and bit.band(items, E.BIT_CONDENSER) ~= 0 then
        return false
    end
    if funcs.map_former(x, y) < 4 and not funcs.has_map_node(x, y, E.NODE_BOREHOLE) then
        return false
    end
    local level = funcs.tile_alt_level(x, y)
    local coord = ffi.new("int32_t[2]")
    for i = 1, 8 do
        if funcs.tile_neighbor(x, y, i, coord, coord + 1) then
            local nx, ny = coord[0], coord[1]
            if bit.band(funcs.tile_items(nx, ny), E.BIT_THERMAL_BORE) ~= 0
                or funcs.has_map_node(nx, ny, E.NODE_BOREHOLE) then
                return false
            end
            local level2 = funcs.tile_alt_level(nx, ny)
            if level2 < level and level2 > E.ALT_OCEAN_SHELF then
                return false
            end
        end
    end
    return true
end

-- move.cpp:1597-1620.
local function can_farm(x, y, faction_id, bonus)
    local has_nut = funcs.has_tech(tech.rules().tech_preq_allow_3_nutrients_sq, faction_id)
    local sea = funcs.tile_is_ocean(x, y)
    local items = funcs.tile_items(x, y)
    if not funcs.has_terra(E.FORMER_FARM, sea and 1 or 0, faction_id)
        or funcs.tile_is_rocky(x, y) or bit.band(items, E.BIT_THERMAL_BORE) ~= 0 then
        return false
    end
    if bonus == E.RES_NUTRIENT and bit.band(items, E.BIT_FOREST) == 0
        and (sea or funcs.tile_is_rainy(x, y) or funcs.tile_is_moist(x, y) or funcs.tile_is_rolling(x, y)) then
        return true
    end
    if bonus == E.RES_ENERGY or bonus == E.RES_MINERAL
        or bit.band(funcs.tile_lm_items(x, y), E.LM_VOLCANO) ~= 0 then
        return false
    end
    if not has_nut and bonus ~= E.RES_NUTRIENT
        and funcs.mod_crop_yield(faction_id, -1, x, y, 0) >= funcs.tile_output_limit_nutrient() then
        return false
    end
    local score = (funcs.tile_is_rolling(x, y) and 1 or 0)
        + ((funcs.tile_is_rainy(x, y) or funcs.tile_is_moist(x, y)) and 1 or 0)
        + (funcs.nearby_items(x, y, 0, 9, bit.bor(E.BIT_FARM, E.BIT_CONDENSER)) < 2 and 1 or 0)
        + (bit.band(items, bit.bor(E.BIT_FARM, E.BIT_CONDENSER)) ~= 0 and 1 or 0)
        + (bit.band(items, E.BIT_FOREST) ~= 0 and 0 or 2)
        + (bit.band(funcs.tile_lm_items(x, y), E.LM_JUNGLE) ~= 0 and 0 or 1)
    return score > 4
end

-- move.cpp:1622-1645. BIT_ADVANCED (move.h) is CONDENSER|THERMAL_BORE,
-- computed inline rather than exposed as its own constant.
local function can_solar(x, y, faction_id, bonus)
    local sea = funcs.tile_is_ocean(x, y)
    if not funcs.has_terra(E.FORMER_SOLAR, sea and 1 or 0, faction_id) or bonus == E.RES_MINERAL then
        return false
    end
    if funcs.tile_is_rocky(x, y) and bonus ~= E.RES_ENERGY then
        return false
    end
    if not funcs.has_tech(tech.rules().tech_preq_allow_3_energy_sq, faction_id)
        and bonus ~= E.RES_ENERGY and funcs.mod_energy_yield(faction_id, -1, x, y, 0) >= 2 then
        return false
    end
    local items = funcs.tile_items(x, y)
    if not sea and funcs.has_terra(E.FORMER_FOREST, sea and 1 or 0, faction_id) and ResInfoForestSq[2] > 0
        and not (funcs.tile_is_rocky(x, y) and bonus == E.RES_ENERGY
            and funcs.tile_alt_level(x, y) > E.ALT_TWO_ABOVE_SEA)
        and (bit.band(funcs.tile_lm_items(x, y), E.LM_JUNGLE) ~= 0
            or ((funcs.tile_is_rainy(x, y) and 1 or 0) + (funcs.tile_is_rolling(x, y) and 1 or 0)
                + ((funcs.tile_is_rainy(x, y) or funcs.tile_is_moist(x, y)) and 1 or 0)
                + (bit.band(items, E.BIT_FARM) ~= 0 and 1 or 0) < 3)) then
        return false
    end
    if bit.band(items, E.BIT_SENSOR) ~= 0 and funcs.nearby_items(x, y, 0, 9, E.BIT_SENSOR) < 2 then
        return false
    end
    return bit.band(items, bit.bor(E.BIT_MINE, E.BIT_FOREST, E.BIT_SOLAR, E.BIT_CONDENSER, E.BIT_THERMAL_BORE)) == 0
end

-- move.cpp:1647-1663.
local function can_mine(x, y, faction_id, bonus)
    local sea = funcs.tile_is_ocean(x, y)
    if not funcs.has_terra(E.FORMER_MINE, sea and 1 or 0, faction_id) or bonus == E.RES_NUTRIENT then
        return false
    end
    if not sea and not funcs.tile_is_rocky(x, y) then
        return false
    end
    if not funcs.has_tech(tech.rules().tech_preq_allow_3_minerals_sq, faction_id)
        and bonus ~= E.RES_MINERAL and funcs.mod_mine_yield(faction_id, -1, x, y, 0) >= 2 then
        return false
    end
    local items = funcs.tile_items(x, y)
    if bit.band(items, E.BIT_SENSOR) ~= 0 and funcs.nearby_items(x, y, 0, 9, E.BIT_SENSOR) < 2 then
        return false
    end
    return bit.band(items, bit.bor(E.BIT_MINE, E.BIT_FOREST, E.BIT_SOLAR, E.BIT_CONDENSER, E.BIT_THERMAL_BORE)) == 0
end

-- move.cpp:1665-1681.
local function can_forest(x, y, faction_id)
    local sea = funcs.tile_is_ocean(x, y)
    if not funcs.has_terra(E.FORMER_FOREST, sea and 1 or 0, faction_id) then
        return false
    end
    if funcs.tile_is_rocky(x, y) or bit.band(funcs.tile_lm_items(x, y), E.LM_VOLCANO) ~= 0 then
        return false
    end
    local items = funcs.tile_items(x, y)
    if not funcs.has_tech(tech.rules().tech_preq_allow_3_nutrients_sq, faction_id)
        and (funcs.tile_is_rolling(x, y) or bit.band(items, E.BIT_SOLAR) ~= 0)
        and funcs.mod_crop_yield(faction_id, -1, x, y, 0) >= funcs.tile_output_limit_nutrient() then
        return false
    end
    if funcs.is_human(faction_id) and bit.band(GamePreferences[0], E.PREF_AUTO_FORMER_PLANT_FORESTS) == 0 then
        return false
    end
    return bit.band(items, E.BIT_FOREST) == 0
end

-- move.cpp:1683-1703.
local function can_sensor(x, y, faction_id)
    local sea = funcs.tile_is_ocean(x, y)
    if not funcs.has_terra(E.FORMER_SENSOR, sea and 1 or 0, faction_id) then
        return false
    end
    local items = funcs.tile_items(x, y)
    if bit.band(items, bit.bor(E.BIT_MINE, E.BIT_SOLAR, E.BIT_SENSOR, E.BIT_CONDENSER, E.BIT_THERMAL_BORE)) ~= 0 then
        return false
    end
    if funcs.tile_is_fungus(x, y) and not funcs.has_tech(tech.rules().tech_preq_improv_fungus, faction_id) then
        return false
    end
    local coord = ffi.new("int32_t[2]")
    for i = 1, 24 do
        if funcs.tile_neighbor(x, y, i, coord, coord + 1) then
            local nx, ny = coord[0], coord[1]
            if funcs.tile_owner(nx, ny) == faction_id
                and (bit.band(funcs.tile_items(nx, ny), E.BIT_SENSOR) ~= 0
                    or funcs.has_map_node(nx, ny, E.NODE_SENSOR_ARRAY)) then
                return false
            end
        end
    end
    if funcs.is_human(faction_id) and bit.band(GameMorePreferences[0], E.MPREF_AUTO_FORMER_BUILD_SENSORS) == 0 then
        return false
    end
    return true
end

-- move.cpp:1705-1711. Named former_keep_fungus: funcs.keep_fungus is
-- already the AIPlans accessor this calls into.
local function former_keep_fungus(x, y, faction_id)
    local keep = funcs.keep_fungus(faction_id)
    if keep == 0 then
        return false
    end
    local items = funcs.tile_items(x, y)
    return bit.band(items, bit.bor(E.BIT_BASE_IN_TILE, E.BIT_MONOLITH)) == 0
        and funcs.tile_alt_level(x, y) >= E.ALT_OCEAN_SHELF
        and funcs.nearby_items(x, y, 0, 9, E.BIT_FUNGUS) < (funcs.tile_is_fungus(x, y) and 1 or 0) + keep
end

-- move.cpp:1713-1718. Named former_plant_fungus for the same reason as
-- former_keep_fungus above (funcs.plant_fungus_flag is the new AIPlans
-- accessor this calls into).
local function former_plant_fungus(x, y, faction_id)
    if funcs.plant_fungus_flag(faction_id) == 0 then
        return false
    end
    if not former_keep_fungus(x, y, faction_id) then
        return false
    end
    if funcs.tile_alt_level(x, y) < E.ALT_OCEAN_SHELF then
        return false
    end
    return funcs.has_terra(E.FORMER_PLANT_FUNGUS, funcs.tile_is_ocean(x, y) and 1 or 0, faction_id)
end

-- move.cpp:1720-1728.
local function can_level(x, y, faction_id, bonus)
    if not funcs.tile_is_rocky(x, y) then
        return false
    end
    if not funcs.has_terra(E.FORMER_LEVEL_TERRAIN, funcs.tile_is_ocean(x, y) and 1 or 0, faction_id) then
        return false
    end
    if bonus == E.RES_NUTRIENT then
        return true
    end
    if bonus ~= E.RES_NONE then
        return false
    end
    local items = funcs.tile_items(x, y)
    if bit.band(items, bit.bor(E.BIT_MINE, E.BIT_FUNGUS, E.BIT_THERMAL_BORE)) ~= 0 then
        return false
    end
    if bit.band(items, E.BIT_RIVER) == 0 then
        return false
    end
    if funcs.plant_fungus_flag(faction_id) ~= 0 then
        return false
    end
    local limit = (bit.band(funcs.tile_lm_items(x, y), E.LM_JUNGLE) ~= 0) and 4 or 2
    return funcs.nearby_items(x, y, 0, 9, bit.bor(E.BIT_FARM, E.BIT_FOREST)) < limit
end

-- move.cpp:1730-1741.
local function can_river(x, y, faction_id)
    if funcs.tile_is_ocean(x, y) or not funcs.has_terra(E.FORMER_AQUIFER, E.TRIAD_LAND, faction_id) then
        return false
    end
    local items = funcs.tile_items(x, y)
    if bit.band(items, bit.bor(E.BIT_BASE_IN_TILE, E.BIT_RIVER, E.BIT_THERMAL_BORE)) ~= 0 then
        return false
    end
    return bit.band(bit.bxor(idiv(game.turn(), 4) * x, y), 15) == 0
        and funcs.coast_tiles(x, y) == 0
        and funcs.nearby_items(x, y, 1, 9, bit.bor(E.BIT_RIVER, E.BIT_THERMAL_BORE)) < 2
        and funcs.nearby_items(x, y, 1, 25, E.BIT_RIVER) < 6
end

-- move.cpp:1743-1786. The 8-direction NearbyTiles ring (tile_near8) is a
-- distinct, smaller table from the 21-tile TableOffsetX/Y ring
-- tile_neighbor resolves -- off-map/ocean neighbors contribute r[i]=0
-- either way (an off-map tile_near8 result is treated the same as a
-- present-but-ocean one), matching the original's own NULL-safe
-- is_ocean(NULL)==true short-circuit.
local function can_road(x, y, faction_id)
    local sea = funcs.tile_is_ocean(x, y)
    local items = funcs.tile_items(x, y)
    if not funcs.has_terra(E.FORMER_ROAD, sea and 1 or 0, faction_id)
        or bit.band(items, bit.bor(E.BIT_ROAD, E.BIT_BASE_IN_TILE)) ~= 0 then
        return false
    end
    if not funcs.tile_is_base_radius(x, y) and funcs.map_roads(x, y) < 1 then
        return false
    end
    if funcs.tile_is_fungus(x, y)
        and (not funcs.has_tech(tech.rules().tech_preq_build_road_fungus, faction_id)
            or (funcs.build_tubes(faction_id) == 0 and funcs.has_project(E.FAC_XENOEMPATHY_DOME, faction_id))) then
        return false
    end
    if funcs.is_human(faction_id) and bit.band(GameMorePreferences[0], E.MPREF_AUTO_FORMER_CANT_BUILD_ROADS) ~= 0 then
        return false
    end
    if funcs.tile_owner(x, y) ~= faction_id then
        return funcs.map_roads(x, y) > 0 and not funcs.both_neutral(faction_id, funcs.tile_owner(x, y))
    end
    if funcs.has_map_node(x, y, E.NODE_GOAL_RAISE_LAND) then
        return true
    end
    if funcs.map_roads(x, y) > 0 or bit.band(items, bit.bor(E.BIT_MINE, E.BIT_CONDENSER, E.BIT_THERMAL_BORE)) ~= 0 then
        return true
    end
    local r = {}
    local coord = ffi.new("int32_t[2]")
    for i = 0, 7 do
        r[i] = 0
        if funcs.tile_near8(x, y, i, coord, coord + 1) then
            local nx, ny = coord[0], coord[1]
            if not funcs.tile_is_ocean(nx, ny) and funcs.tile_owner(nx, ny) == faction_id
                and bit.band(funcs.tile_items(nx, ny), bit.bor(E.BIT_ROAD, E.BIT_BASE_IN_TILE)) ~= 0 then
                r[i] = 1
            end
        end
    end
    if (r[0] == 1 and r[4] == 1 and r[2] == 0 and r[6] == 0)
        or (r[2] == 1 and r[6] == 1 and r[0] == 0 and r[4] == 0)
        or (r[1] == 1 and r[5] == 1 and not ((r[2] == 1 and r[4] == 1) or (r[0] == 1 and r[6] == 1)))
        or (r[3] == 1 and r[7] == 1 and not ((r[0] == 1 and r[2] == 1) or (r[4] == 1 and r[6] == 1))) then
        return true
    end
    return false
end

-- move.cpp:1788-1801.
local function can_magtube(x, y, faction_id)
    local sea = funcs.tile_is_ocean(x, y)
    local items = funcs.tile_items(x, y)
    if not funcs.has_terra(E.FORMER_MAGTUBE, sea and 1 or 0, faction_id)
        or bit.band(items, bit.bor(E.BIT_MAGTUBE, E.BIT_BASE_IN_TILE)) ~= 0 then
        return false
    end
    if funcs.both_neutral(faction_id, funcs.tile_owner(x, y)) then
        return false
    end
    if funcs.is_human(faction_id) and bit.band(GameMorePreferences[0], E.MPREF_AUTO_FORMER_CANT_BUILD_ROADS) ~= 0 then
        return false
    end
    return funcs.map_roads(x, y) > 0 and bit.band(items, E.BIT_ROAD) ~= 0
        and (not funcs.tile_is_fungus(x, y) or funcs.has_tech(tech.rules().tech_preq_improv_fungus, faction_id))
end

-- former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
-- select_item, the terraform-choice decision tree combining the 12
-- can_*/keep_fungus/plant_fungus results above -- the real AI policy
-- select_build's own former_tile_tally (4.10.29) deferred to this exact
-- port. mode is one of the FormerMode enums (E.FM_Auto_Full etc.), same
-- as the C++ original. mapsq(x, y)'s null check at the top is dropped:
-- a former's own tile, or a candidate already surfaced by former_move's
-- TileSearch scan (sub-stage 4), is always a valid map tile. `sea` here
-- is alt < ALT_SHORE_LINE in the original, identical to tile_is_ocean
-- (is_ocean checks the same climate>>5 < ALT_SHORE_LINE condition), so
-- tile_is_ocean is reused directly rather than recomputed from alt.
local function select_item(x, y, faction_id, mode)
    local items = funcs.tile_items(x, y)
    local alt = funcs.tile_alt_level(x, y)
    local sea = funcs.tile_is_ocean(x, y)
    local road = can_road(x, y, faction_id)
    local is_fungus_tile = funcs.tile_is_fungus(x, y)
    local rem_fungus = funcs.has_terra(E.FORMER_REMOVE_FUNGUS, sea and 1 or 0, faction_id)
        and (not funcs.is_human(faction_id)
            or bit.band(GameMorePreferences[0], E.MPREF_AUTO_FORMER_REMOVE_FUNGUS) ~= 0)

    if funcs.tile_is_base(x, y) or funcs.tile_is_volcano_center(x, y) then
        return E.FORMER_NONE
    end
    -- Improvements on ocean possible for aquatic factions after Adv. Ecological Engineering
    if alt < E.ALT_OCEAN_SHELF and (not is_aquatic(faction_id) or not funcs.has_tech(E.TECH_EcoEng2, faction_id)) then
        return E.FORMER_NONE
    end
    if mode == E.FM_Auto_Sensors then
        if can_sensor(x, y, faction_id) then
            return E.FORMER_SENSOR
        end
        return E.FORMER_NONE
    end
    if mode == E.FM_Remove_Fungus then
        if is_fungus_tile and rem_fungus then
            return E.FORMER_REMOVE_FUNGUS
        end
        return E.FORMER_NONE
    end
    if (mode == E.FM_Auto_Full or mode == E.FM_Auto_Tubes) and can_magtube(x, y, faction_id) then
        return E.FORMER_MAGTUBE
    end
    if mode == E.FM_Auto_Full and funcs.can_bridge(x, y, faction_id) then
        if funcs.has_map_node(x, y, E.NODE_RAISE_LAND)
            or funcs.terraform_cost(x, y, faction_id) < idiv(faction.get(faction_id).energy_credits, 8) then
            return (road and E.FORMER_ROAD or E.FORMER_RAISE_LAND)
        end
    end
    if road or funcs.tile_owner(x, y) ~= faction_id or not funcs.tile_is_base_radius(x, y)
        or bit.band(items, E.BIT_MONOLITH) ~= 0 then
        return (road and E.FORMER_ROAD or E.FORMER_NONE)
    end
    if mode == E.FM_Farm_Road or mode == E.FM_Mine_Road then
        if is_fungus_tile then
            if funcs.has_terra(E.FORMER_REMOVE_FUNGUS, sea and 1 or 0, faction_id) then
                return E.FORMER_REMOVE_FUNGUS
            end
            return E.FORMER_NONE
        end
        if bit.band(items, E.BIT_ROAD) == 0 and funcs.has_terra(E.FORMER_ROAD, sea and 1 or 0, faction_id) then
            return E.FORMER_ROAD
        end
        if bit.band(items, E.BIT_MONOLITH) ~= 0 then
            return E.FORMER_NONE
        end
    end
    if mode == E.FM_Farm_Road then
        if (sea or not funcs.tile_is_rocky(x, y)) and bit.band(items, E.BIT_FARM) == 0
            and funcs.has_terra(E.FORMER_FARM, sea and 1 or 0, faction_id) then
            return E.FORMER_FARM
        end
        if bit.band(items, E.BIT_SOLAR) == 0 and funcs.has_terra(E.FORMER_SOLAR, sea and 1 or 0, faction_id) then
            return E.FORMER_SOLAR
        end
    end
    if mode == E.FM_Mine_Road then
        if bit.band(items, E.BIT_MINE) == 0 and funcs.has_terra(E.FORMER_MINE, sea and 1 or 0, faction_id) then
            return E.FORMER_MINE
        end
    end
    if mode ~= E.FM_Auto_Full then -- Skip non-automated player formers
        return E.FORMER_NONE
    end
    if can_river(x, y, faction_id) then
        return E.FORMER_AQUIFER
    end

    local bonus = funcs.tile_bonus(x, y)
    local current = funcs.mod_crop_yield(faction_id, -1, x, y, 0)
        + funcs.mod_mine_yield(faction_id, -1, x, y, 0)
        + funcs.mod_energy_yield(faction_id, -1, x, y, 0)

    local forest = funcs.has_terra(E.FORMER_FOREST, sea and 1 or 0, faction_id) and ResInfoForestSq[2] > 0
    local borehole = funcs.has_terra(E.FORMER_THERMAL_BORE, sea and 1 or 0, faction_id) and ResInfoBoreholeSq[2] > 2
    local condenser = funcs.has_terra(E.FORMER_CONDENSER, sea and 1 or 0, faction_id)
    local use_sensor = bit.band(items, E.BIT_SENSOR) ~= 0 and funcs.nearby_items(x, y, 0, 9, E.BIT_SENSOR) < 2
    local allow_farm = bit.band(items, E.BIT_FARM) ~= 0 or can_farm(x, y, faction_id, bonus)
    local allow_forest = bit.band(items, E.BIT_FOREST) ~= 0 or can_forest(x, y, faction_id)
    local allow_fungus = is_fungus_tile or former_plant_fungus(x, y, faction_id)
    local allow_borehole = bit.band(items, E.BIT_THERMAL_BORE) ~= 0 or can_borehole(x, y, faction_id, bonus)

    local farm_val = (sea and allow_farm)
        and (2 * funcs.item_yield(x, y, faction_id, bonus, E.BIT_FARM)
            + (bit.band(items, E.BIT_FARM) ~= 0 and 1 or 0))
        or 0
    local forest_val = allow_forest
        and (2 * funcs.item_yield(x, y, faction_id, bonus, E.BIT_FOREST)
            + (bit.band(items, E.BIT_FOREST) ~= 0 and 1 or 0))
        or 0
    local fungus_val = allow_fungus
        and (2 * funcs.item_yield(x, y, faction_id, bonus, E.BIT_FUNGUS)
            - min(4, 2 * funcs.bonus_yield(bonus)) + (is_fungus_tile and 1 or 0))
        or 0
    local borehole_val = allow_borehole
        and (2 * funcs.item_yield(x, y, faction_id, bonus, E.BIT_THERMAL_BORE)
            + (bit.band(items, E.BIT_THERMAL_BORE) ~= 0 and 1 or 0))
        or 0

    local max_val = 0
    for _, v in ipairs({farm_val, forest_val, fungus_val, borehole_val}) do
        max_val = max(v, max_val)
    end
    local skip_val = (current > 7) and 1 or 0
    local crop_val = (bonus == E.RES_NUTRIENT and 1 or 0) + skip_val
        + ((bit.band(items, E.BIT_CONDENSER) == 0 and allow_farm
            and (funcs.tile_is_rainy(x, y) or funcs.tile_is_moist(x, y)) and funcs.tile_is_rolling(x, y))
            and 1 or 0)

    if farm_val == max_val and sea and max_val > 0 then
        if is_fungus_tile then
            return (rem_fungus and E.FORMER_REMOVE_FUNGUS or E.FORMER_NONE)
        end
        if idiv(farm_val, 2) > current and bit.band(items, E.BIT_FARM) == 0 and allow_farm then
            return E.FORMER_FARM
        end
    end
    if forest_val == max_val and max_val > 0 then
        if is_fungus_tile then
            return (rem_fungus and E.FORMER_REMOVE_FUNGUS or E.FORMER_NONE)
        end
        if bit.band(items, E.BIT_FOREST) ~= 0 then
            return (can_sensor(x, y, faction_id) and E.FORMER_SENSOR or E.FORMER_NONE)
        end
        if idiv(forest_val, 2) > current + crop_val and allow_forest then
            return E.FORMER_FOREST
        end
    end
    if fungus_val == max_val and max_val > 0 then
        if is_fungus_tile then
            return (can_sensor(x, y, faction_id) and E.FORMER_SENSOR or E.FORMER_NONE)
        end
        if idiv(fungus_val, 2) > current + (bonus ~= E.RES_NONE and 1 or 0) and allow_fungus then
            return E.FORMER_PLANT_FUNGUS
        end
    end
    if borehole_val == max_val and max_val > 0 then
        if is_fungus_tile then
            return (rem_fungus and E.FORMER_REMOVE_FUNGUS or E.FORMER_NONE)
        end
        if bit.band(items, E.BIT_THERMAL_BORE) ~= 0 then
            return E.FORMER_NONE
        end
        if idiv(borehole_val, 2) > current and allow_borehole then
            return E.FORMER_THERMAL_BORE
        end
    end
    if is_fungus_tile then
        if former_keep_fungus(x, y, faction_id) then
            return (can_sensor(x, y, faction_id) and E.FORMER_SENSOR or E.FORMER_NONE)
        end
        return (rem_fungus and E.FORMER_REMOVE_FUNGUS or E.FORMER_NONE)
    end
    if can_level(x, y, faction_id, bonus) then
        return E.FORMER_LEVEL_TERRAIN
    end
    if sea and bonus == E.RES_NONE and can_sensor(x, y, faction_id) then
        return E.FORMER_SENSOR
    end

    local solar_need = (condenser and 0 or 1) + (forest and 0 or 2) + (borehole and 0 or 3)
        + 2 * max(0, funcs.tile_alt_level(x, y) - E.ALT_ONE_ABOVE_SEA)
        - funcs.nearby_items(x, y, 0, 25, E.BIT_SOLAR)
    if sea then
        local base
        if funcs.has_terra(E.FORMER_MINE, 1, faction_id) then
            base = (ResInfoImprovedSea[2] - ResInfoImprovedSea[1])
                - (funcs.has_tech(tech.rules().tech_preq_mining_platform_bonus, faction_id) and 1 or 0)
        else
            base = 6
        end
        solar_need = base + funcs.nearby_items(x, y, 0, 25, E.BIT_MINE) - funcs.nearby_items(x, y, 0, 25, E.BIT_SOLAR)
    end

    if can_solar(x, y, faction_id, bonus) and solar_need > 0 then
        if allow_farm and bit.band(items, E.BIT_FARM) == 0 then
            return E.FORMER_FARM
        end
        return E.FORMER_SOLAR
    end
    if can_mine(x, y, faction_id, bonus) then
        if sea and allow_farm and bit.band(items, E.BIT_FARM) == 0 then
            return E.FORMER_FARM
        end
        return E.FORMER_MINE
    end
    if bit.band(items, E.BIT_SOLAR) ~= 0 and solar_need >= 0 then
        return E.FORMER_NONE
    end
    if allow_farm and bit.band(items, E.BIT_FARM) == 0 then
        return E.FORMER_FARM
    end
    if not use_sensor and bit.band(items, E.BIT_FARM) ~= 0 and bit.band(items, E.BIT_CONDENSER) == 0
        and funcs.has_terra(E.FORMER_CONDENSER, sea and 1 or 0, faction_id)
        and (not funcs.is_human(faction_id) or bit.band(GamePreferences[0], E.PREF_AUTO_FORMER_BUILD_ADV) ~= 0) then
        return E.FORMER_CONDENSER
    end
    if not use_sensor and bit.band(items, E.BIT_FARM) ~= 0 and bit.band(items, E.BIT_SOIL_ENRICHER) == 0
        and funcs.has_terra(E.FORMER_SOIL_ENR, sea and 1 or 0, faction_id) then
        return E.FORMER_SOIL_ENR
    end
    if can_sensor(x, y, faction_id) then
        return E.FORMER_SENSOR
    end
    if forest_val > current + skip_val and can_forest(x, y, faction_id) then
        return E.FORMER_FOREST
    end
    return E.FORMER_NONE
end

local FORMER_TILE_PRIORITY = {
    { E.BIT_RIVER, 4 },
    { E.BIT_FARM, -2 },
    { E.BIT_SOLAR, -2 },
    { E.BIT_FOREST, -4 },
    { E.BIT_MINE, -4 },
    { E.BIT_CONDENSER, -4 },
    { E.BIT_SOIL_ENRICHER, -4 },
    { E.BIT_THERMAL_BORE, -8 },
}

-- former_move port, sub-stage 3 (IMPLEMENTATION_DETAILS.md 4.13):
-- former_tile_score (move.cpp:2004-2045) -- former_move's own site-
-- scoring formula (which tile is worth terraforming), real AI policy,
-- consumed by former_move's TileSearch scan (sub-stage 4). No new
-- engine surface needed beyond one enum (LM_NEXUS) -- everything else
-- was already exposed by earlier stages, including sub-stages 1-2's
-- own keep_fungus/plant_fungus_flag/build_tubes/map_roads/map_former.
local function former_tile_score(x, y, faction_id)
    local items = funcs.tile_items(x, y)
    local alt = funcs.tile_alt_level(x, y)
    local bonus = funcs.tile_bonus(x, y)
    local lm = funcs.tile_lm_items(x, y)
    local score = (bit.band(lm, bit.bnot(bit.bor(E.LM_DUNES, E.LM_SARGASSO, E.LM_UNITY, E.LM_NEXUS))) ~= 0)
        and 4 or 0

    if bonus ~= E.RES_NONE and bit.band(items, bit.bor(E.BIT_CONDENSER, E.BIT_THERMAL_BORE)) == 0 then
        score = score
            + (bit.band(items, bit.bor(E.BIT_FARM, E.BIT_MINE, E.BIT_SOLAR, E.BIT_FOREST)) ~= 0 and 3 or 5)
                * (bonus == E.RES_NUTRIENT and 3 or 2)
    end
    for _, p in ipairs(FORMER_TILE_PRIORITY) do
        if bit.band(items, p[1]) ~= 0 then
            score = score + p[2]
        end
    end
    if funcs.tile_is_fungus(x, y) then
        score = score + (bit.band(items, bit.bor(E.BIT_CONDENSER, E.BIT_THERMAL_BORE)) ~= 0 and 20 or 0)
        score = score + (funcs.keep_fungus(faction_id) ~= 0 and -8 or (funcs.tile_is_rocky(x, y) and 2 or -2))
        score = score
            + (funcs.plant_fungus_flag(faction_id) ~= 0 and bit.band(items, E.BIT_ROAD) ~= 0 and -8 or 0)
    elseif funcs.plant_fungus_flag(faction_id) ~= 0 then
        score = score + 8
    end
    if bit.band(items, bit.bor(E.BIT_FOREST, E.BIT_SENSOR)) ~= 0 and can_road(x, y, faction_id) then
        score = score + 8
    end
    if funcs.map_roads(x, y) > 0 and (bit.band(items, E.BIT_ROAD) == 0
        or (funcs.build_tubes(faction_id) ~= 0 and bit.band(items, E.BIT_MAGTUBE) == 0)) then
        score = score + 15
    end
    if alt == E.ALT_SHORE_LINE and funcs.has_map_node(x, y, E.NODE_GOAL_RAISE_LAND) then
        score = score + 20
    end
    return score + min(8, funcs.map_former(x, y)) + min(0, map.safety(x, y))
end

-- former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
-- former_move itself (move.cpp:2047-2202), Class 3. Assembles
-- select_item/former_tile_score (sub-stages 2-3) with a new TileSearch
-- scan (own triad; a bare walk, since every one of the original's
-- filter conditions is already an atomic fact Lua can read itself) and
-- reuses the already-ported search_base/search_route for its own
-- tail-end fallback -- no new work needed for either. `sq` in the
-- original is mapsq(veh->x, veh->y), unchanged until the TileSearch
-- scan starts -- `sea` here is that same tile_is_ocean read, reused
-- everywhere the original reused `sq`.
local function former_move(veh_id)
    local v = veh.get(veh_id)
    local faction_id = v.faction_id
    local at_base = funcs.tile_is_base(v.x, v.y) and funcs.tile_owner(v.x, v.y) == faction_id
    local safe = map.safety(v.x, v.y) >= E.PM_SAFE
    local mode = E.FM_Auto_Full

    if funcs.tile_owner(v.x, v.y) ~= faction_id and funcs.map_roads(v.x, v.y) < 1 then
        return funcs.move_to_base(veh_id, false)
    end
    if funcs.defend_tile(veh_id) then
        return funcs.set_order_none(veh_id)
    end
    local sea = funcs.tile_is_ocean(v.x, v.y)
    if sea and veh.triad(v) == E.TRIAD_LAND then
        if not funcs.has_transport(v.x, v.y, faction_id) then
            funcs.mark_map_node(v.x, v.y, E.NODE_NEED_FERRY)
            return funcs.mod_veh_skip(veh_id)
        end
        local coord = ffi.new("int32_t[2]")
        for i = 1, 8 do
            if funcs.tile_neighbor(v.x, v.y, i, coord, coord + 1) then
                local nx, ny = coord[0], coord[1]
                if funcs.allow_civ_move(nx, ny, faction_id, E.TRIAD_LAND) and rand.map(0, 2) == 0 then
                    log.debug("former_trans %2d %2d -> %2d %2d", v.x, v.y, nx, ny)
                    return funcs.set_move_to(veh_id, nx, ny)
                end
            end
        end
        return funcs.mod_veh_skip(veh_id)
    end

    if veh.plr_owner(v) then
        if v.order_auto_type == E.ORDERA_TERRA_AUTO_MAGTUBE
            and funcs.has_terra(E.FORMER_MAGTUBE, sea and 1 or 0, faction_id) then
            mode = E.FM_Auto_Tubes
        elseif v.order_auto_type == E.ORDERA_TERRA_AUTO_ROAD
            and funcs.has_terra(E.FORMER_ROAD, sea and 1 or 0, faction_id) then
            mode = E.FM_Auto_Roads
        elseif v.order_auto_type == E.ORDERA_TERRA_AUTO_SENSOR
            and funcs.has_terra(E.FORMER_SENSOR, sea and 1 or 0, faction_id) then
            mode = E.FM_Auto_Sensors
        elseif v.order_auto_type == E.ORDERA_TERRA_AUTO_FUNGUS_REM
            and funcs.has_terra(E.FORMER_REMOVE_FUNGUS, sea and 1 or 0, faction_id) then
            mode = E.FM_Remove_Fungus
        elseif v.order_auto_type == E.ORDERA_TERRA_FARM_SOLAR_ROAD then
            mode = E.FM_Farm_Road
        elseif v.order_auto_type == E.ORDERA_TERRA_FARM_MINE_ROAD then
            mode = E.FM_Mine_Road
        end
    end

    local turns = 0
    if v.order >= E.ORDER_FARM and v.order < E.ORDER_MOVE_TO then
        turns = Terraform[v.order - E.ORDER_FARM].rate
    end

    if safe or turns >= 12 or veh.plr_owner(v) then
        if turns > 0 and not (v.order == E.ORDER_DRILL_AQUIFER
            and funcs.nearby_items(v.x, v.y, 0, 9, E.BIT_RIVER) >= 4) then
            return E.VEH_SYNC
        end
        if not veh.at_target(v) and not can_road(v.x, v.y, faction_id) and not can_magtube(v.x, v.y, faction_id) then
            return E.VEH_SYNC
        end
        local item = select_item(v.x, v.y, faction_id, mode)
        if item >= 0 then
            log.debug("former_action %2d %2d item: %d", v.x, v.y, item)
            return funcs.former_apply_action(veh_id, item)
        end
    elseif not safe then
        return escape_move(veh_id)
    end

    if mode == E.FM_Farm_Road or mode == E.FM_Mine_Road then
        funcs.former_request_new_orders(veh_id)
        return E.VEH_SYNC
    end

    local home_base_only = false
    local full_search = imod(game.turn() + veh_id, 4) == 0
    local limit = full_search and 320 or 80
    local best_score = -math.huge
    local bx, by = v.x, v.y
    local item = -1
    local tx, ty = -1, -1

    if v.home_base_id >= 0 and base_api.get(v.home_base_id).faction_id == faction_id then
        local hb = base_api.get(v.home_base_id)
        bx, by = hb.x, hb.y
        if veh.plr_owner(v) and v.order_auto_type == E.ORDERA_TERRA_AUTOIMPROVE_BASE
            and funcs.region_at(v.x, v.y) == funcs.region_at(bx, by) then
            home_base_only = true
        end
    end

    funcs.former_search_start(veh_id)
    local i = 0
    local out = ffi.new("int32_t[3]")
    while i < limit do
        i = i + 1
        funcs.former_search_next(out, out + 1, out + 2)
        if out[0] == 0 then
            break
        end
        local cx, cy = out[1], out[2]
        if not funcs.tile_is_base(cx, cy)
            and not (funcs.tile_owner(cx, cy) ~= faction_id and funcs.map_roads(cx, cy) < 1)
            and not (home_base_only and funcs.map_range(bx, by, cx, cy) > 2)
            and not (funcs.map_former(cx, cy) < 1 and funcs.map_roads(cx, cy) < 1)
            and map.safety(cx, cy) >= E.PM_SAFE
            and not funcs.non_ally_in_tile(cx, cy, faction_id) then
            local score
            if mode == E.FM_Auto_Full then
                score = former_tile_score(cx, cy, faction_id) - idiv(funcs.map_range(bx, by, cx, cy), 2)
            else
                score = former_tile_score(cx, cy, faction_id) - 2 * funcs.map_range(v.x, v.y, cx, cy)
            end
            if score > best_score then
                local choice = select_item(cx, cy, faction_id, mode)
                if choice >= 0 then
                    tx, ty = cx, cy
                    best_score = score
                    item = choice
                end
            end
        end
    end

    if tx >= 0 then
        funcs.former_consume(tx, ty)
        log.debug("former_move %2d %2d -> %2d %2d score: %d item: %d", v.x, v.y, tx, ty, best_score, item)
        return funcs.set_move_to(veh_id, tx, ty)
    end

    log.debug("former_skip %2d %2d", v.x, v.y)
    if funcs.region_at(v.x, v.y) == funcs.region_at(bx, by) and not (v.x == bx and v.y == by)
        and (home_base_only or funcs.map_range(v.x, v.y, bx, by) < rand.map(0, 32)) then
        return funcs.set_move_to(veh_id, bx, by)
    end
    if not at_base then
        local sbx, sby = search_base(veh_id, false)
        if sbx >= 0 then
            return funcs.set_move_to(veh_id, sbx, sby)
        end
    end
    if full_search and not veh.plr_owner(v) then
        local rtx, rty = search_route(veh_id)
        if rtx then
            return funcs.set_move_to(veh_id, rtx, rty)
        end
        if v.home_base_id >= 0 and game.turn() > E.VEH_REMOVE_TURNS and rand.map(0, 4) == 0 then
            return funcs.mod_veh_kill(veh_id)
        end
    end
    return funcs.mod_veh_skip(veh_id)
end

-- move.cpp:2204-2225.
local function artifact_move(veh_id)
    local v = veh.get(veh_id)
    local base_id = map.base_at(v.x, v.y)
    if base_id >= 0 and base_api.get(base_id).faction_id == v.faction_id
        and base_api.can_link_artifact(base_id) then
        log.debug("artifact_link %2d %2d %d", v.x, v.y, base_id)
        funcs.mod_study_artifact(veh_id)
        return E.VEH_SKIP
    end
    if not veh.at_target(v) and v.iter_count < 2 and map.safety(v.x, v.y) >= E.PM_SAFE then
        return E.VEH_SYNC
    end
    local tx, ty = search_route(veh_id)
    if tx then
        log.debug("artifact_move %2d %2d -> %2d %2d", v.x, v.y, tx, ty)
        return funcs.set_move_to(veh_id, tx, ty)
    end
    return funcs.mod_veh_skip(veh_id)
end

-- move.cpp:1167-1221, ported fully to Lua rather than left as an opaque
-- wrapper: crawlers are the single biggest economic lever in the game
-- and the project's explicit priority area (2026-07-21) -- the scoring
-- formula itself is real AI policy, not engine mechanics, even though it
-- consumes engine yield calculators as inputs. Only mod_crop_yield/
-- mod_mine_yield/mod_energy_yield (genuine engine mechanics) and
-- single-field tile reads (MAP* can't cross the FFI boundary) stay as
-- host wrappers.
local function want_convoy(veh_id, x, y)
    local v = veh.get(veh_id)
    local base_id = v.home_base_id
    local score = 0
    local choice = E.RES_NONE
    local owner = map.tile_owner(x, y)

    if not map.tile_is_base(x, y) and base_id >= 0 and (owner == v.faction_id or owner < 0) then
        local base = base_api.get(base_id)
        for i = veh.count() - 1, 0, -1 do
            local other = veh.get(i)
            if i ~= veh_id and other.x == x and other.y == y
                and veh.is_supply(other) and other.order == E.ORDER_CONVOY then
                funcs.mark_convoy_site(x, y)
                return { choice = E.RES_NONE, score = 0 }
            end
        end
        local N = funcs.mod_crop_yield(v.faction_id, base_id, x, y, 0)
        local M = funcs.mod_mine_yield(v.faction_id, base_id, x, y, 0)
        local nrg = funcs.mod_energy_yield(v.faction_id, base_id, x, y, 0)

        local growth_goal = clamp(24 - base.pop_size, 0, funcs.base_unused_space(base_id))
        local Nw = (base.nutrient_surplus < 0 and 8 or min(8, 2 + growth_goal))
            - max(0, base.nutrient_surplus - 14) + (base.pop_size < 4 and 2 or 0)
        local Mw = max(3, idiv(50 - base.mineral_intake_2, 5))
        local Ew = max(3, Mw - 1)
        local B = map.tile_is_base_radius(x, y) and 2 or 4

        local Ns = Nw * N - idiv((M + nrg) * (M + nrg), B)
        local Ms = Mw * M - idiv((N + nrg) * (N + nrg), B)
        local Es = Ew * nrg - idiv((N + M) * (N + M), B)

        if M > 1 and Ms > score then
            choice = E.RES_MINERAL
            score = Ms
        end
        if N > 1 and Ns > score then
            choice = E.RES_NUTRIENT
            score = Ns
        end
        if nrg > 1 and Es > score
            and base.energy_inefficiency * 2 < base.energy_surplus
            and base.mineral_surplus > min(20, 4 + base.pop_size)
            and funcs.has_fac_built(E.FAC_PUNISHMENT_SPHERE, base_id) == 0
            and (funcs.has_fac_built(E.FAC_NETWORK_NODE, base_id) ~= 0
                or funcs.has_fac_built(E.FAC_TREE_FARM, base_id) ~= 0
                or funcs.project_base(E.FAC_SUPERCOLLIDER) == base_id
                or funcs.project_base(E.FAC_THEORY_OF_EVERYTHING) == base_id) then
            choice = E.RES_ENERGY
            score = Es
        end
    end
    if owner == v.faction_id then
        score = score + 8
    end
    return { choice = choice, score = score }
end

-- move.cpp:1223-1288. crawler_home_base_check/crawler_at_target_check
-- each wrap one whole "no real judgment, just eligibility/bookkeeping"
-- block (move.cpp:1229-1239/1240-1246) -- see src/luaai.cpp's own
-- comments on why. The TileSearch scan itself is an incremental
-- iterator (crawler_search_start/_next): TileSearch still never crosses
-- into Lua (Phase 4.3), but this loop drives it directly and scores
-- each candidate with the real (Lua) want_convoy above, so the "which
-- tile is the best crawl target" judgment is genuinely in Lua now, not
-- baked into a host wrapper.
local function crawler_move(veh_id)
    local out = ffi.new("int32_t[2]")
    funcs.crawler_home_base_check(veh_id, out, out + 1)
    if out[0] ~= 0 then
        return out[1]
    end
    funcs.crawler_at_target_check(veh_id, out, out + 1)
    if out[0] ~= 0 then
        return out[1]
    end

    local v = veh.get(veh_id)
    local wc = want_convoy(veh_id, v.x, v.y)
    local best_choice = wc.choice
    local best_score = wc.score

    if best_choice ~= E.RES_NONE and cmath.imod(game.turn() + veh_id, 4) ~= 0 then
        log.debug("crawl_convoy %2d %2d res: %2d score: %2d", v.x, v.y, best_choice, best_score)
        funcs.mark_convoy_site(v.x, v.y)
        return funcs.set_convoy(veh_id, best_choice)
    end

    local limit = (best_choice ~= E.RES_NONE) and 80 or 120
    funcs.crawler_search_start(veh_id, limit)
    local tx, ty = -1, -1
    local search_out = ffi.new("int32_t[4]")
    while true do
        funcs.crawler_search_next(v.faction_id, search_out, search_out + 1, search_out + 2, search_out + 3)
        if search_out[0] == 0 then
            break
        end
        local cand_x, cand_y, dist = search_out[1], search_out[2], search_out[3]
        local cand = want_convoy(veh_id, cand_x, cand_y)
        if cand.choice ~= E.RES_NONE and (cand.score - dist) > best_score then
            best_score = cand.score - dist
            tx, ty = cand_x, cand_y
            log.debug("crawl_score %2d %2d res: %2d score: %2d", cand_x, cand_y, cand.choice, best_score)
        end
    end

    if tx >= 0 then
        log.debug("crawl_move %2d %2d -> %2d %2d", v.x, v.y, tx, ty)
        funcs.mark_convoy_site(tx, ty)
        return funcs.set_move_to(veh_id, tx, ty)
    end
    if best_choice ~= E.RES_NONE then
        log.debug("crawl_convoy %2d %2d res: %2d score: %2d", v.x, v.y, best_choice, best_score)
        funcs.mark_convoy_site(v.x, v.y)
        return funcs.set_convoy(veh_id, best_choice)
    end
    if not funcs.is_human(v.faction_id) and rand.map(0, 4) == 0 then
        return funcs.move_to_base(veh_id, 0)
    end
    return funcs.mod_veh_skip(veh_id)
end

-- path.cpp:567-573. Ported to Lua rather than left opaque: it's the same
-- "compare candidates, pick the best" AI judgment as want_convoy above,
-- shared by search_escape/search_base/escape_move (all below) --
-- discovered while reading colony_move's dependency chain
-- (2026-07-21/22, IMPLEMENTATION_DETAILS.md 4.12).
local function escape_score(x, y, range, veh_id)
    local items = funcs.tile_items(x, y)
    local score = map.safety(x, y) - 32 * funcs.map_target(x, y) - 128 * range
    if bit.band(items, E.BIT_MONOLITH) ~= 0 and funcs.veh_need_monolith(veh_id) then
        score = score + 2000
    end
    if bit.band(items, E.BIT_BUNKER) ~= 0 then
        score = score + 500
    end
    if bit.band(items, E.BIT_FOREST) ~= 0 or funcs.tile_is_rocky(x, y) then
        score = score + 200
    end
    if funcs.has_map_node(x, y, E.NODE_PATROL) then
        score = score + 500
    end
    return score
end

-- path.cpp:575-593. search_escape_start/_next apply the original's own
-- eligibility filter (non_ally_in_tile/is_base+owner+pact/zoc) host-side
-- (same incremental-iterator shape as crawler_search_*) -- only the real
-- per-tile scoring and best-so-far comparison happen here. The `dist > 2
-- and best_score > 500` early-out is checked per candidate returned, same
-- final result as the original checking it per popped tile regardless of
-- eligibility (ineligible tiles never affect best_score either way).
local function search_escape(veh_id)
    local v = veh.get(veh_id)
    local best_score = escape_score(v.x, v.y, 0, veh_id)
    local tx, ty = -1, -1
    funcs.search_escape_start(veh_id)
    local out = ffi.new("int32_t[4]")
    while true do
        funcs.search_escape_next(v.faction_id, out, out + 1, out + 2, out + 3)
        if out[0] == 0 then
            break
        end
        local cx, cy, dist = out[1], out[2], out[3]
        if dist > 2 and best_score > 500 then
            break
        end
        local score = escape_score(cx, cy, dist, veh_id)
        if score > best_score then
            tx, ty = cx, cy
            best_score = score
            log.debug("escape_score %2d %2d -> %2d %2d dist: %d score: %d",
                v.x, v.y, cx, cy, dist, score)
        end
    end
    return tx, ty
end

-- path.cpp:604-657. search_base_start/_next apply the original's own
-- eligibility filters (already-there, is_base+owner/pact, dist/triad
-- gating, allow_move, and -- folded into the host wrapper since it's a
-- pure fact, not a score -- the is_airbase/has_zoc gate that in the
-- original only guards the *assignment*, not the score computation
-- itself; since escape_score has no side effects, never surfacing an
-- ineligible candidate to Lua at all is equivalent). kind: 0 = exhausted,
-- 1 = friendly/pact base found, 2 = scoreable non-base candidate.
search_base = function(veh_id, ally)
    local start_out = ffi.new("int32_t[2]")
    funcs.search_base_start(veh_id, ally and 1 or 0, start_out, start_out + 1)
    if start_out[0] ~= 0 then
        return -1, -1
    end

    local v = veh.get(veh_id)
    local triad = veh.triad(v)
    local best_score
    if triad == E.TRIAD_AIR and funcs.veh_need_refuel(veh_id) then
        best_score = -math.huge
    else
        best_score = escape_score(v.x, v.y, 0, veh_id)
    end

    local found = false
    local tx, ty = -1, -1
    local out = ffi.new("int32_t[4]")
    while true do
        funcs.search_base_next(v.faction_id, triad, ally and 1 or 0, found and 1 or 0,
            out, out + 1, out + 2, out + 3)
        local kind = out[0]
        if kind == 0 then
            break
        elseif kind == 1 then
            tx, ty = out[1], out[2]
            found = true
            if triad == E.TRIAD_AIR or rand.map(0, 2) ~= 0 then
                break
            end
        else
            local cx, cy, dist = out[1], out[2], out[3]
            local score = escape_score(cx, cy, dist, veh_id)
            if score > best_score then
                tx, ty = cx, cy
                best_score = score
            end
        end
    end
    return tx, ty
end

-- path.cpp:551-564.
escape_move = function(veh_id)
    if funcs.defend_tile(veh_id) then
        return funcs.set_order_none(veh_id)
    end
    local tx, ty = search_escape(veh_id)
    if tx >= 0 then
        return funcs.set_move_to(veh_id, tx, ty)
    end
    return funcs.mod_veh_skip(veh_id)
end

local PRIORITY = {
    { E.BIT_FUNGUS, -2 },
    { E.BIT_FARM, 2 },
    { E.BIT_FOREST, 2 },
    { E.BIT_MONOLITH, 4 },
}

-- move.cpp:1339-1399, colony_move's own site-scoring formula -- real AI
-- policy (the "which tile is worth founding a base on" judgment), ported
-- fully to Lua. tile_neighbor drives the 21-tile iterate_tiles(x,y,0,21)
-- scan itself (Phase 4.3: TableOffsetX/Y ring geometry stays in C++, the
-- scoring built on top does not).
local function base_tile_score(x, y, faction_id)
    local map_area_y = game.map_area_y()
    local sea_colony = funcs.tile_alt_level(x, y) < E.ALT_SHORE_LINE
    local score = idiv(min(min(y, map_area_y - y), min(idiv(map_area_y, 4), 24)), 2)
    local land = 0
    local items = funcs.tile_items(x, y)
    if bit.band(items, E.BIT_SENSOR) ~= 0 then
        score = score + 8
    end
    if not sea_colony then
        if funcs.ocean_coast_tiles(x, y) then
            score = score + 12
        end
        if bit.band(items, E.BIT_RIVER) ~= 0 then
            score = score + 6
        end
    end

    local coord = ffi.new("int32_t[2]")
    for i = 0, 20 do
        if funcs.tile_neighbor(x, y, i, coord, coord + 1) then
            local tx, ty = coord[0], coord[1]
            if not funcs.tile_is_base(tx, ty) then
                local bn = funcs.tile_bonus(tx, ty)
                local lm = funcs.tile_lm_items(tx, ty)
                local alt = funcs.tile_alt_level(tx, ty)
                local m_items = funcs.tile_items(tx, ty)
                if bit.band(lm, bit.bnot(bit.bor(E.LM_DUNES, E.LM_SARGASSO, E.LM_UNITY))) ~= 0 then
                    score = score + (bit.band(lm, E.LM_JUNGLE) ~= 0 and 3 or 2)
                end
                if i == 0 then
                    if bn ~= 0 then
                        score = score + (bn ~= E.RES_ENERGY and 4 or 3)
                    end
                else
                    if bn ~= 0 then
                        score = score + (bn ~= E.RES_ENERGY and 8 or 6)
                    end
                    local owner = funcs.tile_owner(tx, ty)
                    if i <= 8 then
                        if sea_colony and funcs.tile_is_land_region(tx, ty)
                            and map.continent(funcs.tile_region(tx, ty)).tile_count >= 20
                            and (owner < 0 or owner == faction_id) then
                            -- move.cpp:1373 pre-increments land as part of
                            -- the `&&` chain (`++land < 3`), so the
                            -- comparison sees the *post*-increment value --
                            -- only the first two qualifying tiles ever
                            -- grant the bonus, not three (the third
                            -- increments land to 3 and fails `3 < 3`).
                            land = land + 1
                            if land < 3 then
                                score = score + (owner < 0 and 20 or 4)
                            end
                        end
                        if alt == E.ALT_OCEAN_SHELF then
                            score = score + (sea_colony and 3 or 2)
                        end
                        if alt <= E.ALT_OCEAN then
                            score = score - (alt < E.ALT_OCEAN and 8 or 4)
                        end
                    end
                    if sea_colony ~= (alt < E.ALT_SHORE_LINE) and funcs.both_non_enemy(faction_id, owner) then
                        score = score - 5
                    end
                    if alt >= E.ALT_SHORE_LINE then
                        if funcs.tile_is_rainy(tx, ty) then
                            score = score + 2
                        end
                        if funcs.tile_is_moist(tx, ty) and funcs.tile_is_rolling(tx, ty) then
                            score = score + 2
                        end
                        if bit.band(m_items, E.BIT_RIVER) ~= 0 then
                            score = score + 1
                        end
                    end
                    for _, p in ipairs(PRIORITY) do
                        if bit.band(m_items, p[1]) ~= 0 then
                            score = score + p[2]
                        end
                    end
                end
            end
        end
    end
    return score + min(0, map.safety(x, y))
end

-- path.cpp:474-485. Pure fact (a garrison-strength count at a tile,
-- consumed later by colony_move's own random(8) comparison) built
-- entirely from already-exposed veh.get/veh.count/veh.at_target/
-- veh.eval_garrison -- no new host wrapper needed.
local function defender_count(x, y, veh_skip_id)
    local num = 0
    for i = veh.count() - 1, 0, -1 do
        local other = veh.get(i)
        if other.x == x and other.y == y and other.order ~= E.ORDER_SENTRY_BOARD
            and veh.at_target(other) and i ~= veh_skip_id then
            num = num + veh.eval_garrison(other)
        end
    end
    return idiv(num + 1, 4)
end

-- path.cpp:659-673, route_score -- search_route's own scoring formula
-- (continent size, home-region bonus, distance penalty, artifact-linking
-- bonus, pod-density bonus), the real AI judgment that was flagged baked
-- into the opaque path.search_route host wrapper (IMPLEMENTATION_DETAILS.md
-- 4.12's "search + score" audit, same defect class want_convoy/
-- base_tile_score already had fixed). Ported now as its own sub-stage; the
-- two plain Bases[] scans below consume it directly, the three
-- TileSearch-driven scans (sea-triad branch, general territory-pact
-- branch, naval-pickup-point search) are deferred to a following
-- sub-stage that assembles the full search_route replacement. `sq` in the
-- original is mapsq(x, y) -- the candidate tile -- at every call site
-- except one: path.cpp:760 passes x,y=veh->x,veh->y but a *stale* `sq`
-- left over from the Bases[] scan just above it (whatever base the loop
-- last matched, not mapsq(veh->x, veh->y)) -- a genuine inconsistency in
-- the original, not a formatting quirk, replicated here (not "fixed") via
-- the optional sq_x/sq_y override, per this project's 1:1-before-
-- improvement rule. Every other call site omits them, so sq matches x,y
-- as usual.
local function route_score(veh_id, x, y, modifier, sq_x, sq_y)
    sq_x = sq_x or x
    sq_y = sq_y or y
    local v = veh.get(veh_id)
    local region = funcs.tile_region(sq_x, sq_y)
    local sea = funcs.tile_is_ocean(sq_x, sq_y)
    local continent = map.continent(region)
    local score = (sea and 0 or min(16, idiv(continent.tile_count, 32)))
        + (region == funcs.main_region(v.faction_id) and 32 or 0)
        - modifier * (sea and 2 or 1) * funcs.map_range(v.x, v.y, x, y)
        - 4 * funcs.map_target(x, y)
    if veh.is_artifact(v) and not funcs.has_map_node(x, y, E.NODE_NAVAL_START) then
        score = score + 64 * (funcs.can_link_artifact(map.base_at(x, y)) and 1 or 0)
    end
    if veh.is_combat_unit(v) and not sea then
        score = score + 2 * max(0, continent.pods - idiv(continent.tile_count, 32))
    end
    return score
end

-- path.cpp:743-756, search_route's first Bases[] scan: the best "home
-- base" candidate by route_score, plus whether the vehicle is currently
-- standing on a base with an available Psi Gate connection (has_gate).
-- Pure Bases[] iteration, no TileSearch involved -- same direct-loop
-- style as select_colony/select_combat's own Bases[] scans
-- (IMPLEMENTATION_DETAILS.md 4.8). mapsq(base->x, base->y)'s null check
-- is dropped: a founded base always sits on a valid map tile. Also
-- returns the last faction-owned base matched by the scan (last_x/
-- last_y, in array-index order, regardless of its score) -- this is the
-- stale `sq` route_score's own comment documents; a real match is
-- guaranteed whenever the caller needs it (at_base implies the vehicle's
-- own faction owns at least one base, so the scan below always matches
-- at least once in that case).
local function route_best_home_base(veh_id)
    local v = veh.get(veh_id)
    local px, py, has_gate = -1, -1, false
    local best_score = -math.huge
    local last_x, last_y = nil, nil
    for i = 0, base_api.count() - 1 do
        local base = base_api.get(i)
        if base.faction_id == v.faction_id then
            last_x, last_y = base.x, base.y
            local score = route_score(veh_id, base.x, base.y, 4)
            if score > best_score then
                px, py = base.x, base.y
                best_score = score
            end
            if v.x == base.x and v.y == base.y and funcs.can_use_teleport(i) then
                has_gate = true
            end
        end
    end
    return px, py, has_gate, last_x, last_y
end

-- path.cpp:794-816, search_route's Psi-Gate target-base scan and the
-- teleport action itself -- only reached when the vehicle stands on a
-- gate-connected home base (has_gate, from route_best_home_base above).
-- Returns tx, ty (equal to px, py) if the teleport action fired, or nil
-- if no eligible target base was found. best_score's floor of literal
-- -20 is the original's own exact value (not the scan's usual "no
-- candidate yet" sentinel), kept as-is.
local function route_gate_teleport(veh_id, px, py)
    local v = veh.get(veh_id)
    local target_region = funcs.region_at(px, py)
    local tgt_id = -1
    local best_score = -20
    for i = 0, base_api.count() - 1 do
        local base = base_api.get(i)
        if base.faction_id == v.faction_id and funcs.has_fac_built(E.FAC_PSI_GATE, i)
            and funcs.region_at(base.x, base.y) == target_region then
            local score = base.pop_size - funcs.map_range(px, py, base.x, base.y)
            if score > best_score then
                tgt_id = i
                best_score = score
            end
        end
    end
    if tgt_id >= 0 then
        log.debug("route_gate %2d %2d -> %2d %2d base: %d", v.x, v.y, px, py, tgt_id)
        funcs.net_action_gate(veh_id, tgt_id)
        return px, py
    end
    return nil
end

-- path.cpp:675-885, search_route in full -- assembles route_score and
-- both plain Bases[] scans (above) with the three TileSearch-driven
-- scans below, resolving the pending item flagged in IMPLEMENTATION_
-- DETAILS.md 4.12 (route_score baked into an opaque host wrapper), the
-- whole reason this sub-stage exists. Returns tx, ty on success, nil on
-- failure. Note the original's own final `return *tx >= 0`: `*tx`/`*ty`
-- are only ever set by the same_reg branch at the very end or by one of
-- the two early returns in between -- finding a candidate px/py that is
-- neither same_reg nor resolved by gate-teleport/naval-pickup is a real
-- "not found" outcome in the original (not a bug), so no fallback to
-- `px, py` is added here. mapsq(veh->x, veh->y)'s null check at the top
-- is dropped: a dispatched vehicle always sits on a valid map tile.
search_route = function(veh_id)
    local v = veh.get(veh_id)
    local faction_id = v.faction_id
    local veh_reg = funcs.tile_region(v.x, v.y)
    local combat = veh.is_combat_unit(v)
    local continent = map.continent(veh_reg)
    local scout = combat and not funcs.bad_reg(veh_reg)
        and continent.pods > idiv(continent.tile_count, 32)
    local at_base = funcs.tile_is_base(v.x, v.y) and funcs.tile_owner(v.x, v.y) == faction_id
    local triad = veh.triad(v)

    if triad == E.TRIAD_AIR then
        local tx, ty = funcs.main_region_x(faction_id), funcs.main_region_y(faction_id)
        if tx >= 0 and (tx ~= v.x or ty ~= v.y) then
            return tx, ty
        end
        return nil
    end

    if triad == E.TRIAD_SEA then
        if not veh.is_transport(v) then
            return nil
        end
        local naval_start_x, naval_start_y = funcs.naval_start_x(faction_id), funcs.naval_start_y(faction_id)
        local naval_end_x, naval_end_y = funcs.naval_end_x(faction_id), funcs.naval_end_y(faction_id)
        local invade = naval_start_x >= 0 and funcs.invasion_unit(veh_id)
        local tx, ty, best_score = -1, -1, -math.huge
        funcs.route_search_sea_start(veh_id)
        local out = ffi.new("int32_t[4]")
        while true do
            funcs.route_search_sea_next(faction_id, out, out + 1, out + 2, out + 3)
            if out[0] == 0 then
                break
            end
            local cx, cy, dist = out[1], out[2], out[3]
            local score = route_score(veh_id, cx, cy, 1)
            if invade then
                score = score - 4 * min(funcs.map_range(cx, cy, naval_start_x, naval_start_y),
                    funcs.map_range(cx, cy, naval_end_x, naval_end_y))
            end
            if score > best_score then
                tx, ty = cx, cy
                best_score = score
            end
            if tx >= 0 and dist >= 25 then
                break
            end
        end
        if tx >= 0 then
            return tx, ty
        end
        return nil
    end

    if not combat then
        if veh.in_transit(v) or (at_base and faction.get(faction_id).base_count < 2) then
            return nil
        end
        if map.safety(v.x, v.y) < E.PM_SAFE then
            local ex, ey = search_escape(veh_id)
            if ex >= 0 then
                return ex, ey
            end
        end
    end

    local px, py, has_gate, last_base_x, last_base_y = route_best_home_base(veh_id)

    local best_score = -math.huge
    if at_base and veh.is_artifact(v) then
        best_score = route_score(veh_id, v.x, v.y, 1, last_base_x, last_base_y)
    end
    local same_reg = false
    funcs.route_search_pact_start(veh_id)
    local out2 = ffi.new("int32_t[6]")
    while true do
        funcs.route_search_pact_next(faction_id, combat and 1 or 0, scout and 1 or 0,
            out2, out2 + 1, out2 + 2, out2 + 3, out2 + 4, out2 + 5)
        if out2[0] == 0 then
            break
        end
        local cx, cy, dist, naval_pick, is_base_safe = out2[1], out2[2], out2[3], out2[4], out2[5]
        if naval_pick ~= 0 then
            if funcs.cargo_capacity(cx, cy, faction_id) > 0 then
                log.debug("route_load %2d %2d", cx, cy)
                return cx, cy
            end
            if v.iter_count == 0 or rand.map(0, 4) ~= 0 then
                log.debug("route_skip %2d %2d", cx, cy)
                return nil
            end
        end
        if is_base_safe ~= 0 then
            local score = route_score(veh_id, cx, cy, 1)
            if score > best_score then
                px, py = cx, cy
                best_score = score
                same_reg = funcs.tile_region(cx, cy) == veh_reg
                    and dist < 8 + 2 * funcs.map_range(v.x, v.y, cx, cy)
            end
            if px >= 0 and dist >= 25 then
                break
            end
        end
    end

    if px >= 0 and has_gate then
        local tx, ty = route_gate_teleport(veh_id, px, py)
        if tx then
            return tx, ty
        end
    end

    if px >= 0 and not same_reg and (not at_base or not veh.is_artifact(v)) then
        local seed_out = ffi.new("int32_t[3]")
        funcs.route_search_naval_seed(veh_id, px, py, seed_out, seed_out + 1, seed_out + 2)
        if seed_out[0] ~= 0 then
            log.debug("route_redirect %2d %2d", seed_out[1], seed_out[2])
            return seed_out[1], seed_out[2]
        end

        funcs.route_search_naval_pickup_start()
        local best_tx, best_ty, best_prev_x, best_prev_y = nil, nil, nil, nil
        local best_route_score = -math.huge
        local out3 = ffi.new("int32_t[6]")
        while true do
            funcs.route_search_naval_pickup_next(out3, out3 + 1, out3 + 2, out3 + 3, out3 + 4, out3 + 5)
            if out3[0] == 0 then
                break
            end
            local cx, cy, dist, prev_x, prev_y = out3[1], out3[2], out3[3], out3[4], out3[5]
            if funcs.tile_region(cx, cy) == veh_reg and dist > 3
                and not funcs.tile_is_base(cx, cy) and not funcs.tile_is_base(prev_x, prev_y)
                and funcs.allow_civ_move(cx, cy, faction_id, E.TRIAD_LAND)
                and funcs.allow_civ_move(prev_x, prev_y, faction_id, E.TRIAD_SEA) then
                local d2 = funcs.map_range(v.x, v.y, cx, cy)
                local score = 16 * (funcs.has_map_node(prev_x, prev_y, E.NODE_NAVAL_PICK) and 1 or 0)
                    + 8 * ((funcs.tile_is_fungus(cx, cy) == veh.is_native_unit(v)) and 1 or 0)
                    + min(0, idiv(map.safety(cx, cy), 32))
                    - dist - 2 * d2
                if score > best_route_score then
                    best_tx, best_ty = cx, cy
                    best_prev_x, best_prev_y = prev_x, prev_y
                    best_route_score = score
                end
            end
        end
        if best_tx then
            funcs.mark_map_node(best_prev_x, best_prev_y, E.NODE_NAVAL_PICK)
            funcs.mark_map_node(best_prev_x, best_prev_y, E.NODE_NEED_FERRY)
            funcs.add_goal(faction_id, E.AI_GOAL_NAVAL_PICK, 3, best_prev_x, best_prev_y, -1)
            if funcs.cargo_capacity(best_prev_x, best_prev_y, faction_id) > 0 then
                log.debug("route_pickup_load %2d %2d", best_prev_x, best_prev_y)
                return best_prev_x, best_prev_y
            end
            log.debug("route_pickup_wait %2d %2d", best_tx, best_ty)
            return best_tx, best_ty
        end
    end

    if same_reg then
        log.debug("route_move %2d %2d -> %2d %2d", v.x, v.y, px, py)
        return px, py
    end
    return nil
end

-- move.cpp:1405-1528.
local function colony_move(veh_id)
    local v = veh.get(veh_id)
    local faction_id = v.faction_id
    local triad = veh.triad(v)

    if funcs.defend_tile(veh_id) or v.iter_count >= 4 then
        return funcs.set_order_none(veh_id)
    end
    if map.safety(v.x, v.y) < E.PM_SAFE and not funcs.is_human(faction_id) then
        return escape_move(veh_id)
    end
    if funcs.can_build_base(v.x, v.y, faction_id, triad) then
        if triad == E.TRIAD_LAND and (veh.at_target(v)
            or funcs.ocean_coast_tiles(v.x, v.y) or not funcs.near_ocean_coast(v.x, v.y)) then
            return funcs.net_action_build(veh_id)
        elseif triad == E.TRIAD_SEA and veh.at_target(v) then
            return funcs.net_action_build(veh_id)
        elseif triad == E.TRIAD_AIR then
            return funcs.net_action_build(veh_id)
        end
    end

    if funcs.tile_alt_level(v.x, v.y) < E.ALT_SHORE_LINE and triad == E.TRIAD_LAND then
        local out = ffi.new("int32_t[3]")
        funcs.colony_transport_check(veh_id, out, out + 1, out + 2)
        if out[0] ~= 0 and out[1] >= 0 then
            log.debug("colony_trans %2d %2d -> %2d %2d", v.x, v.y, out[1], out[2])
            return funcs.set_move_to(veh_id, out[1], out[2])
        end
        return funcs.mod_veh_skip(veh_id)
    end

    if not veh.at_target(v)
        and (bit.band(v.state, E.VSTATE_UNK_40000) ~= 0 or bit.band(v.state, E.VSTATE_UNK_2000) == 0)
        and funcs.can_build_base(v.waypoint_x[0], v.waypoint_y[0], faction_id, triad) then
        local coord = ffi.new("int32_t[2]")
        for i = 0, 8 do
            if funcs.tile_neighbor(v.waypoint_x[0], v.waypoint_y[0], i, coord, coord + 1) then
                funcs.mark_map_node(coord[0], coord[1], E.NODE_BASE_SITE)
            end
        end
        funcs.connect_roads(v.waypoint_x[0], v.waypoint_y[0], faction_id)
        return E.VEH_SYNC
    end

    local owner = funcs.tile_owner(v.x, v.y)
    local at_base = funcs.tile_is_base(v.x, v.y) and owner == faction_id
    local skip_owner = owner >= 0 and owner ~= faction_id and not funcs.has_pact(faction_id, owner)

    local start_out = ffi.new("int32_t[3]")
    funcs.colony_search_start(veh_id, skip_owner and 1 or 0, start_out, start_out + 1, start_out + 2)
    local airdrop, veh_region = start_out[0], start_out[1]

    local best_score = -math.huge
    local k = 0
    local tx, ty = -1, -1
    local out = ffi.new("int32_t[4]")
    while true do
        funcs.colony_search_next(faction_id, triad, skip_owner and 1 or 0, airdrop, veh_region,
            out, out + 1, out + 2, out + 3)
        if out[0] == 0 then
            break
        end
        local cx, cy, dist = out[1], out[2], out[3]
        local score = base_tile_score(cx, cy, faction_id) - 2 * dist
        if score > best_score then
            tx, ty = cx, cy
            best_score = score
        end
        k = k + 1
        if k >= 25 and best_score >= 0 and dist >= (triad == E.TRIAD_LAND and 8 or 16) then
            local cand_owner = funcs.tile_owner(cx, cy)
            if cand_owner ~= faction_id or not funcs.tile_is_visible(cx, cy, faction_id) or dist >= 32 then
                break
            end
        end
    end

    if tx >= 0 then
        funcs.mark_base_site_radius(tx, ty)
        if airdrop > 0 and funcs.map_range(v.x, v.y, tx, ty) <= airdrop
            -- move.cpp:1490 deliberately uses region_at(), not sq->region
            -- (unlike every other region check in this function) -- kept
            -- as-is rather than "fixed" to match the others.
            and (veh_region ~= funcs.region_at(tx, ty)
                or funcs.path_cost(v.x, v.y, tx, ty, v.unit_id, faction_id, funcs.veh_speed(veh_id, 0)) < 0) then
            log.debug("colony_drop %2d %2d -> %2d %2d", v.x, v.y, tx, ty)
            funcs.action_airdrop(veh_id, tx, ty, 3)
            return E.VEH_SKIP
        end
        log.debug("colony_move %2d %2d -> %2d %2d", v.x, v.y, tx, ty)
        funcs.set_colony_automation_flags(veh_id)
        funcs.connect_roads(tx, ty, faction_id)
        return funcs.set_move_to(veh_id, tx, ty)
    end

    if not at_base then
        local bx, by = search_base(veh_id, false)
        if bx >= 0 then
            log.debug("colony_base %2d %2d -> %2d %2d", v.x, v.y, bx, by)
            return funcs.set_move_to(veh_id, bx, by)
        end
    end

    if not funcs.is_human(faction_id) then
        local naval_x = funcs.naval_start_x(faction_id)
        local naval_y = funcs.naval_start_y(faction_id)
        if naval_x >= 0 and veh_region == funcs.main_region(faction_id)
            and not (v.x == naval_x and v.y == naval_y) then
            log.debug("colony_naval %2d %2d -> %2d %2d", v.x, v.y, naval_x, naval_y)
            return funcs.set_move_to(veh_id, naval_x, naval_y)
        end
        local rtx, rty = search_route(veh_id)
        if rtx then
            return funcs.set_move_to(veh_id, rtx, rty)
        end
        if game.turn() > E.VEH_REMOVE_TURNS
            and (game.base_count() < types.counts.MaxBaseNum or faction.get(faction_id).base_count >= 2)
            and (v.home_base_id >= 0 or game.base_count() > 16 + rand.map(0, 256))
            and (not at_base or defender_count(v.x, v.y, veh_id) > rand.map(0, 8)) then
            return funcs.mod_veh_kill(veh_id)
        end
    end
    return funcs.mod_veh_skip(veh_id)
end

port.artifact_move = artifact_move
port.crawler_move = crawler_move
port.colony_move = colony_move
port.former_move = former_move
port.escape_move = escape_move
return port
