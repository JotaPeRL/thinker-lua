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
local function vehicle_counts_check(base_id, sea_base)
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

    log.debug(
        "vehicle_counts base:%d def:%d frm:%d prb:%d crw:%d pods:%d scouts:%d "
        .. "lprb:%d sprb:%d trn:%d near_frm:%d art:%d ferry:%d supply:%s",
        base_id, idiv(defenders + 2, 8), formers, landprobes + seaprobes,
        all_crawlers, pods, scouts, landprobes, seaprobes, transports,
        near_formers, artifacts, need_ferry, tostring(allow_supply))
end

-- select_build itself (porting-order item 3, final piece), step 2
-- (IMPLEMENTATION_DETAILS.md 4.10.5/4.10.9, resumed after the
-- Consolidation gate): push_item (build.cpp:816-836) + its two small
-- dependents. Not wiring select_build itself yet (steps 3-4) -- these
-- are standalone, verifiable building blocks. mod_base_making/
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

-- Temporary, verification-only (same precedent as vehicle_counts_check,
-- step 1): select_build's own push_item() already logs the exact
-- adjusted score for every call (build.cpp:835), so this gives the same
-- kind of log-diff verification without wiring the real hook yet.
-- Deleted once step 4 wires select_build for real.
local function push_item_check(base_id, item_id, retool, score, modifier)
    log.debug("push_item_check %d %d %d",
        push_item_score(base_id, item_id, retool, score, modifier), retool, item_id)
    return 1
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
port.vehicle_counts_check = vehicle_counts_check
port.has_retool = has_retool
port.skip_facility = skip_facility
port.push_item_score = push_item_score
port.new_build_tracker = new_build_tracker
port.push_item = push_item
port.push_item_check = push_item_check
return port
