-- Deliberately minimal (IMPLEMENTATION_PLAN.md Phase 3.2, narrowed to the
-- tech-AI pilot): the handful of bare scalar globals mod_tech_val/
-- mod_tech_ai read (CurrentTurn, GameRules, MapCloudCover). No `game`
-- module owns these yet -- iterators over factions/bases/vehs
-- (game.vehs(), game.bases(), ...) are Phase 4's later modules, on demand.
local types = dofile_once("lua/ffi/validate.lua")

local CurrentTurn = ffi.cast("int32_t*", types.globals.CurrentTurn)
local GameRules = ffi.cast("int32_t*", types.globals.GameRules)
local MapCloudCover = ffi.cast("int32_t*", types.globals.MapCloudCover)
-- Social engineering (porting-order item 2): SunspotDuration/DiffLevel are
-- plain `int*`; MapAreaSqRoot too (IMPLEMENTATION_DETAILS.md 4.5).
local SunspotDuration = ffi.cast("int32_t*", types.globals.SunspotDuration)
local DiffLevel = ffi.cast("int32_t*", types.globals.DiffLevel)
local MapAreaSqRoot = ffi.cast("int32_t*", types.globals.MapAreaSqRoot)
-- War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md 4.6):
-- FactionRankings is an int[MaxPlayerNum] array (ranking position -> faction
-- id), not a scalar -- indexed directly, like the other array fields.
local FactionRankings = ffi.cast("int32_t*", types.globals.FactionRankings)

return {
    turn = function() return CurrentTurn[0] end,
    rules = function() return GameRules[0] end,
    cloud_cover = function() return MapCloudCover[0] end,
    sunspot_duration = function() return SunspotDuration[0] end,
    diff_level = function() return DiffLevel[0] end,
    map_area_sq_root = function() return MapAreaSqRoot[0] end,
    faction_ranking = function(i) return FactionRankings[i] end,
}
