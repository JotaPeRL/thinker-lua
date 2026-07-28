-- 1:1 port of unit_score + find_proto (src/build.cpp), the first slice of
-- porting-order item 3 (production/plans, IMPLEMENTATION_PLAN.md Phase 4,
-- IMPLEMENTATION_DETAILS.md 4.7). Registered as a Class-1 (pure query)
-- hook on find_proto: returns a unit_id (or a negative build-order
-- constant), matching C++'s int return. find_proto consumes RNG
-- (random(128), i.e. rand.map(0,128) -- see below), so the C++ seam
-- snapshots/restores it around the Lua call, same as mod_tech_ai.
--
-- Also ports every small helper unit_score/find_proto call that isn't
-- kept opaque (IMPLEMENTATION_DETAILS.md 4.7 lists exactly which and why):
-- need_police, unit_support_plan, check_retool, proto_extra_cost,
-- prototype_factor, base_can_riot, unit_is_better. mod_veh_avail/has_abil
-- stay host wrappers (engine eligibility/capability gates, not AI policy).
--
-- Translation notes (mirrors lua/ai/social.lua and lua/ai/war.lua):
-- * idiv for every C truncating division; bit.band/bnot/bxor for `&`/`~`/`^`.
-- * debug()-only logging (e.g. unit_is_better's name-pair log line) is not
--   replicated -- it has no effect on the returned value.
local port = {
    source = {
        unit_score = { file = "src/build.cpp", func = "unit_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        find_proto = { file = "src/build.cpp", func = "find_proto",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        select_colony = { file = "src/build.cpp", func = "select_colony",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        select_combat = { file = "src/build.cpp", func = "select_combat",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- plan.cpp, not build.cpp -- 4.9's production/plans third slice,
        -- unaffected by the 15418b28 rewrite (last touched by 6d37d82,
        -- "Add probe functions"), so the same pin point is still correct.
        facility_score = { file = "src/plan.cpp", func = "facility_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        governor_priorities = { file = "src/plan.cpp", func = "governor_priorities",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- select_build step 2 (IMPLEMENTATION_DETAILS.md 4.10.9, resumed
        -- after the Consolidation gate). push_item_score/push_item
        -- together reimplement push_item; tracked under that one name.
        has_retool = { file = "src/build.cpp", func = "has_retool",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        skip_facility = { file = "src/build.cpp", func = "skip_facility",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        push_item = { file = "src/build.cpp", func = "push_item",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- select_build step 3 sub-step 1 (IMPLEMENTATION_DETAILS.md
        -- 4.10.9/4.10.12, resumed after the Consolidation gate): the
        -- shared prologue, part of select_build itself (not a separately
        -- named C++ function -- same convention choice as push_item).
        select_build_prologue = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- select_build step 3 sub-step 2 (IMPLEMENTATION_DETAILS.md
        -- 4.10.9/4.10.13, resumed after the Consolidation gate):
        -- DefendUnit/CombatUnit's early-return decision, part of
        -- select_build itself (same convention as select_build_prologue).
        defend_unit_land_defense = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        defend_unit_explore_veh = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        combat_unit_early_return = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- select_build step 3 sub-step 3 (IMPLEMENTATION_DETAILS.md
        -- 4.10.9/4.10.14, resumed after the Consolidation gate): the
        -- build_order loop's per-item base score.
        build_order_item_score = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- select_build itself, unit-branch catalog (IMPLEMENTATION_
        -- DETAILS.md 4.10.27), part of select_build itself (same
        -- convention as build_order_item_score/defend_unit_*).
        colony_unit_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        crawler_unit_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        ferry_unit_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        sea_probe_unit_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        satellites_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        find_satellite = { file = "src/build.cpp", func = "find_satellite",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        prod_count = { file = "src/faction.cpp", func = "prod_count",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        satellite_count = { file = "src/plan.cpp", func = "satellite_count",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        satellite_goal_calc = { file = "src/plan.cpp", func = "satellite_goal",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        secret_project_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        find_project = { file = "src/build.cpp", func = "find_project",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        find_missile = { file = "src/build.cpp", func = "find_missile",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        faction_might = { file = "src/plan.cpp", func = "faction_might",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        has_pact = { file = "src/faction.cpp", func = "has_pact",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        redundant_project = { file = "src/build.cpp", func = "redundant_project",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        former_unit_branch = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- select_build itself, step 4 (IMPLEMENTATION_DETAILS.md 4.10):
        -- the real Class 2 hook, tying every branch above into the
        -- build_order[] loop.
        select_build = { file = "src/build.cpp", func = "select_build",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        -- Item 3 remainder, 2nd of three (IMPLEMENTATION_DETAILS.md 4.18).
        mod_base_hurry = { file = "src/build.cpp", func = "mod_base_hurry",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local faction = dofile("lua/api/faction.lua")
local tech = dofile("lua/api/tech.lua")
local base_api = dofile("lua/api/base.lua")
local game = dofile("lua/api/game.lua")
local rand = dofile("lua/api/rand.lua")
local cmath = dofile("lua/api/cmath.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local veh = dofile("lua/api/veh.lua")
local log = dofile("lua/api/log.lua")

local idiv = cmath.idiv
local imod = cmath.imod
local clamp = cmath.clamp
local max = math.max
local min = math.min
local E = types.enums
local C = types.counts

-- bool-to-int, used a lot by select_colony/select_combat's C original
-- (IMPLEMENTATION_DETAILS.md 4.8) -- more boolean arithmetic than
-- unit_score/find_proto needed.
local function b2n(b)
    return b and 1 or 0
end

-- plan.cpp:323
local function need_police(faction_id)
    local f = faction.get(faction_id)
    return f.SE_police > -2 and f.SE_police < 3 and not faction.has_project(E.FAC_TELEPATHIC_MATRIX, faction_id)
end

-- base.cpp:4274
local function unit_support_plan()
    local mode = funcs.modify_unit_support()
    if mode == 1 then
        return E.PLAN_SUPPLY
    elseif mode == 2 then
        return E.PLAN_PROBE
    end
    return E.PLAN_TERRAFORM
end

-- build.cpp:11-18 (static helper, used by both unit_score and,
-- eventually, select_build)
local function check_retool(base)
    local f = faction.get(base.faction_id)
    local rules = tech.rules()
    return base_api.plr_owner(base)
        and f.diff_level > E.DIFF_SPECIALIST
        and rules.retool_penalty_prod_change ~= 0
        and rules.retool_exemption ~= E.RETOOL_ALWAYS_FREE
        and bit.band(base.state_flags, E.BSTATE_PRODUCTION_DONE) == 0
        and base.minerals_accumulated > rules.retool_exemption
end

-- veh.cpp:2043-2059
local function prototype_factor(unit_id)
    local faction_id = idiv(unit_id, C.MaxProtoFactionNum)
    local m = faction.meta(faction_id)
    local f = faction.get(faction_id)
    if bit.band(m.rule_flags, E.RFLAG_FREEPROTO) ~= 0 or f.diff_level <= E.DIFF_SPECIALIST then
        return 0
    end
    local triad = tech.proto_triad(unit_id)
    local rules = tech.rules()
    if triad == E.TRIAD_SEA then
        return rules.extra_cost_prototype_sea
    elseif triad == E.TRIAD_AIR then
        return rules.extra_cost_prototype_air
    end
    return rules.extra_cost_prototype_land
end

-- build.cpp:34-38
local function proto_extra_cost(unit_id)
    if unit_id >= C.MaxProtoFactionNum and not tech.proto_is_prototyped(unit_id) then
        return prototype_factor(unit_id)
    end
    return 0
end

-- base.cpp:4842-4847
local function base_can_riot(base_id, allow_staple)
    local base = base_api.get(base_id)
    return (not allow_staple or base.nerve_staple_turns_left == 0)
        and not faction.has_project(E.FAC_TELEPATHIC_MATRIX, base.faction_id)
        and funcs.has_fac_built(E.FAC_PUNISHMENT_SPHERE, base_id) == 0
end

-- select_build itself, facility-branch catalog continued (IMPLEMENTATION_
-- DETAILS.md 4.10.25): FAC_NETWORK_NODE's own branch. faction.cpp:76-86
-- -- a plain BASE[]-count loop over already-exposed primitives, ported
-- directly rather than adding another opaque host wrapper for two lines
-- of arithmetic, same precedent as FAC_PSI_GATE's own base-scan (4.10.19).
local function facility_count(item_id, faction_id)
    local n = 0
    for i = 0, base_api.count() - 1 do
        local base = base_api.get(i)
        if base.faction_id == faction_id and funcs.has_fac_built(item_id, i) ~= 0 then
            n = n + 1
        end
    end
    return n
end

-- build.cpp:483-503 (debug()-only name log dropped, see module comment)
local function unit_is_better(unit_id1, unit_id2)
    local u1 = tech.proto(unit_id1)
    local u2 = tech.proto(unit_id2)
    local abls_old = u1.ability_flags
    local abls_new = u2.ability_flags
    local off1 = tech.proto_offense(unit_id1)
    return u1.cost >= u2.cost
        and off1 >= 0
        and off1 <= tech.proto_offense(unit_id2)
        and tech.proto_defense(unit_id1) <= tech.proto_defense(unit_id2)
        and (funcs.ignore_reactor_power() ~= 0 or u1.reactor_id <= u2.reactor_id)
        and tech.proto_speed(unit_id1) <= tech.proto_speed(unit_id2)
        and bit.band(bit.bxor(bit.band(abls_old, abls_new), abls_old), bit.bnot(E.ABL_SLOW)) == 0
        and bit.band(abls_old, E.ABL_ARTILLERY) == bit.band(abls_new, E.ABL_ARTILLERY)
        and (tech.proto_triad(unit_id2) ~= E.TRIAD_AIR or (u1.chassis_id == u2.chassis_id
            and bit.band(abls_old, E.ABL_AIR_SUPERIORITY) == bit.band(abls_new, E.ABL_AIR_SUPERIORITY)))
end

-- Ability score table (build.cpp:509-524).
local SPECIALS = {
    { "ABL_AAA", 4 }, { "ABL_AIR_SUPERIORITY", 2 }, { "ABL_ALGO_ENHANCEMENT", 5 },
    { "ABL_AMPHIBIOUS", -2 }, { "ABL_DROP_POD", 4 }, { "ABL_EMPATH", 2 },
    { "ABL_TRANCE", 3 }, { "ABL_SLOW", -4 }, { "ABL_TRAINED", 2 },
    { "ABL_COMM_JAMMER", 3 }, { "ABL_ANTIGRAV_STRUTS", 3 }, { "ABL_BLINK_DISPLACER", 3 },
    { "ABL_DEEP_PRESSURE_HULL", 2 }, { "ABL_SUPER_TERRAFORMER", 8 },
}

-- build.cpp:505-604
local function unit_score(base_id, unit_id, psi_score, psi_atk, psi_def, defend)
    -- defend may arrive as a raw 0/1 int (lua_ai_hook's int-args contract,
    -- or a plain call from find_proto below) -- Lua's `0` is truthy, so
    -- this must be normalized before use in any `if defend`/`defend and`
    -- expression, same trap avoided in lua/ai/social.lua's pop_boom.
    defend = not (defend == false or defend == 0)
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    local u = tech.proto(unit_id)
    local combat = u.plan <= E.PLAN_NAVAL_SUPERIORITY
    local atk_val = tech.proto_offense(unit_id)
    local def_val = tech.proto_defense(unit_id)

    if tech.proto_is_missile(unit_id) and tech.proto_is_planet_buster(unit_id) == 0 and atk_val > 0 then
        atk_val = idiv(atk_val + 7 * psi_atk, 8)
    end

    local v
    if defend then
        v = (atk_val >= 0 and 2 * atk_val or psi_atk + psi_score)
            + (def_val >= 0 and 16 * (def_val + (def_val > 1 and 1 or 0)) or 12 * psi_def + 16 * psi_score)
    else
        v = (atk_val >= 0 and 16 * (atk_val + (atk_val > 1 and 1 or 0)) or 12 * psi_atk + 16 * psi_score)
            + (def_val >= 0 and 2 * def_val or psi_def + psi_score)
    end

    if psi_score <= 0 and tech.proto_is_psi_unit(unit_id) then
        v = v + 8 * (psi_score - 2)
    end
    if combat and atk_val >= 0 then
        if atk_val == 0 then
            v = v - (defend and 100 or 1000)
        end
        if (defend and atk_val > def_val) or (not defend and atk_val < def_val) then
            v = v - 100
        end
    end

    local triad = tech.proto_triad(unit_id)
    if triad ~= E.TRIAD_AIR then
        v = v + (defend and (combat and 8 or 16) or 32) * tech.proto_speed(unit_id)
    else
        v = v + clamp(4 * tech.proto_speed(unit_id), 0, 48) + (tech.proto_range(unit_id) == 0 and 16 or 0)
        if tech.proto_is_missile(unit_id) then
            v = v + (bit.band(f.player_flags_ext, E.PFLAG_EXT_STRAT_LOTS_MISSILES) ~= 0 and 20 or 0)
            v = v - 4 * funcs.missile_units(base.faction_id)
        end
    end

    if bit.band(u.ability_flags, E.ABL_ARTILLERY) ~= 0 then
        local rules = tech.rules()
        if funcs.long_range_artillery() > 0 and rules.artillery_max_rng <= 4
        and not game.multiplayer_active() and triad == E.TRIAD_SEA and tech.proto_offense_value(unit_id) > 0 then
            v = v + (funcs.long_range_artillery() > 1 and 24 or 16)
        else
            v = v - 8
        end
        v = v + (bit.band(f.player_flags_ext, E.PFLAG_EXT_STRAT_LOTS_ARTILLERY) ~= 0 and 20 or 0)
    end
    if bit.band(u.ability_flags, E.ABL_POLICE_2X) ~= 0 and need_police(base.faction_id) then
        v = v + (tech.proto_speed(unit_id) > 1 and 16 or 32)
        v = v + 8 * min(4, base.specialist_adjust)
    end
    if bit.band(u.ability_flags, E.ABL_CLEAN_REACTOR) ~= 0 and u.plan <= unit_support_plan()
    and (f.SE_support_pending < 3 or base.mineral_consumption > 0) then
        v = v + 16
    end
    local rules = tech.rules()
    if unit_id == base.production_id_last
    and rules.retool_exemption >= E.RETOOL_FREE_PROJECT and check_retool(base) then
        v = v + 200
    end
    if proto_extra_cost(unit_id) > 0 then
        v = v + clamp(base.mineral_surplus - 4, 0, 32)
        v = v + 40 * (funcs.has_fac_built(E.FAC_SKUNKWORKS, base_id) ~= 0 and 1 or 0)
        if base.mineral_surplus >= funcs.median_limit(base.faction_id) then
            v = v + 40 * (atk_val > funcs.max_offense_value(base.faction_id) and 1 or 0)
            v = v + 40 * (def_val > funcs.max_defense_value(base.faction_id) and 1 or 0)
        end
    end
    for _, s in ipairs(SPECIALS) do
        if bit.band(u.ability_flags, E[s[1]]) ~= 0 then
            v = v + 8 * s[2]
        end
    end

    local mins = max(4, base.mineral_surplus)
    local turns = idiv(max(0, u.cost * 10 - base.minerals_accumulated) + mins - 1, mins)
    local score = v - idiv(turns * turns, 10) - turns * (tech.proto_is_colony(unit_id) and 6 or 3)
        * (max(2, 8 - idiv(game.turn(), 16)) + max(0, 2 - idiv(base.mineral_surplus, 4)))
    return score
end

-- build.cpp:610-670
local function find_proto(base_id, triad, mode, defend)
    -- lua_ai_hook passes bool args as a raw 0/1 int -- see unit_score's
    -- comment above for why this must be normalized before any boolean use.
    defend = not (defend == false or defend == 0)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local gov = base_api.gov_config(base)

    local psi_score = 0
    if bit.band(gov, E.GOV_MAY_PROD_NATIVE) ~= 0 then
        psi_score = funcs.psi_score(faction_id)
            + (funcs.has_fac_built(E.FAC_BROOD_PIT, base_id) ~= 0 and 1 or 0)
            + (funcs.has_fac_built(E.FAC_BIOLOGY_LAB, base_id) ~= 0 and 1 or 0)
            + (funcs.has_fac_built(E.FAC_CENTAURI_PRESERVE, base_id) ~= 0 and 1 or 0)
            + (funcs.has_fac_built(E.FAC_TEMPLE_OF_PLANET, base_id) ~= 0 and 1 or 0)
    end
    local prototypes = bit.band(gov, E.GOV_MAY_PROD_PROTOTYPE) ~= 0
        or funcs.has_fac_built(E.FAC_SKUNKWORKS, base_id) ~= 0
    local combat = (mode == E.WMODE_COMBAT)
    local pacifism = combat
        and base_can_riot(base_id, true)
        and base_api.se_police(base_id, E.SE_Pending) <= -3
        and base.drone_total + base.specialist_adjust >= base.talent_total

    local best_id = -E.FAC_STOCKPILE_ENERGY
    local best_val = -10000
    local psi_atk = 1
    local psi_def = 1
    local choices = {}

    for id = 0, C.MaxProtoNum - 1 do
        local u = tech.proto(id)
        if (id < C.MaxProtoFactionNum or idiv(id, C.MaxProtoFactionNum) == faction_id)
        and funcs.mod_veh_avail(id, faction_id, base_id) ~= 0 and tech.proto_is_planet_buster(id) == 0 then
            psi_atk = max(psi_atk, tech.proto_offense(id))
            psi_def = max(psi_def, tech.proto_defense(id))
            if bit.band(bit.lshift(1, tech.proto_triad(id)), triad) ~= 0 then
                local skip = false
                if not prototypes and proto_extra_cost(id) > 0 then
                    skip = true
                end
                if not skip and ((not combat and tech.weapon(u.weapon_id).mode ~= mode)
                or (combat and (tech.proto_offense_value(id) == 0 and (not defend or u.plan > E.PLAN_RECON)))
                or (tech.proto_is_psi_unit(id) and bit.band(gov, E.GOV_MAY_PROD_NATIVE) == 0)) then
                    skip = true
                end
                if not skip and combat and tech.proto_triad(id) == E.TRIAD_AIR then
                    local intercept = funcs.has_abil(id, E.ABL_AIR_SUPERIORITY) ~= 0
                    if (not intercept and pacifism)
                    or (not intercept and bit.band(gov, E.GOV_MAY_PROD_AIR_COMBAT) == 0)
                    or (intercept and bit.band(gov, E.GOV_MAY_PROD_AIR_DEFENSE) == 0) then
                        skip = true
                    end
                end
                if not skip then
                    choices[#choices + 1] = id
                end
            end
        end
    end

    for _, id in ipairs(choices) do
        local val = unit_score(base_id, id, psi_score, psi_atk, psi_def, defend)
        if best_id < 0 or unit_is_better(best_id, id) or rand.map(0, 128) > 64 + best_val - val then
            best_id = id
            best_val = val
        end
    end
    return best_id
end

-- engine_types.h:287-289's MFaction::is_aquatic() (rule_flags &
-- RFLAG_AQUATIC) -- distinct from the free is_alien(faction_id)-style
-- functions, same tier as war.lua's local is_alien helper (kept local
-- here too, not added to faction.lua's shared surface).
local function is_aquatic(faction_id)
    return bit.band(faction.meta(faction_id).rule_flags, E.RFLAG_AQUATIC) ~= 0
end

-- Production/plans port, second slice (porting-order item 3,
-- IMPLEMENTATION_DETAILS.md 4.8): build.cpp:691-753 (pre-seam line
-- numbers). Class 1, consumes RNG (random()), only ever called by
-- select_build (still C++) today -- see 4.8 for why the dual-run seam
-- still works despite no external caller.
local function select_colony(base_id, num_colony, build_ships)
    build_ships = not (build_ships == false or build_ships == 0)
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    local start = f.base_count < min(16, 2 + idiv(game.map_area_sq_root(), 4))
    local land = funcs.has_base_sites(base.x, base.y, base.faction_id, E.TRIAD_LAND) ~= 0
    local sea = funcs.has_base_sites(base.x, base.y, base.faction_id, E.TRIAD_SEA) ~= 0
    local extra_land = land and bit.band(f.player_flags_ext, E.PFLAG_EXT_STRAT_LOTS_COLONY_PODS) ~= 0
    local extra_sea = build_ships and sea and bit.band(f.player_flags_ext, E.PFLAG_EXT_STRAT_LOTS_SEA_BASES) ~= 0
    local aquatic = is_aquatic(base.faction_id)

    local limit
    if start or (rand.map(0, 4) == 0 and (land or (build_ships and sea))) then
        limit = 2
    else
        limit = 1
    end
    limit = limit + b2n((extra_land or extra_sea) and rand.map(0, 4) == 0)

    if funcs.expansion_autoscale() > 0 and f.base_count >= 4 and game.diff_level() <= E.DIFF_SPECIALIST then
        -- Both random() calls below must run in this exact order: the
        -- first is unconditional, the second only if diff_level >
        -- DIFF_CITIZEN, matching the C original's `!random(4) + (cond ?
        -- !random(4) : 0)` short-circuit exactly (RNG determinism).
        local term1 = b2n(rand.map(0, 4) == 0)
        local term2 = 0
        if game.diff_level() > E.DIFF_CITIZEN then
            term2 = b2n(rand.map(0, 4) == 0)
        end
        limit = min(limit, term1 + term2)
    end

    if num_colony >= limit then
        return -1
    end
    if funcs.is_ocean(base_id) ~= 0 then
        if funcs.ocean_colony_land_site(base_id, b2n(land)) ~= 0 then
            return find_proto(base_id, E.TRFLAG_LAND, E.WMODE_COLONY, true)
        end
        if sea then
            return find_proto(base_id, E.TRFLAG_SEA, E.WMODE_COLONY, true)
        end
    else
        local cheap = build_ships and funcs.best_reactor(base.faction_id) >= E.REC_FUSION
        if build_ships and sea and (not land or not start or cheap)
        and rand.map(0, 16) > 10 + 2 * (b2n(land) + b2n(start) - b2n(cheap)) then
            return find_proto(base_id, E.TRFLAG_SEA, E.WMODE_COLONY, true)
        end
        if land then
            return find_proto(base_id, E.TRFLAG_LAND, E.WMODE_COLONY, true)
        end
    end
    return -1
end

-- build.cpp:755-841 (pre-seam line numbers). Same Class 1 + RNG shape as
-- select_colony above.
local function select_combat(base_id, sea_base, build_ships)
    sea_base = not (sea_base == false or sea_base == 0)
    build_ships = not (build_ships == false or build_ships == 0)
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    local gov = base_api.gov_config(base)

    local w_air
    if 4 * funcs.air_combat_units(base.faction_id) < f.base_count then
        w_air = 2
    elseif bit.band(f.player_flags, E.PFLAG_EMPHASIZE_AIR_POWER) ~= 0 then
        w_air = 4
    else
        w_air = 5
    end
    local w_sea
    if 5 * funcs.transport_units(base.faction_id) < f.base_count + 5 then
        w_sea = 2
    elseif 3 * funcs.transport_units(base.faction_id) < f.base_count then
        w_sea = 5
    else
        w_sea = 8
    end
    local w_probes
    if funcs.probe_units(base.faction_id) * (funcs.modify_unit_support() < 2 and 2 or 4) < f.base_count then
        w_probes = 3
    else
        w_probes = 5
    end
    w_probes = w_probes + (bit.band(f.player_flags_ext, E.PFLAG_EXT_STRAT_LOTS_PROBE_TEAMS) ~= 0 and 0 or 1)

    local need_ships = (bit.band(f.player_flags, E.PFLAG_EMPHASIZE_SEA_POWER) ~= 0 and 4 or 6)
        * funcs.sea_combat_units(base.faction_id) < funcs.land_combat_units(base.faction_id)
    local need_land = bit.band(f.player_flags, E.PFLAG_EMPHASIZE_LAND_POWER) ~= 0
    local reserve = funcs.modify_unit_support() >= 2
        or base.mineral_surplus >= idiv(base.mineral_intake_2, 2)
    local probes = funcs.has_wmode(base.faction_id, E.WMODE_PROBE) ~= 0
        and bit.band(gov, E.GOV_MAY_PROD_PROBES) ~= 0
    local transports = funcs.has_wmode(base.faction_id, E.WMODE_TRANSPORT) ~= 0
        and bit.band(gov, E.GOV_MAY_PROD_TRANSPORT) ~= 0
    local land = bit.band(gov, bit.bor(E.GOV_MAY_PROD_LAND_COMBAT, E.GOV_MAY_PROD_LAND_DEFENSE)) ~= 0
    local sea = bit.band(gov, bit.bor(E.GOV_MAY_PROD_NAVAL_COMBAT, E.GOV_MAY_PROD_TRANSPORT)) ~= 0
    local air = bit.band(gov, bit.bor(E.GOV_MAY_PROD_AIR_COMBAT, E.GOV_MAY_PROD_AIR_DEFENSE)) ~= 0

    if probes and (not (land or sea or air) or rand.map(0, w_probes) == 0 or not reserve) then
        local triad = bit.bor(E.TRFLAG_LAND, E.TRFLAG_AIR)
        if build_ships then
            triad = bit.bor(E.TRFLAG_SEA, E.TRFLAG_AIR)
            if sea_base and funcs.contacted_factions(base.faction_id) ~= 0
            and funcs.check_probe(base_id, E.TRIAD_LAND) == 0
            and base.defend_range > 0 and base.defend_range < rand.map(0, 64) then
                triad = bit.bor(triad, E.TRFLAG_LAND)
            end
        end
        local choice = find_proto(base_id, triad, E.WMODE_PROBE, true)
        if choice >= 0 then
            return choice
        end
    end
    if air and (not (land or sea) or rand.map(0, w_air) == 0) then
        local choice = find_proto(base_id, E.TRFLAG_AIR, E.WMODE_COMBAT, false)
        if choice >= 0 then
            return choice
        end
    end
    if build_ships and sea then
        local min_dist = math.huge
        local sea_enemy = false
        for i = 0, base_api.count() - 1 do
            local b = base_api.get(i)
            if base.faction_id ~= b.faction_id and funcs.has_pact(base.faction_id, b.faction_id) == 0 then
                local dist = funcs.map_range(base.x, base.y, b.x, b.y)
                    * ((need_land and funcs.is_ocean(i) ~= 0) and 2 or 1)
                    * (funcs.at_war(base.faction_id, b.faction_id) ~= 0 and 1 or 4)
                if dist < min_dist then
                    sea_enemy = funcs.is_ocean(i) ~= 0
                    min_dist = dist
                end
            end
        end
        local threshold
        if sea_base then
            threshold = 3
        else
            threshold = 1 + b2n(need_ships or sea_enemy)
        end
        if not land or rand.map(0, 4) < threshold then
            local mode
            if not transports then
                mode = E.WMODE_COMBAT
            elseif bit.band(gov, E.GOV_MAY_PROD_NAVAL_COMBAT) == 0 then
                mode = E.WMODE_TRANSPORT
            elseif rand.map(0, w_sea) == 0 then
                mode = E.WMODE_TRANSPORT
            else
                mode = E.WMODE_COMBAT
            end
            local choice = find_proto(base_id, E.TRFLAG_SEA, mode, false)
            if choice >= 0 then
                return choice
            end
        end
    end
    local last_defend = sea_base or rand.map(0, 5) == 0
    return find_proto(base_id, E.TRFLAG_LAND, E.WMODE_COMBAT, last_defend)
end

-- select_build itself (porting-order item 3, final piece,
-- IMPLEMENTATION_DETAILS.md 4.10.9), step 1: standalone correctness check
-- for VEH's first-ever FFI exposure (4.10.1) + select_build's own
-- vehicle-count loop (build.cpp:913-955). NOT a real hook -- select_build
-- itself isn't ported yet (4.10 lists the remaining steps: push_item +
-- running-best tracker, the build_order scoring loop, then wiring the real
-- hook last). Called from a temporary seam in select_build (src/build.cpp)
-- purely so its counters can be diffed by hand against the C++
-- debug("select_build ...") line a few statements later in the original
-- (build.cpp:977-981), which already prints def/frm/prb/crw/pods/scouts
-- for the same base -- a mismatch is visible with no new comparison
-- machinery needed.
--
-- sea_base is passed in from C++ (rather than recomputed here) because it
-- depends on region_at(), not yet wrapped for Lua (deferred alongside
-- adjacent_region/allow_expand, see 4.10.5) -- everything else this
-- function needs (BASE, Faction, VEH, gov flags) is already exposed.
-- Extracted from vehicle_counts_check (step 1) so select_build_prologue
-- (step 3 sub-step 1, IMPLEMENTATION_DETAILS.md 4.10.12) can reuse this
-- already-verified loop (986/986 and 859/859 clean this session) instead
-- of duplicating it. Returns raw (pre-transform) counters -- callers
-- apply their own transforms (e.g. defenders' (x+2)/8), matching how the
-- C++ original only transforms `defenders` well after this loop ends.
local function count_vehicles(base_id, sea_base)
    sea_base = not (sea_base == false or sea_base == 0)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local gov = base_api.gov_config(base)
    local allow_supply = not sea_base and bit.band(gov, E.GOV_MAY_PROD_TERRAFORMERS) ~= 0

    local all_crawlers, near_formers, need_ferry = 0, 0, 0
    local transports, landprobes, seaprobes = 0, 0, 0
    local artifacts, defenders, formers, scouts, pods = 0, 0, 0, 0, 0

    for i = veh.count() - 1, 0, -1 do
        local v = veh.get(i)
        if v.faction_id == faction_id then
            if v.home_base_id == base_id then
                if veh.is_former(v) then
                    formers = formers + 1
                elseif veh.is_colony(v) then
                    pods = pods + 1
                elseif veh.is_probe(v) then
                    if veh.triad(v) == E.TRIAD_LAND then
                        landprobes = landprobes + 1
                    else
                        seaprobes = seaprobes + 1
                    end
                elseif veh.is_transport(v) then
                    transports = transports + 1
                elseif veh.is_supply(v) and v.order ~= E.ORDER_CONVOY then
                    allow_supply = false
                elseif veh.is_combat_unit(v) or veh.is_garrison_unit(v) then
                    scouts = scouts + 1
                end
            end
            local dist = funcs.map_range(base.x, base.y, v.x, v.y)
            if dist <= 1 then
                defenders = defenders + (dist < 1 and 2 or 1) * veh.eval_garrison(v)
            end
            if dist <= 1 and veh.is_former(v) and v.home_base_id ~= base_id then
                near_formers = near_formers + 1
            elseif dist <= 4 and veh.is_artifact(v) then
                artifacts = artifacts + 1
            elseif dist == 0 and veh.is_transport(v) then
                transports = transports + 1
            elseif veh.is_supply(v) then
                all_crawlers = all_crawlers + 1
            end
            if sea_base and base.x == v.x and base.y == v.y and veh.triad(v) == E.TRIAD_LAND then
                if veh.is_colony(v) or veh.is_former(v) or veh.is_supply(v) then
                    need_ferry = need_ferry + 1
                end
            end
        end
    end

    return {
        defenders = defenders, formers = formers, landprobes = landprobes,
        seaprobes = seaprobes, all_crawlers = all_crawlers, pods = pods,
        scouts = scouts, transports = transports, near_formers = near_formers,
        artifacts = artifacts, need_ferry = need_ferry, allow_supply = allow_supply,
    }
end

-- select_build itself (porting-order item 3, final piece), step 2
-- (IMPLEMENTATION_DETAILS.md 4.10.5/4.10.9, resumed after the
-- Consolidation gate): push_item (build.cpp:816-836) + its two small
-- dependents. mod_base_making/
-- skip_gov_facility_bit stay opaque host wrappers (genuine engine
-- mechanics, not AI policy, same bucket as mod_veh_avail/has_abil).
local function has_retool(base_id, item_id, retool)
    return retool ~= -1 and retool ~= 0
        and retool ~= funcs.mod_base_making(item_id, base_id)
end

local function skip_facility(base_id, item_id)
    local base = base_api.get(base_id)
    return base_api.plr_owner(base) and item_id >= 1 and item_id <= 64
        and funcs.skip_gov_facility_bit(item_id) ~= 0
end

-- Pure scoring math (build.cpp:816-833), split out from push_item so the
-- temporary diagnostic hook below can reuse it without needing a tracker.
local function push_item_score(base_id, item_id, retool, score, modifier)
    local base = base_api.get(base_id)
    if item_id >= 0 then
        score = score - 2 * tech.proto(item_id).cost
    elseif item_id >= -E.FAC_ORBITAL_DEFENSE_POD then
        local p = tech.facility(-item_id)
        local turns = idiv(max(0, 10 * p.cost - base.minerals_accumulated),
            max(2, base.mineral_surplus))
        score = score - idiv(turns * turns, 4)
        score = score - 2 * p.cost
        score = score - 8 * p.maint
    end
    if modifier > 0 then
        score = score + 20 * modifier
    end
    if has_retool(base_id, item_id, retool) then
        score = score - (retool <= -E.SP_ID_First and 800 or 400)
    end
    return score
end

-- Running-best tracker (IMPLEMENTATION_DETAILS.md 4.10.6) -- replaces
-- C++'s score_max_queue_t entirely: select_build only ever calls
-- .top()/.size() once, at the very end, never .pop()/iterates, so no
-- heap data structure needs porting. Tie-break matches SItem::operator<
-- exactly (plan.h:9-12): higher score wins; equal score, higher item_id
-- wins.
local function new_build_tracker()
    return { item_id = nil, score = nil }
end

local function push_item(tracker, base_id, item_id, retool, score, modifier)
    local final_score = push_item_score(base_id, item_id, retool, score, modifier)
    if tracker.score == nil or final_score > tracker.score
        or (final_score == tracker.score and item_id > tracker.item_id) then
        tracker.item_id, tracker.score = item_id, final_score
    end
    return final_score
end

-- Production/plans port, third slice (porting-order item 3,
-- IMPLEMENTATION_DETAILS.md 4.9): plan.cpp:8-13/15-31. WItem is a plain
-- table here ({AI_growth=.., AI_tech=.., AI_wealth=.., AI_power=..,
-- AI_fight=..}), not an FFI struct: lua/ai/ never touches ffi, and
-- there's no engine memory backing a WItem to justify one -- it's a
-- short-lived scoring accumulator in the C++ original too.
local function facility_score(item_id, wgov)
    local p = tech.facility(item_id)
    return wgov.AI_fight * p.AI_fight
        + wgov.AI_growth * p.AI_growth + wgov.AI_power * p.AI_power
        + wgov.AI_tech * p.AI_tech + wgov.AI_wealth * p.AI_wealth
end

local function governor_priorities(base_id)
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    local gov = base.governor_flags
    local wgov = {}
    if faction.is_human(base.faction_id) then
        wgov.AI_growth = bit.band(gov, E.GOV_PRIORITY_EXPLORE) ~= 0 and 4 or 1
        wgov.AI_tech = bit.band(gov, E.GOV_PRIORITY_DISCOVER) ~= 0 and 4 or 1
        wgov.AI_wealth = bit.band(gov, E.GOV_PRIORITY_BUILD) ~= 0 and 4 or 1
        wgov.AI_power = bit.band(gov, E.GOV_PRIORITY_CONQUER) ~= 0 and 4 or 1
        wgov.AI_fight = clamp((idiv(base.defend_goal, 2) - 1) * 2, -2, 2)
    else
        wgov.AI_growth = f.AI_growth ~= 0 and 4 or 1
        wgov.AI_tech = f.AI_tech ~= 0 and 4 or 1
        wgov.AI_wealth = f.AI_wealth ~= 0 and 4 or 1
        wgov.AI_power = f.AI_power ~= 0 and 4 or 1
        wgov.AI_fight = clamp(2 * f.AI_fight, -2, 2)
    end
    return wgov
end

-- Consolidation gate item b (IMPLEMENTATION_PLAN.md, typed hook-descriptor
-- refactor): facility_score/governor_priorities above don't fit the C
-- side's flat-int-args/flat-int-result contract directly -- WItem is a
-- named-field table on both sides here, and facility_score's second
-- argument is a whole WItem, not a scalar. These are thin marshalling
-- adapters at that specific boundary, same precedent as
-- lua/api/faction.lua's models_to_cdata: the real logic stays in the
-- named-table functions above, unchanged, so any future internal Lua
-- caller (once select_build is ported and starts calling these directly)
-- gets the convenient interface, not this one.
--
-- Field order matches WItem's C++ declaration exactly (src/engine.h):
-- AI_growth, AI_tech, AI_wealth, AI_power, AI_fight. src/plan.cpp's hook
-- seams flatten/unflatten in this same order.
local function facility_score_hook(item_id, ai_growth, ai_tech, ai_wealth, ai_power, ai_fight)
    return facility_score(item_id, {
        AI_growth = ai_growth, AI_tech = ai_tech, AI_wealth = ai_wealth,
        AI_power = ai_power, AI_fight = ai_fight,
    })
end

local function governor_priorities_hook(base_id)
    local wgov = governor_priorities(base_id)
    return { wgov.AI_growth, wgov.AI_tech, wgov.AI_wealth, wgov.AI_power, wgov.AI_fight }
end

-- select_build itself, step 3 sub-step 1 (IMPLEMENTATION_DETAILS.md
-- 4.10.9/4.10.12, resumed after the Consolidation gate): the shared
-- prologue through Wbase/Wthreat (build.cpp:847-965), everything every
-- later branch (9 special unit types + ~35 facility branches, none
-- ported yet) depends on. Originally deliberately skipped retool/
-- project_change/allow_units/allow_supply/allow_ships/drone_riots/
-- drones -- none of those fed Wbase/Wthreat or the existing debug() line
-- this was verified against. retool/allow_ships landed with later
-- sub-steps as branches started needing them; allow_units is threaded
-- through as a hook argument instead (4.10.16, RNG-sensitivity reasons);
-- drone_riots/drones land here (4.10.18) for the shared psych-facility
-- branch. project_change/allow_supply remain genuinely unneeded so far.
-- Wbase/Wthreat is genuine C float arithmetic (4.10.7): plain Lua `/`,
-- not idiv. Placed after governor_priorities (calls it) -- Lua locals
-- aren't hoisted, an earlier placement here errored live ("attempt to
-- call global 'governor_priorities' (a nil value)") since it fell
-- through to a nonexistent global instead of the not-yet-declared local.
local function select_build_prologue(base_id)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local f = faction.get(faction_id)
    local gov = base_api.gov_config(base)
    local minerals = base.mineral_surplus + idiv(base.minerals_accumulated, 10)
    local reserve = max(2, idiv(base.mineral_intake_2, 2))
    local base_reg = funcs.region_at(base.x, base.y)
    local defend_range = base.defend_range > 0 and base.defend_range or idiv(C.MaxEnemyRange, 2)
    local sea_base = base_reg >= C.MaxRegionLandNum
    local allow_pods = funcs.allow_expand(faction_id)
        and (base.pop_size > 1 or base.nutrient_surplus > 0)

    -- retool (build.cpp:852-861): plans_upkeep(faction_id) is skipped --
    -- a mutating orchestration call that already runs for real in C++
    -- regardless of this comparison (4.10.8: no pure-query shape, out of
    -- scope). check_retool is already ported; mod_base_making already
    -- wrapped (step 2).
    local prev_id = base.production_id_last
    local retool = 0
    if base_api.plr_owner(base) then
        if check_retool(base) and (prev_id >= 0
            or (prev_id >= -E.Fac_ID_Last and funcs.has_fac_built(-prev_id, base_id) == 0)
            or (prev_id < -E.Fac_ID_Last and prev_id ~= -E.FAC_STOCKPILE_ENERGY)) then
            retool = funcs.mod_base_making(prev_id, base_id)
        end
    end

    -- allow_ships (build.cpp:874-875).
    local allow_ships = funcs.has_ships(faction_id)
        and funcs.adjacent_region(base.x, base.y, -1, game.map_area_sq_root(), E.TRIAD_SEA)

    -- drone_riots/drones (build.cpp:877-878): select_build itself,
    -- facility-branch catalog continued (IMPLEMENTATION_DETAILS.md
    -- 4.10.18).
    local drone_riots = base_api.drone_riots(base) or base_api.drone_riots_active(base)
    local drones = base.drone_total + base.specialist_adjust

    local c = count_vehicles(base_id, sea_base)
    local wgov = governor_priorities(base_id)
    local defenders = idiv(c.defenders + 2, 8)

    -- select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
    -- 4.10.27): need_ferry/allow_supply's own post-loop refinement
    -- (build.cpp:948-950), applied to count_vehicles' raw loop-
    -- accumulated values -- a real gap found while wiring FerryUnit/
    -- CrawlerUnit, not present until now: `count_vehicles`'s own return
    -- table only ever held the *unrefined* values (right for
    -- `vehicle_counts_check`'s diagnostic comparison, which runs before
    -- this refinement in the C++ source too, build.cpp:945 vs 948-950),
    -- and nothing consumed the refined values until these two branches,
    -- so the gap was invisible until now. Kept here, not inside
    -- `count_vehicles` itself, to avoid changing what
    -- `vehicle_counts_check` verifies.
    local need_ferry = c.need_ferry ~= 0 and c.transports == 0
        and funcs.adjacent_region(base.x, base.y, faction_id, 16, E.TRIAD_LAND)
    local allow_supply = c.allow_supply
        and c.all_crawlers < min(f.base_count, idiv(game.map_area_tiles(), 20))

    -- Wenergy (build.cpp:1044-1045): select_build step 3 sub-step 3
    -- (IMPLEMENTATION_DETAILS.md 4.10.9/4.10.14, resumed after the
    -- Consolidation gate).
    local wenergy = (funcs.has_fac_built(E.FAC_PUNISHMENT_SPHERE, base_id) ~= 0 and 1 or 2)
        * (base.energy_surplus >= max(funcs.energy_limit(faction_id), 2 * base.energy_inefficiency)
            and 2 or 1)

    local project_limit = funcs.project_limit(faction_id)
    local enemy_mil_factor = funcs.enemy_mil_factor(faction_id)
    local enemy_base_range = funcs.enemy_base_range(faction_id)
    local enemy_bases = funcs.enemy_bases(faction_id)
    local main_region = funcs.main_region(faction_id)
    local target_land_region = funcs.target_land_region(faction_id)

    local Wbase = clamp(1.0 * minerals / project_limit, 0.4, 1.0)
        * ((defend_range > 0 and defend_range < 8) and 4.0 or 1.0)
        * clamp((defend_range < C.MaxEnemyRange and 0.1 or 0.05) * f.base_count, 0.2, 1.0)
        * max(0.05, 2.0 * enemy_mil_factor / (enemy_base_range * 0.1 + 0.1)
            + min(1.0, 1.5 * f.base_count / max(16, game.map_area_sq_root()))
            + 0.8 * enemy_bases + 0.2 * wgov.AI_fight)

    if base_api.plr_owner(base) then
        Wbase = Wbase * (bit.band(gov, E.GOV_PRIORITY_CONQUER) ~= 0 and 4 or 1)
    else
        Wbase = Wbase * ((base_reg ~= main_region and base_reg == target_land_region) and 4 or 1)
    end
    local Wthreat = 1.0 - (1.0 / (1.0 + Wbase))

    return {
        defenders = defenders, formers = c.formers, landprobes = c.landprobes,
        seaprobes = c.seaprobes, all_crawlers = c.all_crawlers, pods = c.pods,
        scouts = c.scouts, allow_pods = allow_pods, minerals = minerals,
        reserve = reserve, project_limit = project_limit,
        enemy_mil_factor = enemy_mil_factor, wthreat = Wthreat,
        sea_base = sea_base, retool = retool, allow_ships = allow_ships,
        gov = gov, wgov = wgov, wenergy = wenergy, defend_range = defend_range,
        drone_riots = drone_riots, drones = drones, base_reg = base_reg,
        artifacts = c.artifacts, allow_supply = allow_supply,
        need_ferry = need_ferry, near_formers = c.near_formers,
    }
end

-- select_build itself, step 3 sub-step 2 (IMPLEMENTATION_DETAILS.md
-- 4.10.9/4.10.13, resumed after the Consolidation gate): DefendUnit's
-- two return sites and CombatUnit's early-return check (build.cpp,
-- inside the build_order loop). Each is a real Class 1/2 shadow hook --
-- both consume RNG (random(8)/random(256)) with no existing debug line to diff
-- this needs lua_ai_shadow_call's snapshot/restore, same as
-- find_proto/mod_tech_ai. Returns the chosen unit_id, or -1 for "no
-- decision" (matching find_proto's own negative-sentinel convention).
-- reuses find_proto/select_combat/has_retool -- already ported and
-- shadow-verified with zero divergences over 3 real games -- so this is
-- genuinely just the gating conditions around them. The outer `t ==
-- DefendUnit/CombatUnit && gov & GOV_ALLOW_COMBAT` gate is guaranteed by
-- the C++ call site's own placement, but re-checked here too so each
-- function is correct standalone, not just in context.
local function defend_unit_land_defense(base_id)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_ALLOW_COMBAT) == 0 then
        return -1
    end
    if bit.band(r.gov, E.GOV_MAY_PROD_LAND_DEFENSE) ~= 0
        and r.minerals > 0 and r.defenders < 1 then
        local choice = find_proto(base_id, E.TRFLAG_LAND, E.WMODE_COMBAT, true)
        if choice >= 0 then
            return choice
        end
    end
    return -1
end

-- Evaluation order matters here, not just the final boolean: C++'s
-- short-circuit `&&` draws random(8) only after the first three
-- conditions hold, before need_scouts/find_proto -- Lua's `and` short-
-- circuits identically, so writing the terms in the same left-to-right
-- order (not pre-computing booleans) reproduces the same RNG draw
-- sequence find_proto's own internal draws then continue from.
local function defend_unit_explore_veh(base_id)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_ALLOW_COMBAT) == 0 then
        return -1
    end
    if bit.band(r.gov, E.GOV_MAY_PROD_EXPLORE_VEH) ~= 0
        and (r.pods > 0 or r.formers > 0 or r.minerals >= r.reserve + 2)
        and r.minerals >= r.reserve and r.scouts < 4 and rand.map(0, 8) == 0
        and funcs.need_scouts(base_id, r.sea_base and E.TRIAD_SEA or E.TRIAD_LAND) then
        local choice = find_proto(base_id,
            r.sea_base and E.TRFLAG_SEA or E.TRFLAG_LAND, E.WMODE_COMBAT, not r.sea_base)
        if choice >= 0 and not has_retool(base_id, choice, r.retool) then
            return choice
        end
    end
    return -1
end

-- (int)(256 * Wthreat) is a float-to-int cast, not C integer division --
-- math.floor, not idiv (idiv is specifically the int/int-truncation
-- case). Wthreat is provably non-negative given Wbase's clamps (3.1), so
-- floor matches C's truncation here.
local function combat_unit_early_return(base_id)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_ALLOW_COMBAT) == 0 or r.minerals < r.reserve then
        return -1
    end
    local choice = select_combat(base_id, r.sea_base, r.allow_ships)
    if choice >= 0 then
        if rand.map(0, 256) < math.floor(256 * r.wthreat)
            and not has_retool(base_id, choice, r.retool) then
            return choice
        end
    end
    return -1
end

-- select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
-- 4.10.27): find_satellite's own dependency chain (Satellites branch),
-- ported directly rather than as opaque wrappers -- all three are plain
-- BASE[]/Faction reads with no engine-mechanics content beyond what's
-- already exposed, same "cheap enough once actually read" call as
-- facility_count (4.10.25).
local function prod_count(item_id, faction_id, base_skip_id)
    local n = 0
    for i = 0, base_api.count() - 1 do
        local base = base_api.get(i)
        if base.faction_id == faction_id and base_api.item(base) == item_id and i ~= base_skip_id then
            n = n + 1
        end
    end
    return n
end

-- plan.cpp:409-419.
local function satellite_count(faction_id, item_id)
    local f = faction.get(faction_id)
    if item_id == E.FAC_SKY_HYDRO_LAB then
        return f.satellites_nutrient
    elseif item_id == E.FAC_ORBITAL_POWER_TRANS then
        return f.satellites_energy
    elseif item_id == E.FAC_NESSUS_MINING_STATION then
        return f.satellites_mineral
    else
        return f.satellites_ODP
    end
end

-- plan.cpp:421-446. Named _calc (not satellite_goal) to avoid colliding
-- with the AIPlans field of the same name (funcs.satellite_goal_setting
-- reads that field; this function *consumes* it as an input).
local function satellite_goal_calc(faction_id, item_id)
    local f = faction.get(faction_id)
    local goal = funcs.satellite_goal_setting(faction_id)
    if item_id == E.FAC_ORBITAL_DEFENSE_POD then
        local nukes = 0
        for i = 1, C.MaxPlayerNum - 1 do
            if faction_id ~= i and funcs.is_alive(i) ~= 0 and funcs.at_war(faction_id, i) ~= 0 then
                nukes = max(nukes, faction.get(i).planet_busters)
            end
        end
        if funcs.enemy_odp(faction_id) > 0 or funcs.enemy_sat(faction_id) > 0 or nukes > 2 then
            goal = clamp(idiv(goal, 4), 0, 4) + clamp(idiv(f.base_count, 8) + idiv(nukes, 2), 2, 12)
        else
            goal = clamp(idiv(goal, 4), 0, 4) + clamp(idiv(f.base_count, 8), 2, 4)
        end
    elseif f.base_count <= 5 then
        goal = idiv(goal, 2)
    end
    if f.base_count <= 10 then
        goal = idiv(goal, 2)
    end
    return clamp(goal, 0, funcs.max_satellites())
end

-- build.cpp:286-330. Returns a unit_id/-facility_id choice, or
-- C.MaxProtoNum (GOV_NONE's actual value, build.cpp:4) for "no
-- candidate" -- matching the C++ sentinel exactly, not a Lua-only stand-in,
-- since this return value is compared directly against GOV_NONE by the
-- Satellites branch below (`~= GOV_NONE`), not just used as a boolean.
local SATELLITE_ITEMS = {
    E.FAC_ORBITAL_DEFENSE_POD, E.FAC_NESSUS_MINING_STATION,
    E.FAC_ORBITAL_POWER_TRANS, E.FAC_SKY_HYDRO_LAB,
}

local function find_satellite(base_id)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local has_complex = funcs.has_facility(E.FAC_AEROSPACE_COMPLEX, base_id) ~= 0
        or faction.has_project(E.FAC_SPACE_ELEVATOR, faction_id)
    local build_complex = not has_complex and funcs.can_build(base_id, E.FAC_AEROSPACE_COMPLEX)
        and not skip_facility(base_id, E.FAC_AEROSPACE_COMPLEX)
    if not has_complex and bit.band(idiv(base_id + game.turn(), 8), 1) ~= 0 then
        return C.MaxProtoNum
    end
    if not has_complex and not build_complex then
        return C.MaxProtoNum
    end
    local f = faction.get(faction_id)
    local defense_only = clamp(funcs.enemy_odp(faction_id) - f.satellites_ODP + 7, 0, 14) > rand.map(0, 16)
    for _, item_id in ipairs(SATELLITE_ITEMS) do
        if funcs.has_tech(tech.facility(item_id).preq_tech, faction_id) ~= 0
            and not (item_id ~= E.FAC_ORBITAL_DEFENSE_POD and defense_only) then
            local prod_num = prod_count(-item_id, faction_id, base_id)
            local built_num = satellite_count(faction_id, item_id)
            local goal_num = satellite_goal_calc(faction_id, item_id)
            if built_num + prod_num < goal_num then
                if not has_complex and build_complex then
                    return -E.FAC_AEROSPACE_COMPLEX
                end
                if has_complex then
                    return -item_id
                end
            end
        end
    end
    return C.MaxProtoNum
end

-- select_build itself, unit-branch catalog continued (IMPLEMENTATION_
-- DETAILS.md 4.10.28): find_project's own dependency chain (SecretProject
-- branch). find_missile reuses the already-ported unit_score (4.7)
-- verbatim -- the same function build.cpp's own find_missile calls.
local function find_missile(base_id)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local best_id = -1
    local best_val = -math.huge
    for unit_id = 0, C.MaxProtoNum - 1 do
        if (unit_id < C.MaxProtoFactionNum or idiv(unit_id, C.MaxProtoFactionNum) == faction_id)
            and funcs.mod_veh_avail(unit_id, faction_id, -1) ~= 0
            and tech.proto_is_planet_buster(unit_id) ~= 0 then
            local val = unit_score(base_id, unit_id, 0, 1, 1, false)
            if val > best_val then
                best_id = unit_id
                best_val = val
            end
        end
    end
    return best_id
end

-- plan.cpp:365-367.
local function faction_might(faction_id)
    return funcs.mil_strength(faction_id) + 8 * faction.get(faction_id).pop_total
end

-- faction.cpp:158-161.
local function has_pact(faction_id_1, faction_id_2)
    return faction_id_1 >= 0 and faction_id_2 >= 0
        and bit.band(faction.get(faction_id_1).diplo_status[faction_id_2], E.DIPLO_PACT) ~= 0
end

-- build.cpp:252-283.
local function redundant_project(faction_id, item_id)
    local f = faction.get(faction_id)
    if item_id == E.FAC_PLANETARY_DATALINKS then
        local n = 0
        for i = 0, C.MaxPlayerNum - 1 do
            if faction.get(i).base_count > 0 then
                n = n + 1
            end
        end
        return n < 4
    end
    if item_id == E.FAC_CITIZENS_DEFENSE_FORCE then
        return tech.facility(E.FAC_PERIMETER_DEFENSE).maint == 0
            and facility_count(E.FAC_PERIMETER_DEFENSE, faction_id) > idiv(f.base_count, 2) + 2
    end
    if item_id == E.FAC_MARITIME_CONTROL_CENTER then
        local n = 0
        for i = veh.count() - 1, 0, -1 do
            local v = veh.get(i)
            if v.faction_id == faction_id and veh.triad(v) == E.TRIAD_SEA then
                n = n + 1
            end
        end
        return n < 8 and n < idiv(f.base_count, 3)
    end
    if item_id == E.FAC_HUNTER_SEEKER_ALGORITHM then
        return f.SE_probe >= 3
    end
    if item_id == E.FAC_LIVING_REFINERY then
        return f.SE_support >= 3
    end
    return false
end

-- build.cpp:351-463. Takes wgov (the same WItem-shaped plain table
-- facility_score/governor_priorities already use) rather than
-- recomputing it -- select_build already has one per base via
-- governor_priorities, matching the C++ signature exactly (`WItem&
-- Wgov`, passed in, not rebuilt).
local function find_project(base_id, wgov)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local f = faction.get(faction_id)
    local gov = base_api.gov_config(base)
    local bases = f.base_count
    local projs, nukes, works, diplo = 0, 0, 0, 0
    local unit_id = -1
    if bit.band(gov, E.GOV_MAY_PROD_AIR_COMBAT) ~= 0 then
        unit_id = find_missile(base_id)
    end
    local nuke_limit, nuke_score = 0, 0
    local built_nukes, enemy_nukes = 0, 0
    local defense = false

    if unit_id >= 0 and bases >= 8 then
        for i = veh.count() - 1, 0, -1 do
            local v = veh.get(i)
            if veh.is_planet_buster(v) ~= 0 then
                if faction_id == v.faction_id then
                    built_nukes = built_nukes + 1
                elseif funcs.at_war(faction_id, v.faction_id) ~= 0 then
                    enemy_nukes = enemy_nukes + 1
                end
            end
        end
        for i = 1, C.MaxPlayerNum - 1 do
            if faction_id ~= i and funcs.is_alive(i) ~= 0 and not has_pact(faction_id, i) then
                -- f->diplo_status[i]: the CURRENT faction's own array,
                -- indexed by the OTHER faction -- not the other way
                -- around (double-checked against build.cpp:381, not
                -- assumed from the has_pact args' order above).
                diplo = bit.bor(diplo, f.diplo_status[i])
                if 4 * faction_might(i) > faction_might(faction_id)
                    and funcs.has_tech(tech.facility(E.FAC_ORBITAL_DEFENSE_POD).preq_tech, i) ~= 0 then
                    defense = true
                end
            end
        end
        local atrocity = not funcs.un_charter() or bit.band(diplo, E.DIPLO_MAJOR_ATROCITY_VICTIM) ~= 0
        nuke_score = (atrocity and (defense and 4 or 8) or (f.AI_fight > 0 and 0 or -2))
            + 2 * f.AI_power + 2 * f.AI_fight
            + (bit.band(f.player_flags, E.PFLAG_COMMIT_ATROCITIES_WANTONLY) ~= 0 and 2 or 0)
            + (funcs.defense_modifier(faction_id) > 2 and 2 or 0)
            + clamp(enemy_nukes - f.satellites_ODP, -4, 4)
            + (bit.band(diplo, E.DIPLO_MAJOR_ATROCITY_VICTIM) ~= 0 and 4 or 0)
            + (bit.band(diplo, E.DIPLO_ATROCITY_VICTIM) ~= 0 and 4 or 0)
            + (bit.band(diplo, E.DIPLO_WANT_REVENGE) ~= 0 and 4 or 0)
            + min(4, idiv(base.mineral_surplus, 20))
        if nuke_score > 5 then
            nuke_limit = clamp(clamp(b2n(f.AI_fight > 0) + idiv(nuke_score, 8) + idiv(bases, 20), 1, 3)
                + ((defense or not atrocity) and 0 or idiv(bases, 10)) - built_nukes, 0, 10)
        end
    end

    for i = 0, base_api.count() - 1 do
        local b = base_api.get(i)
        if b.faction_id == faction_id and base_id ~= i then
            local t = base_api.item(b)
            if t <= -E.SP_ID_First or t == -E.FAC_SUBSPACE_GENERATOR then
                projs = projs + 1
            elseif t == -E.FAC_SKUNKWORKS then
                works = works + 1
            elseif t >= 0 and tech.proto_is_planet_buster(t) ~= 0 then
                nukes = nukes + 1
            end
        end
    end
    if unit_id >= 0 and nukes < nuke_limit then
        local extra_cost = proto_extra_cost(unit_id)
        local has_works = funcs.has_fac_built(E.FAC_SKUNKWORKS, base_id) ~= 0
        if rand.map(0, nuke_score > 10 and 2 or 4) == 0
            or (nukes == 0 and extra_cost == 0) or (has_works and extra_cost ~= 0) then
            if bit.band(gov, E.GOV_MAY_PROD_PROTOTYPE) ~= 0 or has_works or extra_cost == 0 then
                if extra_cost >= 50 and bit.band(gov, E.GOV_MAY_PROD_FACILITIES) ~= 0
                    and funcs.can_build(base_id, E.FAC_SKUNKWORKS) and works < 2
                    and not skip_facility(base_id, E.FAC_SKUNKWORKS) then
                    return -E.FAC_SKUNKWORKS
                end
                if has_works or works == 0 or extra_cost == 0 then
                    return unit_id
                end
            end
        end
    end
    local similar_limit = min(4, idiv(base.minerals_accumulated, 50))
    if projs + b2n(nukes > 0) < min(3 + b2n(nuke_limit > 0) + similar_limit, idiv(bases, 4)) then
        if funcs.can_build(base_id, E.FAC_SUBSPACE_GENERATOR)
            and not skip_facility(base_id, E.FAC_SUBSPACE_GENERATOR) then
            return -E.FAC_SUBSPACE_GENERATOR
        end
        local best_value = -math.huge
        local choice = C.MaxProtoNum
        local retool = check_retool(base)
        for i = E.SP_ID_First, E.SP_ID_Last do
            if funcs.can_build(base_id, i) and prod_count(-i, faction_id, base_id) <= similar_limit
                and (similar_limit > 0 or not redundant_project(faction_id, i)) then
                local value = facility_score(i, wgov)
                if retool then
                    value = value + (base.production_id_last == -i and 10 or 0)
                end
                if value > best_value then
                    choice = -i
                    best_value = value
                end
            end
        end
        if projs > 0 or best_value > 3 then
            return choice
        end
    end
    return C.MaxProtoNum
end

-- select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
-- 4.10.27): ColonyUnit/CrawlerUnit/FerryUnit/SeaProbeUnit (build.cpp:
-- 1177-1210, plus ColonyUnit at 1202-1210). Unlike DefendUnit/CombatUnit
-- (which `return choice` and end select_build outright), these push a
-- *candidate* onto the priority queue and keep evaluating later
-- build_order items, so each hook returns {choice, score} (out_count=2)
-- rather than a single value -- `score` is the shared per-item base
-- value (`random(32)` + Wgov contributions, build.cpp:1064-1067)
-- **threaded through as a hook argument, not re-derived**: it's already
-- computed once per loop iteration in C++ by the time any of these
-- branches runs, so recomputing it here would double-draw rand.map(0,32)
-- for no reason (same "don't re-derive an already-computed, order-
-- sensitive value" principle as `allow_units`, 4.10.16 -- though here
-- the concern is a redundant draw, not a divergence risk, since nothing
-- else consumes RNG between C++'s own draw and this hook's snapshot).
-- {-1, 0} is the shared "no candidate" sentinel; the C++ seam only calls
-- lua_ai_shadow_check on its own success path (same accepted trade-off
-- DefendUnit/CombatUnit already use -- "neither condition holds" isn't
-- compared), so the sentinel's exact shape never actually gets diffed.
local function colony_unit_branch(base_id, score)
    local r = select_build_prologue(base_id)
    if not (r.allow_pods and r.pods < 2 and bit.band(r.gov, E.GOV_MAY_PROD_COLONY_POD) ~= 0) then
        return { -1, 0 }
    end
    local choice = select_colony(base_id, r.pods, r.allow_ships)
    if choice < 0 then
        return { -1, 0 }
    end
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    score = score + clamp(2 * game.map_area_sq_root() - f.base_count, 0, 80)
    score = score + clamp(f.SE_effic_pending + 4, 0, 4)
        * (r.pods > 0 and 1 or 2) * max(0, 16 - f.base_count)
    return { choice, score }
end

local function crawler_unit_branch(base_id, score)
    local r = select_build_prologue(base_id)
    local base = base_api.get(base_id)
    if not (r.allow_supply and funcs.has_wmode(base.faction_id, E.WMODE_SUPPLY) ~= 0) then
        return { -1, 0 }
    end
    local choice = find_proto(base_id, E.TRFLAG_LAND, E.WMODE_SUPPLY, true)
    if choice < 0 then
        return { -1, 0 }
    end
    local f = faction.get(base.faction_id)
    score = score + max(0, 40 - base.mineral_surplus - base.nutrient_surplus)
    score = score + (r.all_crawlers < 4 + idiv(f.base_count, 4) and 40 or 0)
    return { choice, score }
end

local function ferry_unit_branch(base_id, score)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_MAY_PROD_TRANSPORT) == 0 or not r.need_ferry then
        return { -1, 0 }
    end
    local choice = find_proto(base_id, E.TRFLAG_SEA, E.WMODE_TRANSPORT, true)
    if choice < 0 then
        return { -1, 0 }
    end
    local base = base_api.get(base_id)
    score = score + ((funcs.target_land_region(base.faction_id) > 0
        or funcs.transport_units(base.faction_id) < 4) and 40 or 0)
    return { choice, score }
end

local function sea_probe_unit_branch(base_id, score)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_MAY_PROD_PROBES) == 0 then
        return { -1, 0 }
    end
    local base = base_api.get(base_id)
    local unknown_factions = funcs.unknown_factions(base.faction_id)
    if not (r.allow_ships and funcs.has_wmode(base.faction_id, E.WMODE_PROBE) ~= 0
        and unknown_factions > 1 and funcs.contacted_factions(base.faction_id) < 2
        and funcs.adjacent_region(base.x, base.y, -1, idiv(game.map_area_tiles(), 16), E.TRIAD_SEA)) then
        return { -1, 0 }
    end
    local choice = find_proto(base_id, E.TRFLAG_SEA, E.WMODE_PROBE, true)
    if choice < 0 then
        return { -1, 0 }
    end
    score = score + 32 * (unknown_factions - r.seaprobes) - 2 * funcs.probe_units(base.faction_id)
    return { choice, score }
end

-- build.cpp:1069-1075. find_satellite returns C.MaxProtoNum (GOV_NONE)
-- for "no candidate" -- same sentinel comparison as the C++ original
-- (`!= GOV_NONE`), not a Lua-only stand-in.
local function satellites_branch(base_id, score)
    local r = select_build_prologue(base_id)
    local base = base_api.get(base_id)
    if bit.band(r.gov, E.GOV_MAY_PROD_FACILITIES) == 0
        or r.minerals < funcs.median_limit(base.faction_id) then
        return { -1, 0 }
    end
    local choice = find_satellite(base_id)
    if choice == C.MaxProtoNum then
        return { -1, 0 }
    end
    local f = faction.get(base.faction_id)
    score = score + rand.map(0, 8 * clamp(f.base_count - 5, 0, 50))
    return { choice, score }
end

-- build.cpp:1076-1084. find_project returns C.MaxProtoNum (GOV_NONE) for
-- "no candidate", same sentinel as find_satellite above.
local function secret_project_branch(base_id, score)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_MAY_PROD_SP) == 0 or r.minerals < r.project_limit then
        return { -1, 0 }
    end
    local choice = find_project(base_id, r.wgov)
    if choice == C.MaxProtoNum then
        return { -1, 0 }
    end
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    if choice >= 0 or choice == -E.FAC_SKUNKWORKS then
        score = score + 40 * funcs.defense_modifier(base.faction_id)
    end
    score = score + 4 * clamp(f.base_count - 5, 0, 50)
    return { choice, score }
end

-- build.cpp:1152-1179. The tile-quality tally itself
-- (`base_api.former_tile_tally`) is a single opaque host wrapper, not a
-- Lua port of select_item -- see IMPLEMENTATION_DETAILS.md 4.10.29 for
-- why (select_item's return value is only ever used here as a >=0
-- eligibility check, never scored; porting its real terraform-choice
-- logic belongs to Movement/former_move, where it's actually consumed as
-- AI policy).
local function former_unit_branch(base_id, score)
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_MAY_PROD_TERRAFORMERS) == 0 then
        return { -1, 0 }
    end
    local base = base_api.get(base_id)
    local f = faction.get(base.faction_id)
    local priority = base.pop_size >= 6 and r.minerals >= 8
        and bit.band(f.player_flags_ext, E.PFLAG_EXT_STRAT_LOTS_TERRAFORMERS) ~= 0
    if not (funcs.has_wmode(base.faction_id, E.WMODE_TERRAFORM) ~= 0
        and r.formers + idiv(r.near_formers, 2) < (base.pop_size < 4 and 1 or 2 + b2n(priority))) then
        return { -1, 0 }
    end
    local tally = base_api.former_tile_tally(base_id)
    if tally.num < 4 then
        return { -1, 0 }
    end
    score = score + 8 * (tally.num - 4)
        + ((r.formers > 0 or r.near_formers > 0 or r.defend_range < 8) and 0 or 4 * tally.num)
    if tally.sea * 2 >= tally.num or r.sea_base then
        local choice = find_proto(base_id, bit.bor(E.TRFLAG_SEA, E.TRFLAG_AIR), E.WMODE_TERRAFORM, true)
        if choice >= 0 then
            return { choice, score }
        end
    end
    if not r.sea_base then
        local choice = find_proto(base_id, bit.bor(E.TRFLAG_LAND, E.TRFLAG_AIR), E.WMODE_TERRAFORM, true)
        if choice >= 0 then
            return { choice, score }
        end
    end
    return { -1, 0 }
end

-- select_build itself, step 3 sub-step 3 (IMPLEMENTATION_DETAILS.md
-- 4.10.9/4.10.14, resumed after the Consolidation gate): the
-- build_order loop's per-item base score. 1:1 transcription of
-- build.cpp:983-1041's build_order[] table -- all 45 entries (the 9 unit
-- sentinels too, as plain negative literals matching those local consts
-- exactly: SecretProject=-1, Satellites=-2, DefendUnit=-3, CombatUnit=-4,
-- ColonyUnit=-5, FormerUnit=-6, FerryUnit=-7, CrawlerUnit=-8,
-- SeaProbeUnit=-9), not just the 14 facilities this slice's scoring
-- function can fully evaluate -- this is the actual data step 4 will
-- need regardless, one mechanical low-risk pass. Keyed by item_id:
-- {explore, discover, build, conquer, energy}.
local BUILD_ORDER = {
    [-3] = {0, 0, 0, 0, 0}, -- DefendUnit
    [E.FAC_PRESSURE_DOME] = {4, 4, 4, 4, 0},
    [E.FAC_HEADQUARTERS] = {4, 4, 4, 4, 0},
    [E.FAC_PUNISHMENT_SPHERE] = {0, 0, 4, 4, 0},
    [E.FAC_RECREATION_COMMONS] = {0, 4, 4, 0, 0},
    [-4] = {0, 0, 0, 4, 0}, -- CombatUnit
    [-6] = {3, 0, 3, 0, 0}, -- FormerUnit
    [-2] = {2, 2, 2, 2, 0}, -- Satellites
    [E.FAC_RECYCLING_TANKS] = {4, 4, 4, 0, 0},
    [-9] = {2, 0, 0, 3, 0}, -- SeaProbeUnit
    [-8] = {3, 0, 3, 0, 0}, -- CrawlerUnit
    [-7] = {2, 0, 0, 2, 0}, -- FerryUnit
    [-5] = {4, 1, 1, 0, 0}, -- ColonyUnit
    [-1] = {3, 3, 3, 3, 0}, -- SecretProject
    [E.FAC_CHILDREN_CRECHE] = {2, 2, 2, 0, 0},
    [E.FAC_HAB_COMPLEX] = {4, 4, 4, 0, 0},
    [E.FAC_NETWORK_NODE] = {2, 4, 4, 0, 2},
    [E.FAC_HOLOGRAM_THEATRE] = {2, 4, 4, 0, 1},
    [E.FAC_PERIMETER_DEFENSE] = {2, 2, 2, 4, 0},
    [E.FAC_AEROSPACE_COMPLEX] = {0, 0, 3, 3, 0},
    [E.FAC_TREE_FARM] = {2, 2, 2, 0, 3},
    [E.FAC_GENEJACK_FACTORY] = {0, 1, 3, 1, 0},
    [E.FAC_ROBOTIC_ASSEMBLY_PLANT] = {0, 1, 3, 1, 0},
    [E.FAC_NANOREPLICATOR] = {0, 1, 3, 1, 0},
    [E.FAC_QUANTUM_CONVERTER] = {0, 1, 3, 1, 0},
    [E.FAC_HABITATION_DOME] = {4, 4, 4, 0, 0},
    [E.FAC_TACHYON_FIELD] = {0, 0, 3, 4, 0},
    [E.FAC_GEOSYNC_SURVEY_POD] = {0, 0, 3, 4, 0},
    [E.FAC_FLECHETTE_DEFENSE_SYS] = {0, 0, 3, 4, 0},
    [E.FAC_BIOENHANCEMENT_CENTER] = {0, 0, 0, 3, 0},
    [E.FAC_COMMAND_CENTER] = {0, 0, 0, 3, 0},
    [E.FAC_NAVAL_YARD] = {0, 0, 0, 3, 0},
    [E.FAC_PSI_GATE] = {0, 0, 3, 3, 0},
    [E.FAC_FUSION_LAB] = {2, 4, 2, 0, 4},
    [E.FAC_QUANTUM_LAB] = {2, 4, 2, 0, 4},
    [E.FAC_ENERGY_BANK] = {0, 2, 2, 0, 2},
    [E.FAC_PARADISE_GARDEN] = {0, 2, 4, 0, 0},
    [E.FAC_RESEARCH_HOSPITAL] = {0, 4, 2, 0, 3},
    [E.FAC_NANOHOSPITAL] = {0, 4, 2, 0, 3},
    [E.FAC_HYBRID_FOREST] = {2, 2, 2, 0, 3},
    [E.FAC_BIOLOGY_LAB] = {3, 2, 0, 0, 0},
    [E.FAC_CENTAURI_PRESERVE] = {3, 0, 0, 0, 0},
    [E.FAC_COVERT_OPS_CENTER] = {0, 0, 0, 3, 0},
    [E.FAC_EMPTY_FACILITY_42] = {0, 2, 2, 0, 0},
    [E.FAC_EMPTY_FACILITY_43] = {0, 2, 2, 0, 0},
    [E.FAC_EMPTY_FACILITY_44] = {0, 2, 2, 0, 0},
    [E.FAC_EMPTY_FACILITY_45] = {0, 2, 2, 0, 0},
}

-- select_build itself, step 4 (IMPLEMENTATION_DETAILS.md 4.10): the
-- per-item base score (build.cpp:1064-1067), factored out so both
-- build_order_item_score (facilities) and select_build itself (units,
-- which have no other place this computation lives) can share it. w is
-- a BUILD_ORDER[item_id] weight tuple; the rand.map(0,32) draw happens
-- for every item that passes both outer gates, facility or unit alike,
-- even when the result ends up discarded (DefendUnit) -- see
-- select_build's own comment below for why this must not be skipped.
local function base_item_score(w, wgov)
    return rand.map(0, 32) + 4 * (wgov.AI_growth * w[1] + wgov.AI_tech * w[2]
        + wgov.AI_wealth * w[3] + wgov.AI_power * w[4])
end

-- Implements build.cpp:1049-1051 (skip)/1055-1058 (base formula)/
-- 1171-1177 (energy gate) only -- not the GOV_MAY_FORCE_PSYCH gate
-- (build.cpp:1178-1182, only relevant to FAC_PUNISHMENT_SPHERE/
-- FAC_GENEJACK_FACTORY, neither in the 14 facilities this covers
-- completely) and not any of the ~35 per-facility branches. For every
-- OTHER facility (a real branch exists, not ported yet), this
-- legitimately returns a different answer than C++ -- expected, not a
-- bug; the shadow-check comparison is only meaningful for: FAC_PRESSURE_
-- DOME, FAC_HEADQUARTERS, FAC_HAB_COMPLEX, FAC_AEROSPACE_COMPLEX,
-- FAC_HABITATION_DOME, FAC_FUSION_LAB, FAC_QUANTUM_LAB, FAC_ENERGY_BANK,
-- FAC_NANOHOSPITAL, FAC_COVERT_OPS_CENTER, FAC_EMPTY_FACILITY_42-45.
-- Returns -1 for unit entries (item_id < 0) or unrecognized ids -- never
-- reached for shadow-check purposes anyway (see src/build.cpp's call
-- site placement).
--
-- allow_units arrives as a hook argument (raw 0/1 int, same trap as
-- unit_score/find_proto's `defend` -- normalized below) rather than
-- being re-derived from select_build_prologue. It's computed once by
-- C++ (build.cpp:868-872), outside the build_order loop; deriving it
-- here instead would mean calling can_build_unit(base_id, -1) -- which
-- conditionally consumes RNG (random(32) when base_id's vehicle count is
-- close to conf.max_veh_num) -- once per shadow-called item (up to 38x
-- per real select_build call) instead of C++'s single real draw, and
-- could disagree with itself across items within the same call. Same
-- precedent as lua/ai/social.lua's pop_boom (IMPLEMENTATION_DETAILS.md
-- 4.5 item 2): compute once in C++, thread the result through as a
-- plain hook argument instead of re-deriving a value with RNG/ordering
-- sensitivity.
local function build_order_item_score(base_id, item_id, allow_units)
    allow_units = not (allow_units == false or allow_units == 0)
    if item_id < 0 then
        return -1
    end
    local w = BUILD_ORDER[item_id]
    if not w then
        return -1
    end
    local r = select_build_prologue(base_id)
    if bit.band(r.gov, E.GOV_MAY_PROD_FACILITIES) == 0 or not funcs.can_build(base_id, item_id) then
        return -1
    end
    if skip_facility(base_id, item_id) then
        return -1
    end
    local score = base_item_score(w, r.wgov)
    if w[5] > 0 then
        local base = base_api.get(base_id)
        if base.energy_surplus < 4 and item_id ~= E.FAC_NETWORK_NODE then
            return -1
        end
        score = score + idiv(r.wenergy * w[5] * base.energy_surplus, 4)
        score = score - 2 * base.energy_inefficiency
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.26): FAC_RECYCLING_TANKS's own
    -- branch (build.cpp:1229-1233), the last of the original 15-block
    -- catalog.
    if item_id == E.FAC_RECYCLING_TANKS then
        local base = base_api.get(base_id)
        local rt = tech.recycling_tanks()
        score = score + 16 * (rt.energy
            + clamp(5 - base.nutrient_surplus, 1, 3) * rt.nutrient
            + clamp(5 - base.mineral_surplus, 1, 3) * rt.mineral)
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.22): FAC_CHILDREN_CRECHE's own
    -- branch (build.cpp:1234-1242).
    if item_id == E.FAC_CHILDREN_CRECHE then
        local base = base_api.get(base_id)
        local f = faction.get(base.faction_id)
        score = score + 4 * base.energy_inefficiency
            + 16 * min(4, funcs.base_unused_space(base_id))
        score = score + ((f.SE_growth_pending < -1
            or f.SE_growth_pending + 2 == C.GrowthPopBoom) and 40 or 0)
        score = score + ((f.SE_growth_pending >= C.GrowthPopBoom
            or base.nutrient_surplus < 2
            or faction.has_project(E.FAC_CLONING_VATS, base.faction_id))
            and -40 or 0)
        if funcs.has_fac_built(E.FAC_HEADQUARTERS, base_id) == 0 then
            score = score + 40 * b2n(f.SE_effic_pending < 0)
                + 40 * b2n(f.SE_effic_pending < -2)
        end
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.21): the shared GOV_MAY_FORCE_PSYCH
    -- gate (build.cpp:1224-1228), positioned here (after the energy gate,
    -- before any facility-specific branch) to match C++ exactly -- also
    -- gates FAC_GENEJACK_FACTORY, not ported yet, so this half of the
    -- condition is dead code until that facility's own branch lands.
    if bit.band(r.gov, E.GOV_MAY_FORCE_PSYCH) == 0
        and (item_id == E.FAC_PUNISHMENT_SPHERE
            or (item_id == E.FAC_GENEJACK_FACTORY and base_can_riot(base_id, false)
                and tech.rules().drones_induced_genejack_factory > 0)) then
        return -1
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.21): FAC_PUNISHMENT_SPHERE's own
    -- branch (build.cpp:1229-1260 region, specifically 1243-1260).
    -- drone_riots/drones already landed in select_build_prologue
    -- (4.10.18) for this exact facility, unused until now.
    if item_id == E.FAC_PUNISHMENT_SPHERE then
        local base = base_api.get(base_id)
        local turns = base.assimilation_turns_left
        if not r.drone_riots and turns == 0 and r.drones < idiv(base.pop_size, 2) then
            return -1
        end
        local f = faction.get(base.faction_id)
        local gate = clamp(idiv(turns - 5, 10), 0, 3)
            + clamp(idiv(r.drones - base.talent_total, 2), 0, 3)
            + b2n(base.energy_surplus < 4 + 2 * base.pop_size)
            + b2n(base.energy_inefficiency > base.energy_surplus)
            + b2n(base.energy_inefficiency > 2 * base.energy_surplus)
            - 2 * funcs.has_fac_built(E.FAC_RECREATION_COMMONS, base_id)
            - 2 * funcs.has_fac_built(E.FAC_HOLOGRAM_THEATRE, base_id)
            - 2 * funcs.has_fac_built(E.FAC_NETWORK_NODE, base_id)
        if gate < 3 then
            return -1
        end
        score = score + 80 * b2n(r.drone_riots) + 16 * r.drones + 4 * turns
        score = score - 2 * ((f.SE_alloc_labs > 0)
            and (base.energy_surplus - base.energy_inefficiency) or 0)
    end

    -- select_build step 3 sub-step 4 (IMPLEMENTATION_DETAILS.md
    -- 4.10.9/4.10.15, resumed after the Consolidation gate):
    -- FAC_COMMAND_CENTER/FAC_NAVAL_YARD/FAC_BIOENHANCEMENT_CENTER
    -- (build.cpp:1322-1331). No new engine surface -- everything here
    -- was already in select_build_prologue or tech.facility().
    if (item_id == E.FAC_COMMAND_CENTER and r.sea_base)
        or (item_id == E.FAC_NAVAL_YARD and not r.allow_ships) then
        return -1
    end
    if item_id == E.FAC_COMMAND_CENTER or item_id == E.FAC_NAVAL_YARD
        or item_id == E.FAC_BIOENHANCEMENT_CENTER then
        local facility = tech.facility(item_id)
        if r.minerals < max(r.reserve, r.project_limit)
            or (r.defend_range > idiv(C.MaxEnemyRange, 2) and facility.maint > 0) then
            return -1
        end
        score = score - 4 * (facility.cost + facility.maint)
        score = score - r.defend_range
    end

    -- select_build itself, facility-branch catalog (IMPLEMENTATION_
    -- DETAILS.md 4.10.15): FAC_PERIMETER_DEFENSE/FAC_NAVAL_YARD's shared
    -- -80 penalty, plus the MaxEnemyRange bonus shared by
    -- FAC_PERIMETER_DEFENSE/FAC_TACHYON_FIELD/FAC_GEOSYNC_SURVEY_POD/
    -- FAC_FLECHETTE_DEFENSE_SYS (build.cpp:1333-1345). No new engine
    -- surface beyond queue_items[0]'s allow_units unblock above --
    -- defend_goal/MaxEnemyRange/facility.maint/defend_range were all
    -- already available.
    if (item_id == E.FAC_PERIMETER_DEFENSE and r.sea_base)
        or (item_id == E.FAC_NAVAL_YARD and not r.sea_base) then
        score = score - 80
    end
    if item_id == E.FAC_PERIMETER_DEFENSE or item_id == E.FAC_TACHYON_FIELD
        or item_id == E.FAC_GEOSYNC_SURVEY_POD or item_id == E.FAC_FLECHETTE_DEFENSE_SYS then
        local facility = tech.facility(item_id)
        score = score + 4 * (C.MaxEnemyRange - 4 * facility.maint - r.defend_range)
    end
    if item_id == E.FAC_TACHYON_FIELD or item_id == E.FAC_GEOSYNC_SURVEY_POD
        or item_id == E.FAC_FLECHETTE_DEFENSE_SYS then
        local base = base_api.get(base_id)
        if allow_units and base.defend_goal < 3 and r.defend_range > idiv(C.MaxEnemyRange, 2) then
            return -1
        end
        score = score + 16 * clamp(base.defend_goal - 3, -2, 2)
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.23): FAC_TREE_FARM/FAC_HYBRID_
    -- FOREST's shared branch (build.cpp:1292-1301).
    if item_id == E.FAC_TREE_FARM or item_id == E.FAC_HYBRID_FOREST then
        local base = base_api.get(base_id)
        local f = faction.get(base.faction_id)
        local facility = tech.facility(item_id)
        if base.eco_damage == 0 then
            score = score - ((r.sea_base or r.wgov.AI_fight > 0) and 8 or 4) * facility.cost
        end
        score = score + ((r.wgov.AI_fight > 0 or r.wgov.AI_power > 1) and 2 or 4)
            * min(40, base.eco_damage)
        score = score + ((f.SE_alloc_psych > 0) and 8 * base.specialist_adjust or 0)
        score = score + ((item_id == E.FAC_TREE_FARM and 16 or 4)
            + 8 * b2n(base.nutrient_surplus < 2) - 8 * b2n(base.nutrient_surplus > 8))
            * funcs.nearby_items(base.x, base.y, 1, 21, E.BIT_FOREST)
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.17): FAC_BIOLOGY_LAB's own branch
    -- (build.cpp:1302-1306), plus the branch it shares with FAC_CENTAURI_
    -- PRESERVE (build.cpp:1307-1310). Both must land together, not just
    -- FAC_CENTAURI_PRESERVE alone -- FAC_BIOLOGY_LAB is gated by both
    -- ifs, so implementing only the second would leave it silently
    -- incomplete, the same split-block trap 4.10.16 hit with FAC_NAVAL_
    -- YARD. r.wenergy is build.cpp:1044-1045's Wenergy local, already
    -- computed by select_build_prologue for the energy gate above.
    if item_id == E.FAC_BIOLOGY_LAB then
        local base = base_api.get(base_id)
        local f = faction.get(base.faction_id)
        score = score + 2 * r.wenergy * funcs.biology_lab_bonus()
        score = score - (f.SE_planet_pending <= 0 and 4 or 2) * base.energy_surplus
        score = score - (base.energy_surplus <= base.energy_inefficiency and 40 or 0)
    end
    if item_id == E.FAC_BIOLOGY_LAB or item_id == E.FAC_CENTAURI_PRESERVE then
        local base = base_api.get(base_id)
        score = score + 8 * min(4, funcs.psi_score(base.faction_id))
        score = score - 40 * (b2n(base.eco_damage == 0)
            + b2n(r.wgov.AI_fight > 0) + b2n(r.wgov.AI_power > 1))
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.24): the FAC_GENEJACK_FACTORY
    -- group's shared branch (build.cpp:1311-1321). GOV_MAY_FORCE_PSYCH's
    -- FAC_GENEJACK_FACTORY half (4.10.21) becomes live now that this
    -- facility has its own scoring branch too.
    if item_id == E.FAC_GENEJACK_FACTORY or item_id == E.FAC_ROBOTIC_ASSEMBLY_PLANT
        or item_id == E.FAC_NANOREPLICATOR or item_id == E.FAC_QUANTUM_CONVERTER then
        local base = base_api.get(base_id)
        local f = faction.get(base.faction_id)
        local modifier = funcs.mineral_output_modifier(base_id)
        if modifier > b2n(base.defend_goal > 2) + b2n(r.wgov.AI_wealth > 1) + b2n(r.wgov.AI_power > 1)
            or idiv(base.mineral_intake * (modifier + 3), 2)
                > funcs.clean_minerals() + f.clean_minerals_modifier then
            score = score - 100
        end
        score = score + 2 * max(-80, (r.minerals >= r.project_limit and 80 or 60) - base.mineral_intake_2)
        score = score + 8 * min(0, base.mineral_intake_2 - 16)
        score = score - ((r.wgov.AI_fight > 0 or r.wgov.AI_power > 1) and 4 or 8) * base.eco_damage
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.18): the shared FAC_RECREATION_
    -- COMMONS/FAC_HOLOGRAM_THEATRE/FAC_RESEARCH_HOSPITAL/FAC_PARADISE_
    -- GARDEN branch (build.cpp:1261-1275). mod_psych_check is pure and
    -- RNG-free (a diff_level table lookup + a fixed formula -- no
    -- random() anywhere in it) and its inputs (faction_id, diff_level,
    -- SE_effic_pending, MapAreaSqRoot) don't change within one
    -- select_build call for a given base -- unlike allow_units (4.10.16),
    -- re-deriving it fresh on every shadow-called item is safe: same
    -- result every time, just redundant work C++'s own `!base_limit`
    -- memoization (a local, not ported -- see 4.10.8's note on skipped
    -- select_build locals) avoids.
    if item_id == E.FAC_RECREATION_COMMONS or item_id == E.FAC_HOLOGRAM_THEATRE
        or item_id == E.FAC_RESEARCH_HOSPITAL or item_id == E.FAC_PARADISE_GARDEN then
        local base = base_api.get(base_id)
        local f = faction.get(base.faction_id)
        local psych = faction.psych_check(base.faction_id)
        if base.drone_total == 0 and base.specialist_total == 0
            and (base.talent_total > 0
                or (base.pop_size <= psych.content_pop and f.base_count <= 2 * psych.base_limit)) then
            return -1
        end
        local facility = tech.facility(item_id)
        if facility.cost + 2 * facility.maint < 10 then
            score = score + ((base.specialist_adjust > 0 and base.pop_size > 3) and 40 or 0)
        end
        score = score + 80 * b2n(r.drone_riots) + max(16, 16 * (5 - facility.maint)) * r.drones
        score = score + 8 * clamp(r.drones - base.talent_total, -4, 4)
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.25): FAC_NETWORK_NODE's own branch
    -- (build.cpp:1276-1291). r.artifacts is count_vehicles' own local
    -- (step 1, 4.10.10), threaded through select_build_prologue's return
    -- table for the first time here.
    if item_id == E.FAC_NETWORK_NODE then
        local base = base_api.get(base_id)
        local f = faction.get(base.faction_id)
        if faction.has_project(E.FAC_VIRTUAL_WORLD, base.faction_id) then
            if base_can_riot(base_id, false) then
                score = score + 80 * b2n(r.drone_riots) + 16 * r.drones
            end
        elseif r.artifacts == 0 and (base.energy_surplus < 4
            or bit.band(game.rules(), E.RULES_SCN_NO_TECH_ADVANCES) ~= 0) then
            return -1
        end
        if facility_count(E.FAC_NETWORK_NODE, base.faction_id) < idiv(f.base_count, 8) then
            score = score + 40
        end
        if r.artifacts ~= 0 then
            score = score + 40
        end
    end

    -- select_build itself, facility-branch catalog continued
    -- (IMPLEMENTATION_DETAILS.md 4.10.19): FAC_PSI_GATE's own branch
    -- (build.cpp:1346-1358), the last special-cased facility branch.
    -- map_range(BASE*, BASE*) (map.h:33-36) is a template that just
    -- forwards to map_range(a->x, a->y, b->x, b->y) -- confirmed by
    -- reading it, not assumed -- so the existing funcs.map_range(x1, y1,
    -- x2, y2) wrapper (4.8) is already the right call, no new wrapper
    -- needed. main_region/target_land_region are re-read here via the
    -- same funcs.* calls select_build_prologue itself uses for Wbase,
    -- rather than added to its return table, since no other branch needs
    -- them yet -- both are pure AIPlans reads, safe to call twice.
    if item_id == E.FAC_PSI_GATE then
        local base = base_api.get(base_id)
        local dist = 40
        for i = 0, base_api.count() - 1 do
            if i ~= base_id then
                local b = base_api.get(i)
                if b.faction_id == base.faction_id
                    and (funcs.has_fac_built(E.FAC_PSI_GATE, i) ~= 0
                        or base_api.item(b) == -E.FAC_PSI_GATE) then
                    local mult = (r.base_reg == funcs.region_at(b.x, b.y)) and 1 or 2
                    dist = min(dist, mult * funcs.map_range(base.x, base.y, b.x, b.y))
                end
            end
        end
        local main_region = funcs.main_region(base.faction_id)
        local target_land_region = funcs.target_land_region(base.faction_id)
        score = score + (r.sea_base and 2 or 8) * max(0, dist - 4)
            * ((main_region ~= target_land_region and r.base_reg == target_land_region) and 4 or 1)
        score = score + ((base.x == funcs.naval_start_x(base.faction_id)
            and base.y == funcs.naval_start_y(base.faction_id)) and 160 or 0)
    end

    return score
end

-- select_build itself, step 4 (IMPLEMENTATION_DETAILS.md 4.10): the
-- exact build_order[] iteration order (build.cpp:993-1041) -- needed
-- because RNG draws happen in this order, and must match C++'s exactly
-- for determinism, not just the final chosen item_id.
local BUILD_ORDER_LIST = {
    -3, E.FAC_PRESSURE_DOME, E.FAC_HEADQUARTERS, E.FAC_PUNISHMENT_SPHERE,
    E.FAC_RECREATION_COMMONS, -4, -6, -2, E.FAC_RECYCLING_TANKS, -9, -8, -7, -5, -1,
    E.FAC_CHILDREN_CRECHE, E.FAC_HAB_COMPLEX, E.FAC_NETWORK_NODE, E.FAC_HOLOGRAM_THEATRE,
    E.FAC_PERIMETER_DEFENSE, E.FAC_AEROSPACE_COMPLEX, E.FAC_TREE_FARM, E.FAC_GENEJACK_FACTORY,
    E.FAC_ROBOTIC_ASSEMBLY_PLANT, E.FAC_NANOREPLICATOR, E.FAC_QUANTUM_CONVERTER,
    E.FAC_HABITATION_DOME, E.FAC_TACHYON_FIELD, E.FAC_GEOSYNC_SURVEY_POD, E.FAC_FLECHETTE_DEFENSE_SYS,
    E.FAC_BIOENHANCEMENT_CENTER, E.FAC_COMMAND_CENTER, E.FAC_NAVAL_YARD, E.FAC_PSI_GATE,
    E.FAC_FUSION_LAB, E.FAC_QUANTUM_LAB, E.FAC_ENERGY_BANK, E.FAC_PARADISE_GARDEN,
    E.FAC_RESEARCH_HOSPITAL, E.FAC_NANOHOSPITAL, E.FAC_HYBRID_FOREST, E.FAC_BIOLOGY_LAB,
    E.FAC_CENTAURI_PRESERVE, E.FAC_COVERT_OPS_CENTER, E.FAC_EMPTY_FACILITY_42,
    E.FAC_EMPTY_FACILITY_43, E.FAC_EMPTY_FACILITY_44, E.FAC_EMPTY_FACILITY_45,
}

-- build.cpp:872's can_build_unit(base_id, -1), reduced to the one
-- conf.max_veh_num-gated expression that applies when unit_id == -1 (see
-- src/luaai.cpp's host_max_veh_num) -- ported directly rather than via a
-- generic can_build_unit(base_id, unit_id) wrapper, since select_build
-- only ever calls it with unit_id fixed at -1.
local function allow_units_check()
    local n = veh.count()
    local max_n = funcs.max_veh_num()
    return n + 32 < max_n or n + rand.map(0, 32) < max_n
end

-- select_build itself (porting-order item 3, final piece), step 4
-- (IMPLEMENTATION_DETAILS.md 4.10): the real Class 2 hook
-- (IMPLEMENTATION_PLAN.md Phase 4.1) -- wired via lua_ai_hook, so this
-- is the first hook in the project whose return value actually drives
-- the game, not just a shadow-mode comparison log. src/build.cpp's own
-- body (still shadow-verified piece by piece, unchanged) remains as the
-- C++ fallback for lua_ai=0 or a Lua error.
--
-- Reuses every already-ported/shadow-verified piece directly: select_
-- build_prologue for the shared locals, build_order_item_score for the
-- whole facility path (base score + all 38 branches), and the 7
-- push-a-candidate unit branches (colony/crawler/ferry/sea_probe/
-- satellites/secret_project/former) verbatim -- each is safe to call
-- here since select_build_prologue itself is RNG-free (proven by every
-- earlier shadow-verification session calling it fresh per item with 0
-- mismatches), so re-deriving it inside these branches costs nothing but
-- redundant work.
--
-- DefendUnit/CombatUnit get their own inline logic instead: the existing
-- DefendUnit hooks (defend_unit_land_defense/_explore_veh) are reused
-- directly (both immediate-return only, no "else" path to duplicate),
-- but CombatUnit's existing hook (combat_unit_early_return) only covers
-- its immediate-return half -- calling it AND separately recomputing
-- select_combat for the push_item fallback would call select_combat
-- twice, drawing RNG twice instead of C++'s single call, so CombatUnit's
-- full branch (both outcomes) is inlined here instead, calling
-- select_combat exactly once, matching build.cpp:1121-1151.
--
-- The per-item base score (rand.map(0,32) + Wgov-weighted sum) is drawn
-- for EVERY item that passes both outer gates, unit or facility alike,
-- even when the result is discarded (DefendUnit never scores/pushes at
-- all) -- build.cpp's own `score = random(32) + ...` runs unconditionally
-- before any `if (t == X)` branch, so skipping this draw for "irrelevant"
-- items would desync every later item's RNG draws against C++.
local function select_build(base_id)
    local base = base_api.get(base_id)
    local faction_id = base.faction_id
    local r = select_build_prologue(base_id)

    -- build.cpp:868-872: project_change/allow_units, computed once here
    -- (not inside select_build_prologue -- see build_order_item_score's
    -- own comment on why allow_units specifically must not be
    -- re-derived per item).
    local project_change = base_api.item_is_project(base)
        and not funcs.can_build(base_id, -base_api.item(base))
        and bit.band(base.state_flags, E.BSTATE_PRODUCTION_DONE) == 0
        and base.minerals_accumulated > tech.rules().retool_exemption
    local allow_units = allow_units_check() and not project_change

    local tracker = new_build_tracker()
    local Wt = 8
    local early_return = nil

    for _, t in ipairs(BUILD_ORDER_LIST) do
        local gate_ok = t < 0 or (bit.band(r.gov, E.GOV_MAY_PROD_FACILITIES) ~= 0 and funcs.can_build(base_id, t))
        if gate_ok and t <= -3 and not allow_units then
            gate_ok = false
        end
        if gate_ok then
            if t == -2 then -- Satellites
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = satellites_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            elseif t == -1 then -- SecretProject
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = secret_project_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            elseif t == -3 then -- DefendUnit
                base_item_score(BUILD_ORDER[t], r.wgov) -- discarded; RNG sequence only
                if bit.band(r.gov, E.GOV_ALLOW_COMBAT) ~= 0 then
                    local choice = defend_unit_land_defense(base_id)
                    if choice < 0 then
                        choice = defend_unit_explore_veh(base_id)
                    end
                    if choice >= 0 then
                        early_return = choice
                    end
                end
            elseif t == -4 then -- CombatUnit
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                if bit.band(r.gov, E.GOV_ALLOW_COMBAT) ~= 0 and r.minerals >= r.reserve then
                    local choice = select_combat(base_id, r.sea_base, r.allow_ships)
                    if choice >= 0 then
                        if rand.map(0, 256) < math.floor(256 * r.wthreat)
                            and not has_retool(base_id, choice, r.retool) then
                            early_return = choice
                        else
                            if proto_extra_cost(choice) > 0 then
                                score = score + 4 * clamp(base.mineral_surplus - 4, 0, 32)
                                score = score + 80 * funcs.has_fac_built(E.FAC_SKUNKWORKS, base_id)
                                if base.mineral_surplus >= funcs.median_limit(faction_id) then
                                    score = score
                                        + 80 * b2n(tech.proto_offense(choice) > funcs.max_offense_value(faction_id))
                                        + 80 * b2n(tech.proto_defense(choice) > funcs.max_defense_value(faction_id))
                                end
                            end
                            score = score - r.defend_range
                            push_item(tracker, base_id, choice, r.retool, score, 0)
                        end
                    end
                end
            elseif t == -6 then -- FormerUnit
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = former_unit_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            elseif t == -9 then -- SeaProbeUnit
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = sea_probe_unit_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            elseif t == -8 then -- CrawlerUnit
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = crawler_unit_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            elseif t == -7 then -- FerryUnit
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = ferry_unit_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            elseif t == -5 then -- ColonyUnit
                local score = base_item_score(BUILD_ORDER[t], r.wgov)
                local res = colony_unit_branch(base_id, score)
                if res[1] >= 0 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, res[1], r.retool, res[2], Wt)
                end
            else -- facility
                local score = build_order_item_score(base_id, t, allow_units)
                if score ~= -1 then
                    Wt = Wt - 1
                    push_item(tracker, base_id, -t, r.retool, score, Wt)
                end
            end
        end
        if early_return then
            break
        end
    end
    if early_return then
        return early_return
    end

    if tracker.item_id ~= nil then
        return tracker.item_id
    end
    if not allow_units or bit.band(r.gov, E.GOV_ALLOW_COMBAT) == 0 then
        return -E.FAC_STOCKPILE_ENERGY
    end
    return select_combat(base_id, r.sea_base, r.allow_ships)
end

-- path.cpp:474-485, duplicated from lua/ai/move.lua's own defender_count
-- (built entirely from already-exposed veh.get/veh.count/veh.at_target/
-- veh.eval_garrison, no new host wrapper) -- not required cross-module
-- since move.lua already requires build.lua for base_can_riot and a
-- reverse require would be circular.
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

-- mod_base_hurry port (item 3 remainder, IMPLEMENTATION_DETAILS.md 4.18).
-- build.cpp:42-215. BASE::can_hurry_item/drone_riots_active (engine_
-- base.h) are one-line methods over already-exposed queue_items[0]/
-- state_flags -- inlined here rather than given their own host wrapper,
-- same treatment as is_ocean(BASE*)/corner_market_active() elsewhere.
local function can_hurry_item(b)
    return b.queue_items[0] ~= -E.FAC_STOCKPILE_ENERGY
        and bit.band(b.state_flags, E.BSTATE_HURRY_PRODUCTION) == 0
        and (bit.band(b.state_flags, E.BSTATE_DRONE_RIOTS_ACTIVE) == 0
            or (b.queue_items[0] < 0 and b.queue_items[0] > -E.FAC_SKY_HYDRO_LAB))
end

local function drone_riots_active(b)
    return bit.band(b.state_flags, E.BSTATE_DRONE_RIOTS_ACTIVE) ~= 0
end

-- Class 3 via lua_ai_command_hook_base (new hook shape, src/luaai.h),
-- hooked at the very top of the C++ function (unlike former_plans/
-- land_raise_plan/invasion_plan's own call-site hooks) -- mod_base_
-- hurry's own two "delegate to the vanilla base_hurry()" early branches
-- are part of what this replicates, not a C++-side gate kept in front of
-- the hook. See IMPLEMENTATION_DETAILS.md 4.18 for the full dependency
-- inventory and why fungus_yield-style opaque wrappers were chosen for
-- mineral_cost/hurry_cost/mod_cost_factor/notify_project_done.
local function mod_base_hurry(base_id)
    local b = base_api.get(base_id)
    local f = faction.get(b.faction_id)
    local t = b.queue_items[0]
    local is_cheap = funcs.conf_simple_hurry_cost() ~= 0
        or b.minerals_accumulated >= tech.rules().retool_exemption
    local is_project = t <= -E.SP_ID_First and t >= -E.SP_ID_Last
    local player_gov = funcs.is_human(b.faction_id)
    local hurry_option

    if funcs.conf_base_hurry() < 1 then
        return 0
    elseif player_gov then
        if funcs.conf_manage_player_bases() == 0 then
            return funcs.base_hurry()
        end
        if bit.band(b.governor_flags, E.GOV_ACTIVE) ~= 0
            and bit.band(b.governor_flags, E.GOV_MAY_HURRY_PRODUCTION) ~= 0 then
            hurry_option = bit.band(b.governor_flags, E.GOV_MAY_PROD_SP) ~= 0 and 2 or 1
        else
            hurry_option = 0
        end
    else
        if not funcs.thinker_enabled(b.faction_id) then
            return funcs.base_hurry()
        end
        hurry_option = funcs.conf_base_hurry()
    end
    if hurry_option < (is_project and 2 or 1) or not can_hurry_item(b) then
        return 0
    end

    local enemy_bases = funcs.enemy_bases(b.faction_id)
    local enemy_factions = funcs.enemy_factions(b.faction_id)
    local contacted_factions = funcs.contacted_factions(b.faction_id)
    local median_limit = funcs.median_limit(b.faction_id)
    local main_region = funcs.main_region(b.faction_id)
    local target_land_region = funcs.target_land_region(b.faction_id)

    local mins = funcs.mineral_cost(base_id, t) - b.minerals_accumulated
    local cost = funcs.hurry_cost(base_id, t, mins)
    local credits = max(0, f.energy_credits - f.hurry_cost_total)
    local reserve = idiv(
        clamp(idiv(game.turn() * f.base_count, 16), 20, 500)
        * ((funcs.conf_design_units() ~= 0 and not player_gov
            and imod(game.turn(), 4) == 0) and 2 or 1)
        * ((contacted_factions == 0 or is_project) and 1 or 4)
        * ((b.defend_goal > 3 and enemy_factions > 0) and 1 or 2)
        * (funcs.has_fac_built(E.FAC_HEADQUARTERS, base_id) ~= 0 and 1 or 2),
        16)
    local divisor = max(1, 10 * b.mineral_surplus)
    local turns = idiv(10 * max(0, mins) + divisor - 1, divisor)

    if not is_cheap or mins < 1 or cost < 1 or credits - cost < reserve then
        return 0
    end

    if is_project then
        local delay = player_gov and 0
            or clamp((game.diff_level() < E.DIFF_THINKER and 1 or 0) + rand.map(0, 4), 0, 3)
        local threshold = 4 * funcs.mod_cost_factor(b.faction_id, E.RSC_MINERAL, -1)
        local wgov = governor_priorities(base_id)

        if funcs.project_base(-t) >= 0 or turns < 2 + delay
            or (b.defend_goal > 3 and enemy_factions > 0)
            or (delay > 0 and b.mineral_surplus < 4)
            or b.minerals_accumulated < threshold then
            return 0
        end
        for i = 0, base_api.count() - 1 do
            local ob = base_api.get(i)
            if ob.faction_id == b.faction_id and ob.queue_items[0] == t
                and ob.minerals_accumulated > b.minerals_accumulated then
                return 0
            end
        end
        local proj_score = 0
        local values = {}
        for i = E.SP_ID_First, E.SP_ID_Last do
            if tech.facility(i).preq_tech ~= E.TECH_Disable then
                local score = facility_score(i, wgov) + rand.map(0, 8)
                if i == -t then
                    proj_score = score
                end
                values[#values + 1] = score
            end
        end
        table.sort(values)
        if #values > 0 and proj_score < max(4, values[idiv(#values, 2) + 1]) then
            return 0
        end
        mins = funcs.mineral_cost(base_id, t) - b.minerals_accumulated
            - idiv(b.mineral_surplus, 2) - delay * b.mineral_surplus
        cost = funcs.hurry_cost(base_id, t, mins)

        if cost > 0 and cost < credits and mins > 0 and mins > b.mineral_surplus then
            funcs.hurry_item(base_id, mins, cost)
            funcs.notify_project_done(b.faction_id, -t)
            return 1
        end
        return 0
    end

    if t < 0 and (turns > 1 or drone_riots_active(b)) and cost < idiv(credits, 8) then
        if (t == -E.FAC_RECREATION_COMMONS or t == -E.FAC_PUNISHMENT_SPHERE
            or (t == -E.FAC_NETWORK_NODE
                and funcs.has_project(E.FAC_VIRTUAL_WORLD, b.faction_id) ~= 0))
            and b.drone_total + b.specialist_adjust > b.talent_total then
            return funcs.hurry_item(base_id, mins, cost)
        end
    end
    if t < 0 and turns > 1 and cost < idiv(credits, 8) then
        if t == -E.FAC_RECYCLING_TANKS or t == -E.FAC_PRESSURE_DOME
            or t == -E.FAC_TREE_FARM or t == -E.FAC_HEADQUARTERS then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if t == -E.FAC_CHILDREN_CRECHE and funcs.base_unused_space(base_id) > 2
            and b.nutrient_surplus > 0 and f.SE_growth_pending < types.counts.GrowthPopBoom then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if (t == -E.FAC_HAB_COMPLEX or t == -E.FAC_HABITATION_DOME)
            and funcs.base_unused_space(base_id) == 0 and b.nutrient_surplus > 0 then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if (t == -E.FAC_GENEJACK_FACTORY or t == -E.FAC_ROBOTIC_ASSEMBLY_PLANT
            or t == -E.FAC_NANOREPLICATOR or t == -E.FAC_QUANTUM_CONVERTER)
            and b.mineral_intake > tech.facility(-t).cost + 2 * tech.facility(-t).maint
            and b.mineral_intake_2 < 40 then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if t == -E.FAC_PERIMETER_DEFENSE and b.defend_range < 12 and enemy_factions > 0 then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if t == -E.FAC_AEROSPACE_COMPLEX
            and (f.satellites_ODP > 0 or f.satellites_nutrient > 0
                or f.satellites_mineral > 0 or f.satellites_energy > 0) then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if t == -E.FAC_PSI_GATE and b.defend_range < 16
            and main_region ~= target_land_region
            and funcs.tile_region(b.x, b.y) == target_land_region then
            return funcs.hurry_item(base_id, mins, cost)
        end
    end
    if t >= 0 and turns > 1 and cost < idiv(credits, 8) and mins < 35 then
        if proto_extra_cost(t) > 0 and cost > 50 then
            return 0
        end
        if tech.proto_is_combat_unit(t) then
            local val = (cost < idiv(credits, 16) and 1 or 0)
                + (enemy_bases > 0 and 1 or 0)
                + (enemy_factions > 0 and 1 or 0)
                + (b.defend_goal > 2 and 1 or 0)
                + (b.defend_range < 8 and 1 or 0)
                + (b.defend_range < 12 and 1 or 0)
                + (bit.band(b.state_flags, E.BSTATE_COMBAT_LOSS_LAST_TURN) ~= 0 and 2 or 0)
                + max(-2, 2 - defender_count(b.x, b.y, -1))
            if b.mineral_surplus * 2 > b.mineral_intake_2 and cost < 40 then
                val = val + rand.map(0, clamp(idiv(credits - cost, 256), 0, 8))
            end
            if val > 4 then
                return funcs.hurry_item(base_id, mins, cost)
            end
        end
        if (tech.proto_is_former(t) or tech.proto_is_supply(t))
            and turns > imod(game.turn() + base_id, 16)
            and (cost < idiv(credits, 16) or b.mineral_surplus < median_limit) then
            return funcs.hurry_item(base_id, mins, cost)
        end
        if tech.proto_is_colony(t) and b.pop_size > 1
            and (cost < idiv(credits, 16) or turns > imod(game.turn() + base_id, 16))
            and (drone_riots_active(b)
                or (funcs.base_unused_space(base_id) == 0 and b.nutrient_surplus > 1)
                or (base_can_riot(base_id, true)
                    and b.drone_total + b.specialist_adjust > b.talent_total)) then
            return funcs.hurry_item(base_id, mins, cost)
        end
    end
    return 0
end

port.need_police = need_police
port.unit_support_plan = unit_support_plan
port.check_retool = check_retool
port.prototype_factor = prototype_factor
port.proto_extra_cost = proto_extra_cost
port.base_can_riot = base_can_riot
port.unit_is_better = unit_is_better
port.unit_score = unit_score
port.find_proto = find_proto
port.select_colony = select_colony
port.select_combat = select_combat
port.facility_score = facility_score
port.governor_priorities = governor_priorities
port.facility_score_hook = facility_score_hook
port.governor_priorities_hook = governor_priorities_hook
port.count_vehicles = count_vehicles
port.select_build_prologue = select_build_prologue
port.has_retool = has_retool
port.skip_facility = skip_facility
port.push_item_score = push_item_score
port.new_build_tracker = new_build_tracker
port.push_item = push_item
port.defend_unit_land_defense = defend_unit_land_defense
port.defend_unit_explore_veh = defend_unit_explore_veh
port.combat_unit_early_return = combat_unit_early_return
port.colony_unit_branch = colony_unit_branch
port.crawler_unit_branch = crawler_unit_branch
port.ferry_unit_branch = ferry_unit_branch
port.sea_probe_unit_branch = sea_probe_unit_branch
port.prod_count = prod_count
port.satellite_count = satellite_count
port.satellite_goal_calc = satellite_goal_calc
port.find_satellite = find_satellite
port.satellites_branch = satellites_branch
port.find_missile = find_missile
port.faction_might = faction_might
port.has_pact = has_pact
port.redundant_project = redundant_project
port.find_project = find_project
port.secret_project_branch = secret_project_branch
port.former_unit_branch = former_unit_branch
port.build_order_item_score = build_order_item_score
port.select_build = select_build
port.mod_base_hurry = mod_base_hurry
return port
