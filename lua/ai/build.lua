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

local idiv = cmath.idiv
local clamp = cmath.clamp
local max = math.max
local min = math.min
local E = types.enums
local C = types.counts

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

port.need_police = need_police
port.unit_support_plan = unit_support_plan
port.check_retool = check_retool
port.prototype_factor = prototype_factor
port.proto_extra_cost = proto_extra_cost
port.base_can_riot = base_can_riot
port.unit_is_better = unit_is_better
port.unit_score = unit_score
port.find_proto = find_proto
return port
