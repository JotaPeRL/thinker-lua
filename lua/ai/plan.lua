-- Production/plans port, item 3 remainder (IMPLEMENTATION_PLAN.md Phase
-- 4.2 item 3, IMPLEMENTATION_DETAILS.md 4.18 for the survey that scoped
-- this). former_plans (plan.cpp:448-467) and design_units (plan.cpp:
-- 140-359) are two of the three (mod_base_hurry, build.cpp, lives in
-- build.lua instead; plans_upkeep itself is not a porting target -- see
-- 4.18). Both Class 3 via lua_ai_command_hook_faction (same shape stage
-- 7B/7C/7D established): former_plans hooked at its call site in
-- plans_upkeep (plan.cpp), same convention as land_raise_plan/
-- invasion_plan; design_units hooked inside its own body instead, since
-- it has two call sites (faction.cpp:1453/1527), same convention as
-- update_main_region_prioritize_naval (stage 7D).
local port = {
    source = {
        former_plans = { file = "src/plan.cpp", func = "former_plans",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        design_units = { file = "src/plan.cpp", func = "design_units",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local tech = dofile("lua/api/tech.lua")
local cmath = dofile("lua/api/cmath.lua")
local veh = dofile("lua/api/veh.lua")
local base_api = dofile("lua/api/base.lua")
local faction = dofile("lua/api/faction.lua")
local game = dofile("lua/api/game.lua")
-- design_units port (item 3 remainder, IMPLEMENTATION_DETAILS.md 4.18):
-- need_police, already ported and exported from build.lua's own
-- select_build work. No circular require -- build.lua never requires
-- plan.lua.
local build = dofile("lua/ai/build.lua")

local E = types.enums
local idiv = cmath.idiv
local imod = cmath.imod
local clamp = cmath.clamp
local min = math.min
local max = math.max

-- Same technique as ResInfoForestSq below: a raw int* global read
-- directly, no host wrapper (design_units port, IMPLEMENTATION_DETAILS.md
-- 4.18).
local MultiplayerActive = ffi.cast("int32_t*", types.globals.MultiplayerActive)

-- Same one-field-address technique as tech.lua's ResInfoRecyclingTanks
-- and move.lua's own ResInfoForestSq (the FIELD()/FieldShape mechanism
-- can't emit_struct a nested-struct member) -- read as int32_t[3]
-- (nutrient, mineral, energy, skipping the unused 4th), all three used
-- here unlike move.lua's single-field use.
local ResInfoForestSq = ffi.cast("int32_t*", types.globals.ResInfoForestSq)

-- former_plans's own fungus_yield(faction_id, RES_NONE) call kept as an
-- opaque host wrapper (IMPLEMENTATION_DETAILS.md 4.18): a real formula,
-- but over several Faction tech_fungus_*/SE_*_pending fields not yet
-- named in the generated cdef, plus the ManifoldHarmonicsBonus[][3]
-- lookup table -- not worth re-exposing either for this one call site.
local function former_plans(faction_id)
    local facility = tech.facility(E.FAC_TREE_FARM)
    local tree_farm = funcs.has_tech(facility.preq_tech, faction_id) ~= 0
        and facility.cost + facility.maint < 20
    local former_fungus = funcs.has_terra(E.FORMER_PLANT_FUNGUS, E.TRIAD_LAND, faction_id)
        or funcs.has_terra(E.FORMER_PLANT_FUNGUS, E.TRIAD_SEA, faction_id)
    local rules = tech.rules()
    local improv_fungus = funcs.has_tech(rules.tech_preq_improv_fungus, faction_id) ~= 0
        or funcs.has_tech(rules.tech_preq_build_road_fungus, faction_id) ~= 0
        or funcs.has_project(E.FAC_XENOEMPATHY_DOME, faction_id) ~= 0
    local value = funcs.fungus_yield(faction_id, E.RES_NONE)
        - (funcs.has_terra(E.FORMER_FOREST, E.TRIAD_LAND, faction_id)
            and ((tree_farm and 1 or 0) + ResInfoForestSq[0] + ResInfoForestSq[1] + ResInfoForestSq[2])
            or 2)
    funcs.set_keep_fungus(faction_id, clamp(2 * value, 0, improv_fungus and 8 or 4))
    local plant_fungus = former_fungus and value >= 0
        and value + (improv_fungus and 1 or 0)
            + funcs.has_project(E.FAC_MANIFOLD_HARMONICS, faction_id) > 1
    funcs.set_plant_fungus(faction_id, plant_fungus and 1 or 0)
    funcs.set_build_tubes(faction_id,
        funcs.has_terra(E.FORMER_MAGTUBE, E.TRIAD_LAND, faction_id) and 1 or 0)
end

-- design_units port (item 3 remainder, IMPLEMENTATION_DETAILS.md 4.18):
-- check_disband (plan.cpp:76-102), a static local helper. The original
-- builds three std::set<Point> (bases/units/other) to dedupe by tile;
-- since every base already occupies a distinct tile, "bases" needs no
-- separate set here -- iterating base_api directly in the final loop is
-- equivalent. units/other become plain Lua tables keyed by x*1000+y
-- (map coordinates never approach that bound). The original's asserts
-- (invariants, not logic) aren't replicated, same as debug()-only lines
-- elsewhere in this project.
local function check_disband(unit_id, faction_id)
    local units, other = {}, {}
    for i = 0, veh.count() - 1 do
        local v = veh.get(i)
        if v.faction_id == faction_id then
            local key = v.x * 1000 + v.y
            if v.unit_id == unit_id then
                units[key] = true
            elseif veh.is_combat_unit(v) or veh.is_probe(v) then
                other[key] = true
            end
        end
    end
    for i = 0, base_api.count() - 1 do
        local b = base_api.get(i)
        if b.faction_id == faction_id then
            local key = b.x * 1000 + b.y
            if units[key] and not other[key] then
                return false
            end
        end
    end
    return true
end

-- design_units port continued: upgrade_value (plan.cpp:104-138), a static
-- local helper. priority[][2] becomes a plain array of {flag, bonus}.
local UPGRADE_PRIORITY = {
    {E.ABL_AAA, 7}, {E.ABL_COMM_JAMMER, 4}, {E.ABL_POLICE_2X, 3},
    {E.ABL_TRANCE, 3}, {E.ABL_TRAINED, 2},
}

local function upgrade_value(new_id, old_id)
    local new_unit = tech.proto(new_id)
    local old_unit = tech.proto(old_id)
    local abls_new = new_unit.ability_flags
    local abls_old = old_unit.ability_flags
    local atk_new = tech.proto_offense_value(new_id)
    local atk_old = tech.proto_offense_value(old_id)
    local def_new = tech.proto_defense_value(new_id)
    local def_old = tech.proto_defense_value(old_id)
    local defend = def_old + (tech.proto_speed(old_id) == 1 and 1 or 0) > atk_old
    local diff_val = defend and (def_new - def_old) or (atk_new - atk_old)

    if new_id ~= old_id
        and old_unit.chassis_id == new_unit.chassis_id
        and old_unit.plan <= E.PLAN_RECON
        and new_unit.plan <= E.PLAN_RECON
        and atk_new >= atk_old and def_new >= def_old
        and defend == (def_new + (tech.proto_speed(new_id) == 1 and 1 or 0) > atk_new)
        and diff_val > (bit.band(abls_new, bit.bnot(abls_old)) ~= 0 and 0 or 1)
        and (max(atk_old, def_old) < 4 or diff_val >= max(idiv(atk_old + def_old, 2), 4))
        and bit.band(bit.bxor(bit.band(abls_old, abls_new), abls_old), bit.bnot(E.ABL_SLOW)) == 0
        and bit.band(abls_old, E.ABL_ARTILLERY) == bit.band(abls_new, E.ABL_ARTILLERY) then
        local value = 4 * (atk_new + def_new) - 2 * new_unit.cost
        for _, p in ipairs(UPGRADE_PRIORITY) do
            if bit.band(abls_new, p[1]) ~= 0 then
                value = value + p[2]
            end
        end
        return value
    end
    return 0
end

-- design_units port (item 3 remainder, IMPLEMENTATION_DETAILS.md 4.18):
-- plan.cpp:140-359, the heaviest of the four surveyed functions. Class 3
-- via lua_ai_command_hook_faction, hooked inside the function's own body
-- (after the conf.design_units/faction_id/is_human guard, which stays
-- C++-only fact-checking -- design_units has two call sites,
-- faction.cpp:1453/1527, so hooking inside the shared body covers both
-- uniformly instead of duplicating the seam at each call site).
--
-- Known 1:1-preserved original bug (plan.cpp:160): `arm_v = Weapon[arm].
-- offense_value` indexes the *Weapon* table with an *armor* id, not
-- Armor[arm].defense_value -- kept as-is per the project's port-before-
-- improve rule (same disposition as Movement's route_score stale-sq bug).
local function design_units(faction_id)
    local fc = faction_id
    local aaa = tech.ability(E.ABL_ID_AAA)
    local arty = tech.ability(E.ABL_ID_ARTILLERY)
    local rec = funcs.best_reactor(fc)
    local wpn = funcs.best_weapon(fc)
    local arm = funcs.best_armor(fc, -1)
    local arm_cheap = funcs.best_armor(fc, max(3, idiv(tech.weapon(wpn).cost, 2)))
    local chs_land = funcs.has_chassis(fc, E.CHS_HOVERTANK) ~= 0 and E.CHS_HOVERTANK
        or (funcs.has_chassis(fc, E.CHS_SPEEDER) ~= 0 and E.CHS_SPEEDER or E.CHS_INFANTRY)
    local chs_ship = funcs.has_chassis(fc, E.CHS_CRUISER) ~= 0 and E.CHS_CRUISER
        or (funcs.has_chassis(fc, E.CHS_FOIL) ~= 0 and E.CHS_FOIL or E.CHS_INFANTRY)
    local DEFEND_ABLS = {E.ABL_ID_AAA, E.ABL_ID_COMM_JAMMER, E.ABL_ID_POLICE_2X,
        E.ABL_ID_TRANCE, E.ABL_ID_TRAINED}
    local twoabl = funcs.has_tech(tech.rules().tech_preq_allow_2_spec_abil, fc) ~= 0
    local upgrade = imod(game.turn(), 4) == 0
    local wpn_v = tech.weapon(wpn).offense_value
    local arm_v = tech.weapon(arm).offense_value -- 1:1-preserved bug, see above

    local units_active = {}
    for i = 0, veh.count() - 1 do
        local v = veh.get(i)
        if v.faction_id == fc then
            units_active[v.unit_id] = (units_active[v.unit_id] or 0) + 1
        end
    end
    if upgrade then
        local old_units = {}
        local new_units = {}
        for i = 0, types.counts.MaxProtoNum - 1 do
            local group = idiv(i, types.counts.MaxProtoFactionNum)
            if (group == 0 or group == fc) and tech.proto_is_active(i)
                and tech.proto_triad(i) == E.TRIAD_LAND
                and tech.proto_offense_value(i) > 0 and tech.proto_defense_value(i) > 0 then
                local u = tech.proto(i)
                if group == fc and tech.proto_is_prototyped(i)
                    and bit.band(u.obsolete_factions, bit.lshift(1, fc)) == 0 then
                    new_units[#new_units + 1] = i
                end
                if units_active[i] then
                    local atk_val = tech.proto_offense_value(i)
                    local def_val = tech.proto_defense_value(i)
                    -- Not `and/or`: the C++ ternary's two branches are
                    -- both booleans, so the idiom would silently fall
                    -- through to the else-branch whenever the then-branch
                    -- is false.
                    local outdated
                    if atk_val > def_val then
                        outdated = atk_val < wpn_v
                    else
                        outdated = def_val < arm_v
                    end
                    if bit.band(u.obsolete_factions, bit.lshift(1, fc)) ~= 0 or outdated then
                        local score = (bit.band(u.ability_flags, bit.bnot(E.ABL_SLOW)) ~= 0 and 0 or 4)
                            + (atk_val == 1 and 4 or 0) + (def_val == 1 and 4 or 0)
                            - atk_val - def_val - u.cost
                        old_units[#old_units + 1] = {item_id = i, score = score}
                    end
                end
            end
        end
        -- score_max_queue_t: highest score first, ties by highest item_id
        -- (SItem::operator<, plan.h).
        table.sort(old_units, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.item_id > b.item_id
        end)
        for _, old in ipairs(old_units) do
            local num = funcs.veh_count(fc, old.item_id)
            local best_score = 0
            local best_id = -1
            for _, new_unit_id in ipairs(new_units) do
                local score = upgrade_value(new_unit_id, old.item_id)
                if score > best_score then
                    best_score = score
                    best_id = new_unit_id
                end
            end
            if best_id >= 0 and num > 0 then
                local f = faction.get(fc)
                local cost_limit = idiv(
                    clamp(idiv(funcs.defense_modifier(fc), 2) + 1, 1, 3)
                    * max(0, f.energy_credits - 20),
                    4)
                local cost = 10 * funcs.mod_upgrade_cost(fc, best_id, old.item_id)
                local total_cost = num * cost
                if cost < 50 + min(50, idiv(f.energy_credits, 32)) then
                    if total_cost < cost_limit then
                        funcs.full_upgrade(fc, best_id, old.item_id)
                    elseif old.score > 0 then
                        funcs.part_upgrade(fc, best_id, old.item_id)
                    end
                end
            end
        end
        units_active = {}
        for i = 0, veh.count() - 1 do
            local v = veh.get(i)
            if v.faction_id == fc then
                units_active[v.unit_id] = (units_active[v.unit_id] or 0) + 1
            end
        end
    end

    local obsolete = {}
    local active = 0
    for i = 0, types.counts.MaxProtoNum - 1 do
        if i >= types.counts.MaxProtoFactionNum and idiv(i, types.counts.MaxProtoFactionNum) == fc
            and tech.proto_is_active(i) then
            active = active + 1
            local u = tech.proto(i)
            local ac = units_active[i] or 0
            if tech.proto_is_prototyped(i)
                and bit.band(u.obsolete_factions, bit.lshift(1, fc)) ~= 0
                and ac < 8
                and (ac == 0 or (not tech.proto_is_colony(i) and not tech.proto_is_supply(i)
                    and not tech.proto_is_transport(i) and not tech.proto_is_missile(i))) then
                local score = ac * (u.cost + 1) * (tech.proto_triad(i) == E.TRIAD_AIR and 4 or 1)
                obsolete[#obsolete + 1] = {item_id = i, score = score}
            end
        end
    end
    if active >= 60 then
        -- score_min_queue_t: lowest score first, ties by lowest item_id.
        table.sort(obsolete, function(a, b)
            if a.score ~= b.score then return a.score < b.score end
            return a.item_id < b.item_id
        end)
        for _, ob in ipairs(obsolete) do
            active = active - 1
            if active >= (ob.score ~= 0 and 56 or 48)
                and (ob.score == 0 or (upgrade and check_disband(ob.item_id, fc))) then
                funcs.retire_proto(ob.item_id, fc)
            end
        end
    end

    if funcs.has_weapon(fc, E.WPN_PROBE_TEAM) ~= 0 then
        if chs_ship ~= E.CHS_INFANTRY then
            local ship = (rec == E.REC_FISSION and funcs.has_chassis(fc, E.CHS_FOIL) ~= 0)
                and E.CHS_FOIL or chs_ship
            local algo = funcs.has_ability(fc, E.ABL_ID_ALGO_ENHANCEMENT, chs_ship, E.WPN_PROBE_TEAM) ~= 0
                and E.ABL_ALGO_ENHANCEMENT or E.ABL_NONE
            funcs.create_proto(fc, ship, E.WPN_PROBE_TEAM,
                rec >= E.REC_FUSION and arm or E.ARM_NO_ARMOR, algo, rec, E.PLAN_PROBE)
        end
        if arm ~= E.ARM_NO_ARMOR and rec >= E.REC_FUSION then
            local algo = funcs.has_ability(fc, E.ABL_ID_ALGO_ENHANCEMENT, chs_land, E.WPN_PROBE_TEAM) ~= 0
                and E.ABL_ALGO_ENHANCEMENT or E.ABL_NONE
            funcs.create_proto(fc, chs_land, E.WPN_PROBE_TEAM, arm, algo, rec, E.PLAN_PROBE)
        end
    end
    if chs_ship ~= E.CHS_INFANTRY and wpn_v >= 4 then
        local long_range = funcs.long_range_artillery() > 0 and MultiplayerActive[0] == 0
            and (tech.rules().artillery_max_rng <= 4 or arty.cost == 0 or arty.cost == 1)
            and funcs.has_ability(fc, E.ABL_ID_ARTILLERY, chs_ship, wpn) ~= 0
        if long_range then
            local arty_speed = arty.cost == -4 or arty.cost == -6 or arty.cost == -7
            local arty_armor = arty.cost == -3 or arty.cost == -5 or arty.cost == -7
            local arm_ship = ((rec >= E.REC_FUSION or not arty_speed) and not arty_armor)
                and (rec >= E.REC_QUANTUM and arm or arm_cheap) or E.ARM_NO_ARMOR
            local abls = bit.bor(E.ABL_ARTILLERY,
                (twoabl and funcs.has_ability(fc, E.ABL_ID_AAA, chs_ship, wpn) ~= 0
                    and (rec >= E.REC_QUANTUM or tech.weapon(wpn).cost <= 6 * rec or not arty_speed)
                    and arm_ship ~= E.ARM_NO_ARMOR)
                and E.ABL_AAA or E.ABL_NONE)
            funcs.create_proto(fc, chs_ship, wpn, arm_ship, abls, rec, E.PLAN_OFFENSE)
        end
        if not long_range or arty.cost < -1 or arty.cost > 2 then
            local arm_ship = (wpn_v >= 6 or rec >= E.REC_FUSION)
                and (rec >= E.REC_QUANTUM and arm or arm_cheap) or E.ARM_NO_ARMOR
            local abls = (funcs.has_ability(fc, E.ABL_ID_AAA, chs_ship, wpn) ~= 0
                and (rec >= E.REC_FUSION or (aaa.cost >= -1 and aaa.cost <= rec))
                and arm_ship ~= E.ARM_NO_ARMOR)
                and E.ABL_AAA or E.ABL_NONE
            funcs.create_proto(fc, chs_ship, wpn, arm_ship, abls, rec, E.PLAN_OFFENSE)
        end
    end
    if arm ~= E.ARM_NO_ARMOR then
        local abls = E.ABL_NONE
        local num = 0
        for _, v in ipairs(DEFEND_ABLS) do
            local skip = false
            if v == E.ABL_ID_POLICE_2X and not build.need_police(fc) then
                skip = true
            elseif v == E.ABL_ID_TRAINED and faction.get(fc).SE_morale < 0 then
                skip = true
            end
            if not skip then
                if funcs.has_ability(fc, v, E.CHS_INFANTRY, E.WPN_HAND_WEAPONS) ~= 0 then
                    abls = bit.bor(abls, bit.lshift(1, v))
                    num = num + 1
                end
                if num > (twoabl and 1 or 0) then
                    break
                end
            end
        end
        funcs.create_proto(fc, E.CHS_INFANTRY, E.WPN_HAND_WEAPONS, arm, abls, rec, E.PLAN_DEFENSE)

        if bit.band(abls, E.ABL_POLICE_2X) == 0 and build.need_police(fc)
            and funcs.has_ability(fc, E.ABL_ID_POLICE_2X, E.CHS_INFANTRY, E.WPN_HAND_WEAPONS) ~= 0 then
            funcs.create_proto(fc, E.CHS_INFANTRY, E.WPN_HAND_WEAPONS, arm,
                E.ABL_POLICE_2X, rec, E.PLAN_DEFENSE)
        end
    end
    if funcs.has_chassis(fc, E.CHS_NEEDLEJET) ~= 0 then
        local addon = (twoabl and funcs.has_ability(fc, E.ABL_ID_DEEP_RADAR, E.CHS_NEEDLEJET, wpn) ~= 0)
            and E.ABL_DEEP_RADAR or E.ABL_NONE
        if funcs.has_ability(fc, E.ABL_ID_AIR_SUPERIORITY, E.CHS_NEEDLEJET, wpn) ~= 0 then
            local abls = bit.bor(E.ABL_AIR_SUPERIORITY, addon)
            funcs.create_proto(fc, E.CHS_NEEDLEJET, wpn, E.ARM_NO_ARMOR, abls, rec, E.PLAN_AIR_SUPERIORITY)
        end
        if funcs.has_ability(fc, E.ABL_ID_NERVE_GAS, E.CHS_NEEDLEJET, wpn) ~= 0
            and funcs.use_nerve_gas(fc) ~= 0 then
            local abls = bit.bor(E.ABL_NERVE_GAS, addon)
            funcs.create_proto(fc, E.CHS_NEEDLEJET, wpn, E.ARM_NO_ARMOR, abls, rec, E.PLAN_OFFENSE)
        elseif funcs.has_ability(fc, E.ABL_ID_DISSOCIATIVE_WAVE, E.CHS_NEEDLEJET, wpn) ~= 0
            and funcs.has_ability(fc, E.ABL_ID_AAA, E.CHS_INFANTRY, wpn) ~= 0 then
            local abls = bit.bor(E.ABL_DISSOCIATIVE_WAVE, addon)
            funcs.create_proto(fc, E.CHS_NEEDLEJET, wpn, E.ARM_NO_ARMOR, abls, rec, E.PLAN_OFFENSE)
        end
    end
    if funcs.has_weapon(fc, E.WPN_TERRAFORMING_UNIT) ~= 0 and rec >= E.REC_FUSION then
        local grav = funcs.has_chassis(fc, E.CHS_GRAVSHIP) ~= 0
        local chs = grav and E.CHS_GRAVSHIP or chs_land
        local abls = bit.bor(
            (funcs.has_ability(fc, E.ABL_ID_SUPER_TERRAFORMER, chs, E.WPN_TERRAFORMING_UNIT) ~= 0)
                and E.ABL_SUPER_TERRAFORMER or E.ABL_NONE,
            (twoabl and not grav
                and funcs.has_ability(fc, E.ABL_ID_FUNGICIDAL, chs, E.WPN_TERRAFORMING_UNIT) ~= 0)
                and E.ABL_FUNGICIDAL or E.ABL_NONE)
        funcs.create_proto(fc, chs, E.WPN_TERRAFORMING_UNIT, E.ARM_NO_ARMOR, abls,
            E.REC_FUSION, E.PLAN_TERRAFORM)
    end
    if funcs.has_weapon(fc, E.WPN_SUPPLY_TRANSPORT) ~= 0 and rec >= E.REC_FUSION
        and arm_cheap ~= E.ARM_NO_ARMOR then
        funcs.create_proto(fc, E.CHS_INFANTRY, E.WPN_SUPPLY_TRANSPORT,
            rec >= E.REC_QUANTUM and arm or arm_cheap, E.ABL_NONE, rec, E.PLAN_SUPPLY)
    end
end

port.former_plans = former_plans
port.design_units = design_units
return port
