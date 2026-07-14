-- 1:1 port of social_score() + the category/model selection loop inside
-- mod_social_ai() (IMPLEMENTATION_PLAN.md Phase 4, porting-order item 2 --
-- see IMPLEMENTATION_DETAILS.md 4.5 for the scoping decision). Registered
-- as a Class-2-shaped hook (propose-then-commit, IMPLEMENTATION_PLAN.md
-- 4.1): this returns a packed proposal int, C++ still validates
-- affordability and applies it -- src/faction.cpp's mod_social_ai only
-- compares the proposal against its own computation and logs a mismatch
-- (same temporary dual-run pattern as lua/ai/tech.lua's mod_tech_val/
-- mod_tech_ai, standing in for real Phase 5 shadow mode).
--
-- Deliberately NOT ported (see IMPLEMENTATION_DETAILS.md 4.5): the
-- pop_boom/want_pop base-iteration in mod_social_ai (no BASE struct in the
-- FFI yet) -- kept in C++, passed in as a hook arg; mod_wants_to_attack
-- (porting-order item 2b, separate function).
--
-- Translation notes (mirrors lua/ai/tech.lua):
-- * idiv/imod for every C truncating division/modulo.
-- * math.max/math.min are fine here -- only math.random/randomseed are
--   forbidden (determinism), not the rest of the math library.
-- * social_calc()'s own internal computation (facility bonuses, faction
--   bonus table, SocialField lookup) stays entirely in C++, exposed as one
--   opaque host call (faction.social_calc) -- it is engine mechanics, not
--   AI policy, per the project's read/write asymmetry rule.
local port = {
    source = {
        social_score = { file = "src/faction.cpp", func = "social_score",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        mod_social_ai = { file = "src/faction.cpp", func = "mod_social_ai",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local faction = dofile("lua/api/faction.lua")
local tech = dofile("lua/api/tech.lua")
local game = dofile("lua/api/game.lua")
local cmath = dofile("lua/api/cmath.lua")

local idiv = cmath.idiv
local imod = cmath.imod
local clamp = cmath.clamp
local max = math.max
local min = math.min
local E = types.enums
local C = types.counts

-- Order of CSocialEffect's values[11] (engine_types.h:797-814), used only
-- for the one place the original code indexes by a dynamic effect number
-- (m->soc_priority_effect) rather than a named field.
local EFFECT_ORDER = {
    "economy", "effic", "support", "talent", "morale", "police",
    "growth", "planet", "probe", "industry", "research",
}

-- Reads the faction's *currently active* effect values directly (no
-- social_calc call) -- used when the hypothetical model equals the model
-- already in effect (faction.cpp:1314-1315's `if (soc.models[sf] == sm)`).
local function vals_from_current(f)
    return {
        economy = f.SE_economy, effic = f.SE_effic, support = f.SE_support,
        talent = f.SE_talent, morale = f.SE_morale, police = f.SE_police,
        growth = f.SE_growth, planet = f.SE_planet, probe = f.SE_probe,
        industry = f.SE_industry, research = f.SE_research,
    }
end

-- faction.cpp:1297-1429
local function social_score(faction_id, sf, sm, pop_boom)
    local f = faction.get(faction_id)
    local m = faction.meta(faction_id)
    local def_val = faction.defense_modifier(faction_id)
    local base_val = max(1, f.base_count)
    local base_ratio = min(10, idiv(10 * f.base_count, clamp(idiv(game.map_area_sq_root(), 2), 8, 40)))
    local morale_mod = (faction.has_project(E.FAC_COMMAND_NEXUS, faction_id) and 2 or 0)
        + (faction.has_project(E.FAC_CYBORG_FACTORY, faction_id) and 2 or 0)
    local probe_mod = (game.turn() - m.thinker_last_mc_turn < 10) and (def_val + 1) or 0
    local sc = 0

    -- current[0..3]: the CSocialCategory overlay on SE_Politics..SE_Future
    -- (faction.cpp:1310-1311's `(CSocialCategory*)&f->SE_Politics`).
    local current = { [0] = f.SE_Politics, [1] = f.SE_Economics, [2] = f.SE_Values, [3] = f.SE_Future }

    local vals
    if current[sf] == sm then
        vals = vals_from_current(f)
    else
        local models = { [0] = current[0], [1] = current[1], [2] = current[2], [3] = current[3] }
        models[sf] = sm
        vals = faction.social_calc(models, faction_id)
    end

    if m.soc_priority_category >= 0 and m.soc_priority_model >= 0 then
        if sf == m.soc_priority_category then
            if sm == m.soc_priority_model then
                sc = sc + faction.social_ai_bias()
            elseif sm ~= E.SOCIAL_M_FRONTIER then
                sc = sc - faction.social_ai_bias()
            end
        else
            if current[m.soc_priority_category] == m.soc_priority_model then
                sc = sc + faction.social_ai_bias()
            elseif current[m.soc_priority_category] ~= E.SOCIAL_M_FRONTIER then
                sc = sc - faction.social_ai_bias()
            end
        end
    end
    if m.soc_priority_effect >= 0 and m.soc_priority_effect < C.MaxSocialEffectNum then
        sc = sc + clamp(vals[EFFECT_ORDER[m.soc_priority_effect + 1]], -4, 4)
            * clamp(idiv(faction.social_ai_bias(), 10), 0, 2)
    end
    if vals.economy >= 2 then
        sc = sc + (vals.economy >= 4 and 16 or 12)
    end
    if vals.effic < -2 then
        sc = sc - (vals.effic < -3 and 16 or 8)
    end
    if vals.support < -3 then
        sc = sc - 16
    end
    if vals.morale >= 1 and vals.morale + morale_mod >= 4 then
        sc = sc + 10
    end
    if vals.probe >= 3 and not faction.has_project(E.FAC_HUNTER_SEEKER_ALGORITHM, faction_id) then
        sc = sc + 4 * def_val
    end
    sc = sc + max(2, 2 + 4 * f.AI_wealth + 3 * f.AI_tech - f.AI_fight)
        * clamp(vals.economy, -3, 5)
    sc = sc + max(2, 2 * f.AI_wealth + 2 * f.AI_tech - f.AI_fight + idiv(base_ratio, 2))
        * clamp(vals.effic, -4, 6)
    sc = sc + max(2, 3 + 2 * f.AI_power + 2 * f.AI_fight - idiv(base_ratio, 4) + idiv(def_val, 2))
        * clamp(vals.support, -4, 3)
    sc = sc + max(2, def_val + 2 * f.AI_power + 2 * f.AI_fight)
        * clamp(vals.morale, -4, 4)

    local creche = tech.has_tech(tech.facility(E.FAC_CHILDREN_CRECHE).preq_tech, faction_id) ~= 0
        or faction.has_free_facility(E.FAC_CHILDREN_CRECHE, faction_id)
    local sphere = tech.has_tech(tech.facility(E.FAC_PUNISHMENT_SPHERE).preq_tech, faction_id) ~= 0
    local nodrones = faction.has_free_facility(E.FAC_PUNISHMENT_SPHERE, faction_id)
    local skipdrones = faction.has_project(E.FAC_TELEPATHIC_MATRIX, faction_id)

    if skipdrones and not nodrones then
        sc = sc + 4 * clamp(vals.talent, 0, 5)
    elseif not nodrones then
        sc = sc + 4 * clamp(vals.talent, -5, 5)
        sc = sc + (((vals.police >= 0) or (def_val > 2)) and 4 or 2)
            * clamp(vals.police, (def_val > 2 and -10 or -5), 3)
        if vals.police < -2 then
            sc = sc - (vals.police < -3 and 2 or 1) * def_val
                * (faction.has_aircraft(faction_id) and 2 or 1)
        end
        if faction.has_project(E.FAC_LONGEVITY_VACCINE, faction_id) and sf == E.SOCIAL_C_ECONOMICS then
            sc = sc + (sm == E.SOCIAL_M_PLANNED and 10 or 0)
            sc = sc + ((sm == E.SOCIAL_M_SIMPLE or sm == E.SOCIAL_M_GREEN) and 5 or 0)
        end
        local drone_score = 3 + (m.rule_drone > 0 and 1 or 0) - (m.rule_talent > 0 and 1 or 0)
            - (sphere and 1 or 0)
        if game.sunspot_duration() > 1 and game.diff_level() >= E.DIFF_LIBRARIAN
        and faction.un_charter() and vals.police >= 0 then
            sc = sc + 3 * drone_score
        end
        if not faction.un_charter() and vals.police >= 0 then
            sc = sc + 2 * drone_score
        end
    end

    if not faction.has_project(E.FAC_CLONING_VATS, faction_id) then
        if pop_boom ~= 0 and vals.growth + (creche and 2 or 0) >= C.GrowthPopBoom then
            sc = sc + 20
        end
        if vals.growth < -2 then
            sc = sc - 5 * clamp(6 - def_val, 2, 4)
        end
        sc = sc + ((def_val < 3) and (5 + 3 * pop_boom) or (3 + 2 * pop_boom))
            * clamp(vals.growth, -3, C.GrowthPopBoom)
    end
    if faction.keep_fungus(faction_id) ~= 0 then
        sc = sc + 3 * clamp(vals.planet, -3, 0)
    end
    sc = sc + max(2, (f.SE_planet_base > 0 and 5 or 2) + idiv(m.rule_psi, 10)
        + (faction.has_project(E.FAC_MANIFOLD_HARMONICS, faction_id) and 6 or 0)) * clamp(vals.planet, -3, 3)
    sc = sc + max(2, 1 + def_val + probe_mod + 2 * f.AI_power + 2 * f.AI_fight)
        * clamp(vals.probe, -2, 3)
    sc = sc + (2 * clamp(vals.industry, -3, 5) - 8 * faction.mineral_factor(faction_id, vals.industry))

    if bit.band(game.rules(), E.RULES_SCN_NO_TECH_ADVANCES) == 0 then
        sc = sc + max(2, 3 + 4 * f.AI_tech + 2 * (f.AI_wealth - f.AI_fight))
            * clamp(vals.research, -5, 5)
    end

    -- social_psych is 2D (int32_t[8][9]) in C++; gen_ffi flattens it to a
    -- single int32_t[72] cdef field, indexed row-major (i*9+j) to match.
    local psy_idx = clamp(vals.talent + 3, 0, 7) * 9 + clamp(vals.police + 5, 0, 8)
    local psy_mod = idiv(f.social_psych[psy_idx], base_val)
    local sup_mod = idiv(4 * f.social_support[clamp(vals.support + 4, 0, 7)], base_val)
    local eff_mod = idiv(2 * f.social_effic[clamp(8 - vals.effic, 0, 8)], base_val)
    sc = sc + (((skipdrones or nodrones) and 0 or psy_mod) - sup_mod - eff_mod)

    return sc
end

-- faction.cpp:1441-1521 (selection loop only, pop_boom/want_pop deferred to
-- the C++ seam per IMPLEMENTATION_DETAILS.md 4.5). Returns a packed
-- proposal (sf * MaxSocialModelNum + sm2), or -1 for "no change proposed".
local function mod_social_ai(faction_id, pop_boom)
    local f = faction.get(faction_id)
    local score_diff = 1 + imod(game.turn() + 11 * faction_id, 6)
    local sf = -1
    local sm2 = -1
    local current = { [0] = f.SE_Politics, [1] = f.SE_Economics, [2] = f.SE_Values, [3] = f.SE_Future }

    for i = 0, C.MaxSocialCatNum - 1 do
        local sm1 = current[i]
        local sc1 = social_score(faction_id, i, sm1, pop_boom)
        for j = 0, C.MaxSocialModelNum - 1 do
            if j ~= sm1 and faction.society_avail(i, j, faction_id) ~= 0 then
                local sc2 = social_score(faction_id, i, j, pop_boom)
                if sc2 - sc1 > score_diff then
                    sf = i
                    sm2 = j
                    score_diff = sc2 - sc1
                end
            end
        end
    end

    if sf >= 0 then
        return sf * C.MaxSocialModelNum + sm2
    end
    return -1
end

port.social_score = social_score
port.mod_social_ai = mod_social_ai
return port
