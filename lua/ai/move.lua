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
local faction = dofile("lua/api/faction.lua")

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
local function search_base(veh_id, ally)
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
local function escape_move(veh_id)
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

-- move.cpp:1405-1528. search_route's own defect (route_score is real
-- scoring baked into an opaque host wrapper, IMPLEMENTATION_DETAILS.md
-- 4.12) is deferred to its own future stage -- colony_move keeps the
-- existing path.search_route call for its one fallback call site until
-- that stage lands.
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
        local route = path.search_route(veh_id, v.x, v.y)
        if route.found then
            return funcs.set_move_to(veh_id, route.tx, route.ty)
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
port.escape_move = escape_move
return port
