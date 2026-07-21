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
local idiv = cmath.idiv
local clamp = cmath.clamp
local min = math.min
local max = math.max

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
        end
    end

    if tx >= 0 then
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
