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
-- TileSearch stays entirely in C++ (Phase 4.3) -- path.search_route
-- constructs and discards its own local TileSearch on the host side.
local port = {
    source = {
        artifact_move = { file = "src/move.cpp", func = "artifact_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local veh = dofile("lua/api/veh.lua")
local base_api = dofile("lua/api/base.lua")
local map = dofile("lua/api/map.lua")
local path = dofile("lua/api/path.lua")
local log = dofile("lua/api/log.lua")

local E = types.enums

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
    local route = path.search_route(veh_id, v.x, v.y)
    if route.found then
        log.debug("artifact_move %2d %2d -> %2d %2d", v.x, v.y, route.tx, route.ty)
        return funcs.set_move_to(veh_id, route.tx, route.ty)
    end
    return funcs.mod_veh_skip(veh_id)
end

port.artifact_move = artifact_move
return port
