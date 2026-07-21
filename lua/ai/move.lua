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
        crawler_move = { file = "src/move.cpp", func = "crawler_move",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        want_convoy = { file = "src/move.cpp", func = "want_convoy",
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
local cmath = dofile("lua/api/cmath.lua")
local game = dofile("lua/api/game.lua")
local rand = dofile("lua/api/rand.lua")

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

-- move.cpp:1167-1221. Real engine mechanics (tile-yield scoring), not AI
-- policy -- opaque host wrapper, same tier as former_tile_tally.
local function want_convoy(veh_id, x, y)
    local out = ffi.new("int32_t[2]")
    funcs.want_convoy(veh_id, x, y, out, out + 1)
    return { choice = out[0], score = out[1] }
end

-- move.cpp:1223-1288. crawler_home_base_check/crawler_at_target_check
-- each wrap one whole "no real judgment, just eligibility/bookkeeping"
-- block (move.cpp:1229-1239/1240-1246) -- see src/luaai.cpp's own
-- comments on why. The TileSearch scan (crawler_find_convoy_site) stays
-- opaque per Phase 4.3, reusing the real want_convoy internally per
-- candidate tile; only the outer control flow (which branch to take,
-- when to mark a convoy site and hand off to set_convoy/set_move_to/
-- move_to_base/mod_veh_skip) is genuine AI orchestration, ported here.
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
        funcs.mark_convoy_site(v.x, v.y)
        return funcs.set_convoy(veh_id, best_choice)
    end

    local limit = (best_choice ~= E.RES_NONE) and 80 or 120
    local search_out = ffi.new("int32_t[4]")
    funcs.crawler_find_convoy_site(veh_id, best_score, limit,
        search_out, search_out + 1, search_out + 2, search_out + 3)
    local found = search_out[0] ~= 0
    local tx, ty = search_out[1], search_out[2]

    if found then
        funcs.mark_convoy_site(tx, ty)
        return funcs.set_move_to(veh_id, tx, ty)
    end
    if best_choice ~= E.RES_NONE then
        funcs.mark_convoy_site(v.x, v.y)
        return funcs.set_convoy(veh_id, best_choice)
    end
    if not funcs.is_human(v.faction_id) and rand.map(0, 4) == 0 then
        return funcs.move_to_base(veh_id, 0)
    end
    return funcs.mod_veh_skip(veh_id)
end

port.artifact_move = artifact_move
port.crawler_move = crawler_move
return port
