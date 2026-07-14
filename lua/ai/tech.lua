-- 1:1 port of mod_tech_val/mod_tech_ai (IMPLEMENTATION_PLAN.md Phase 4,
-- milestone M4 -- the research-AI pilot). Registered as Class 1 hooks
-- (pure query: Lua returns a value, C++ uses it directly; nil/error
-- falls back to the untouched C++ body -- src/luaai.cpp's lua_ai_hook()).
--
-- Translation notes (see IMPLEMENTATION_PLAN.md 3.7 / this port):
-- * Integer division uses cmath.idiv (C truncating semantics, not Lua's
--   floor division) wherever the original uses `/` on ints.
-- * A C `int` used as a boolean (`if (!simple_calc)`, `if (enemy_count)`,
--   ...) becomes an explicit `== 0`/`~= 0` comparison -- Lua treats 0 as
--   truthy, unlike C, so relying on bare truthiness here would silently
--   diverge. Only genuine `bool`-returning host calls (is_human,
--   revised_tech_cost) are used as real Lua booleans.
-- * Bitwise reads use the `bit` library (already sandboxed).
local port = {
    source = {
        mod_tech_val = { file = "src/tech.cpp", func = "mod_tech_val",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        mod_tech_ai = { file = "src/tech.cpp", func = "mod_tech_ai",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local faction = dofile("lua/api/faction.lua")
local tech = dofile("lua/api/tech.lua")
local map = dofile("lua/api/map.lua")
local game = dofile("lua/api/game.lua")
local rand = dofile("lua/api/rand.lua")
local cmath = dofile("lua/api/cmath.lua")

local idiv = cmath.idiv
local clamp = cmath.clamp
local E = types.enums
local C = types.counts

-- tech.cpp:366-611
local function tech_val(tech_id, faction_id, simple_calc)
    local f = faction.get(faction_id)
    local m = faction.meta(faction_id)
    if tech_id == 9999 then
        return 2
    end
    local value

    if tech_id < C.MaxTechnologyNum then
        local t = tech.get(tech_id)
        local enemy_count = 0
        for i = 1, C.MaxPlayerNum - 1 do
            if i ~= faction_id and faction.has_treaty(faction_id, i, E.DIPLO_VENDETTA) ~= 0 then
                enemy_count = enemy_count + 1
            end
        end
        local factor_ai = 1
        if simple_calc == 0 then
            factor_ai = bit.band(game.rules(), E.RULES_BLIND_RESEARCH) ~= 0 and 4 or 2
        end
        value = t.AI_growth * (factor_ai * f.AI_growth + 1)
            + t.AI_wealth * (factor_ai * f.AI_wealth + 1)
            + t.AI_tech * (factor_ai * f.AI_tech + 1)
            + t.AI_power * (factor_ai * f.AI_power + 1)
        local base_count = f.base_count
        if (t.AI_power == 0 or (f.AI_power == 0 and enemy_count == 0))
        and (t.AI_tech == 0 or f.AI_tech == 0)
        and (t.AI_wealth == 0 or f.AI_wealth == 0)
        and (t.AI_growth == 0 or (f.AI_growth == 0 and base_count >= 4)) then
            value = idiv(value + 1, 2)
        end
        local is_player = faction.is_human(faction_id) and 1 or 0
        local tech_id_lvl = tech.tech_level(tech_id, 0)
        if is_player == 0 and tech.has_tech(tech_id, faction_id) == 0 and simple_calc ~= 0 then
            local owners = cmath.popcount8(tech.owners(tech_id))
            if owners > 1 then
                value = value + 2 - 2 * owners
            end
            local search_lvl = 1
            for i = 0, C.MaxTechnologyNum - 1 do
                if tech.has_tech(i, faction_id) ~= 0 then
                    local current_lvl = tech.tech_level(i, 0)
                    if search_lvl < current_lvl then
                        search_lvl = current_lvl
                    end
                end
            end
            if tech_id_lvl < search_lvl then
                value = idiv(value * (tech_id_lvl + 1), search_lvl + 1)
            end
            if value < 1 then
                value = 1
            end
        end
        if simple_calc ~= 0 then
            return value
        end
        if base_count ~= 0 then
            for region = 1, C.MaxRegionLandNum - 1 do
                if map.bad_reg(region) == 0 then
                    local pwr_base = f.region_total_bases[region] * t.AI_power
                    local plan = f.region_base_plan[region]
                    if plan == E.PLAN_NAVAL_TRANSPORT and enemy_count ~= 0 and is_player == 0 then
                        value = value + idiv(pwr_base, base_count)
                    elseif plan == E.PLAN_DEFENSE then
                        value = value + idiv(pwr_base * 4, base_count * (is_player + 1))
                    elseif plan == E.PLAN_OFFENSE then
                        local mult = (f.best_weapon_value >= f.enemy_best_weapon_value) and 2 or 4
                        value = value + idiv(pwr_base * mult, base_count * (is_player + 1))
                    else
                        for i = 1, C.MaxPlayerNum - 1 do
                            local fi = faction.get(i)
                            if i ~= faction_id and fi.region_total_bases[region] ~= 0
                            and f.region_total_bases[region] ~= 0
                            and faction.has_treaty(faction_id, i, E.DIPLO_COMMLINK) ~= 0
                            and (faction.has_treaty(faction_id, i, bit.bor(E.DIPLO_PACT, E.DIPLO_TREATY)) == 0
                                or faction.has_treaty(faction_id, i, E.DIPLO_WANT_REVENGE) ~= 0) then
                                value = value + idiv(pwr_base, base_count * (is_player + 1))
                            end
                        end
                    end
                end
            end
        end
        if tech.has_tech(tech_id, faction_id) ~= 0 then
            return value
        end
        if faction.climactic_battle() ~= 0
        and tech.tech_is_preq(tech_id, tech.facility(E.FAC_ASCENT_TO_TRANSCENDENCE).preq_tech, 2) ~= 0 then
            value = value * 4
        end
        if f.SE_planet_base > 0 and f.AI_growth ~= 0 then
            if tech.tech_is_preq(tech_id, E.TECH_CentMed, 9999) ~= 0 then
                value = value * 3
            end
            if tech.tech_is_preq(tech_id, E.TECH_PlaEcon, 9999) ~= 0 then
                value = value * 2
            end
            if tech.tech_is_preq(tech_id, E.TECH_AlphCen, 3) ~= 0 then
                value = value * 2
            end
        end
        if f.SE_probe_base <= 0 then
            if tech.tech_is_preq(tech_id, tech.facility(E.FAC_HUNTER_SEEKER_ALGORITHM).preq_tech, f.AI_tech + 2) ~= 0 then
                if f.AI_power == 0 then
                    value = value * 2
                end
                if f.AI_tech ~= 0 then
                    value = value * 2
                end
            end
        end
        if f.AI_growth ~= 0 and tech.tech_is_preq(tech_id, E.TECH_DocInit, 2) ~= 0 then
            value = value * 2
        end
        if (f.AI_wealth ~= 0 or game.cloud_cover() == 0)
        and tech.tech_is_preq(tech_id, E.TECH_EnvEcon, 9999) ~= 0 then
            value = value * 2
        end
        if bit.band(t.flags, E.TFLAG_SECRETS) ~= 0 and tech.owners(tech_id) == 0
        and bit.band(game.rules(), E.RULES_BLIND_RESEARCH) == 0 then
            value = value * ((f.AI_power + 1) * 2)
        end
        if m.rule_psi > 0 then
            if tech.tech_is_preq(tech_id, tech.facility(E.FAC_DREAM_TWISTER).preq_tech, 9999) ~= 0 then
                value = value * 2
            end
        else
            local preq_tech_fusion = tech.reactor(E.REC_FUSION - 1).preq_tech
            if tech_id == preq_tech_fusion then
                value = value * 2
            end
            if tech_id == tech.reactor(E.REC_QUANTUM - 1).preq_tech then
                value = value * 2
            end
            if tech.tech_is_preq(tech_id, preq_tech_fusion, 9999) ~= 0 then
                value = value + 1
            end
            if tech.tech_is_preq(tech_id, preq_tech_fusion, 1) ~= 0
            and bit.band(game.rules(), E.RULES_BLIND_RESEARCH) == 0 then
                value = value * 2
            end
        end
        local eco_dmg_unk = idiv(f.unk_47, clamp(base_count, 1, 9999))
        if eco_dmg_unk > f.AI_power
        and (tech.tech_is_preq(tech_id, tech.facility(E.FAC_HYBRID_FOREST).preq_tech, 9999) ~= 0
            or tech.tech_is_preq(tech_id, tech.facility(E.FAC_TREE_FARM).preq_tech, 9999) ~= 0
            or tech.tech_is_preq(tech_id, tech.facility(E.FAC_CENTAURI_PRESERVE).preq_tech, 9999) ~= 0
            or tech.tech_is_preq(tech_id, tech.facility(E.FAC_TEMPLE_OF_PLANET).preq_tech, 9999) ~= 0) then
            value = value + eco_dmg_unk
        end
        if m.rule_population > 0 then
            if tech.tech_is_preq(tech_id, tech.facility(E.FAC_HAB_COMPLEX).preq_tech, 9999) ~= 0 then
                value = value * 2
            elseif game.turn() > 250
            and tech.tech_is_preq(tech_id, tech.facility(E.FAC_HABITATION_DOME).preq_tech, 9999) ~= 0 then
                value = idiv(value * 3, 2)
            end
        end
        if f.AI_power ~= 0 then
            for i = 0, C.MaxWeaponNum - 1 do
                local w = tech.weapon(i)
                if w.offense_value ~= 0 then
                    local weap_preq_tech = w.preq_tech
                    if tech_id == weap_preq_tech then
                        value = value * (is_player + 3)
                    elseif tech.tech_is_preq(tech_id, weap_preq_tech, 1) ~= 0 then
                        value = value * (is_player + 2)
                    end
                end
            end
        end
        if f.AI_tech ~= 0 or f.AI_power == 0 then
            for i = 0, C.MaxTechnologyNum - 1 do
                local ti = tech.get(i)
                if tech.has_tech(i, faction_id) == 0 and bit.band(ti.flags, E.TFLAG_SECRETS) ~= 0
                and tech.owners(i) == 0 and tech.tech_is_preq(tech_id, i, 1) ~= 0 then
                    value = value * 3
                end
            end
        end
        local formers_preq = tech.proto(E.BSC_FORMERS).preq_tech
        if tech.tech_is_preq(tech_id, formers_preq, 9999) ~= 0
        and tech.has_tech(formers_preq, faction_id) == 0 then
            value = value * 2
            if is_player == 1 then
                value = value * 2
            end
        end
        local foil_preq = tech.chassis(E.CHS_FOIL).preq_tech
        if tech.tech_is_preq(tech_id, foil_preq, 9999) ~= 0
        and tech.has_tech(foil_preq, faction_id) == 0 then
            local toggle = false
            for region = 1, C.MaxRegionLandNum - 1 do
                if f.region_total_bases[region] ~= 0 then
                    for i = 1, C.MaxPlayerNum - 1 do
                        if faction_id ~= i and faction.get(i).region_total_bases[region] == 0 then
                            toggle = true
                            break
                        end
                    end
                    if toggle and f.region_visible_tiles[region] >= map.continent(region).tile_count then
                        value = value * 3
                        if is_player == 1 then
                            value = value * 2
                        end
                        break
                    end
                end
            end
            if toggle then
                value = value * 2 + 4
            end
        end
        if tech.tech_balance_enabled() ~= 0 then
            local high_cost = tech.revised_tech_cost() and tech_id_lvl > 2
            local r = tech.rules()
            if tech_id == tech.weapon(E.WPN_TERRAFORMING_UNIT).preq_tech then
                value = value + (high_cost and 60 or 120)
            elseif tech_id == tech.weapon(E.WPN_SUPPLY_TRANSPORT).preq_tech
            or tech_id == tech.facility(E.FAC_RECYCLING_TANKS).preq_tech
            or tech_id == tech.facility(E.FAC_CHILDREN_CRECHE).preq_tech
            or tech_id == tech.facility(E.FAC_RECREATION_COMMONS).preq_tech
            or tech_id == r.tech_preq_allow_3_nutrients_sq
            or tech_id == r.tech_preq_allow_3_minerals_sq
            or tech_id == r.tech_preq_allow_3_energy_sq then
                value = value + (high_cost and 20 or 40)
            end
        end
    elseif tech_id < 97 then -- Factions
        local factor = 1
        local faction_id_2 = tech_id - C.MaxTechnologyNum
        if faction.mod_wants_to_attack(faction_id, faction_id_2, 0) == 0 then
            factor = factor + 1
        end
        if faction.mod_wants_to_attack(faction_id_2, faction_id, 0) == 0 then
            factor = factor + 1
        end
        value = factor * idiv(factor, f.AI_fight + 2)
    else -- Prototypes
        local unit_id = tech_id - 97
        value = clamp(tech.proto_offense_value(unit_id), 1, 2)
            + clamp(tech.proto_defense_value(unit_id), 1, 2)
            + clamp(tech.proto_speed(unit_id), 1, 2)
            + tech.proto(unit_id).reactor_id - 2
    end
    return value
end

-- tech.cpp:613-638
local function tech_ai(faction_id)
    local tech_id = -1
    local best_value = -2147483648 -- INT_MIN
    for i = 0, C.MaxTechnologyNum - 1 do
        if tech.mod_tech_avail(i, faction_id) ~= 0 then
            local tech_value = tech_val(i, faction_id, 0)
            if bit.band(game.rules(), E.RULES_BLIND_RESEARCH) ~= 0 then
                local f = faction.get(faction_id)
                if faction.is_human(faction_id) and i == tech.proto(E.BSC_FORMERS).preq_tech
                and (f.AI_growth ~= 0 or f.AI_wealth ~= 0) then
                    return i
                end
                local preq = tech.tech_level(i, 0)
                tech_value = preq ~= 0 and idiv(bit.lshift(tech_value, 8), preq) or 0
            end
            -- Replaces game_random (players) / game_rand (AIs) -- random_get, rand.map
            local value = rand.map(0, tech_value + 1)
            if value > best_value then
                best_value = value
                tech_id = i
            end
        end
    end
    return tech_id
end

port.mod_tech_val = tech_val
port.mod_tech_ai = tech_ai
return port
