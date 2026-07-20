-- VEH accessors (select_build itself, porting-order item 3 final piece,
-- IMPLEMENTATION_DETAILS.md 4.10.1: VEH's first-ever FFI exposure).
--
-- Vehs[] is a mutable, re-pointable pointer (like Bases[],
-- IMPLEMENTATION_DETAILS.md 3.2) -- get() re-fetches it via the host API
-- on every access instead of caching one ffi.cast, same pattern as
-- lua/api/base.lua.
--
-- The is_*()/triad()/eval_garrison() methods below are VEH's own inline
-- methods (engine_veh.h:595-631/690-692), re-ported the same way tech.lua's
-- proto_* helpers re-port UNIT's -- all but is_combat_unit/is_garrison_unit
-- are pure delegation to the matching tech.proto_is_* on veh.unit_id.
local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local tech = dofile("lua/api/tech.lua")

local VehCount = ffi.cast("int32_t*", types.globals.VehCount)

local function count()
    return VehCount[0]
end

local function get(veh_id)
    assert(veh_id >= 0 and veh_id < count(), "veh_id out of range: " .. tostring(veh_id))
    local Vehs = ffi.cast("VEH*", funcs.vehs_ptr())
    return Vehs[veh_id]
end

local function is_former(veh)
    return tech.proto_is_former(veh.unit_id)
end

local function is_colony(veh)
    return tech.proto_is_colony(veh.unit_id)
end

local function is_probe(veh)
    return tech.proto_is_probe(veh.unit_id)
end

local function is_supply(veh)
    return tech.proto_is_supply(veh.unit_id)
end

local function is_transport(veh)
    return tech.proto_is_transport(veh.unit_id)
end

local function is_artifact(veh)
    return tech.proto_is_artifact(veh.unit_id)
end

-- select_build itself, unit-branch catalog continued (IMPLEMENTATION_
-- DETAILS.md 4.10.28): find_project's own VEH scan (SecretProject
-- branch). engine_veh.h:577-578 delegates the same way is_former/etc do.
local function is_planet_buster(veh)
    return tech.proto_is_planet_buster(veh.unit_id)
end

local function triad(veh)
    return tech.proto_triad(veh.unit_id)
end

-- engine_veh.h:595-597: not pure delegation, adds a BSC_FUNGAL_TOWER
-- exclusion on top of Units[unit_id].is_combat_unit().
local function is_combat_unit(veh)
    return tech.proto_is_combat_unit(veh.unit_id) and veh.unit_id ~= types.enums.BSC_FUNGAL_TOWER
end

local function is_garrison_unit(veh)
    return tech.proto_is_garrison_unit(veh.unit_id)
end

-- engine_veh.h:690-692.
local function eval_garrison(veh)
    return (triad(veh) == types.enums.TRIAD_LAND and 2 or 1)
        + (is_combat_unit(veh) and 1 or 0) + (tech.proto_is_armored(veh.unit_id) and 1 or 0)
end

-- Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12): artifact_move's
-- own re-check-in-progress-order branch. engine_veh.h:647-650 -- pure
-- delegation to already/newly-exposed fields, no host wrapper needed.
local function at_target(veh)
    return veh.order == types.enums.ORDER_NONE or veh.order == types.enums.ORDER_HOLD
        or (veh.waypoint_x[0] < 0 and veh.waypoint_y[0] < 0)
        or (veh.x == veh.waypoint_x[0] and veh.y == veh.waypoint_y[0] and veh.waypoint_count == 0)
end

return {
    count = count,
    get = get,
    is_former = is_former,
    is_colony = is_colony,
    is_probe = is_probe,
    is_supply = is_supply,
    is_transport = is_transport,
    is_artifact = is_artifact,
    is_planet_buster = is_planet_buster,
    triad = triad,
    is_combat_unit = is_combat_unit,
    is_garrison_unit = is_garrison_unit,
    eval_garrison = eval_garrison,
    at_target = at_target,
}
