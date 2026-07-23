-- CTech/CFacility/CReactor/CWeapon/CChassis/CArmor/unit-prototype accessors
-- + the tech-domain host-API wrappers mod_tech_val/mod_tech_ai depend on
-- (IMPLEMENTATION_PLAN.md Phase 3.2, narrowed to the tech-AI pilot).
--
-- proto_offense_value/proto_defense_value/proto_speed re-port UNIT's three
-- inline C++ methods (engine_veh.h) dropped by gen_ffi's field-only cdef
-- generation -- one-liners over the exposed weapon/armor/chassis tables,
-- per the project's rule for re-exposing dropped inline helpers.
local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")

local Tech = ffi.cast("CTech*", types.globals.Tech)
local Facility = ffi.cast("CFacility*", types.globals.Facility)
local Reactor = ffi.cast("CReactor*", types.globals.Reactor)
local Weapon = ffi.cast("CWeapon*", types.globals.Weapon)
local Armor = ffi.cast("CArmor*", types.globals.Armor)
local Chassis = ffi.cast("CChassis*", types.globals.Chassis)
local Units = ffi.cast("UNIT*", types.globals.Units)
local TechOwners = ffi.cast("uint8_t*", types.globals.TechOwners)
-- Distinct from game.rules() (the *GameRules bitmask, a plain int) --
-- Rules is a whole CRules rule-table struct.
local Rules = ffi.cast("CRules*", types.globals.Rules)
-- select_build itself, facility-branch catalog continued (IMPLEMENTATION_
-- DETAILS.md 4.10.26): FAC_RECYCLING_TANKS's own branch. Just the
-- recycling_tanks ResValue's 3 leading int32_t fields (nutrient, mineral,
-- energy -- engine_types.h:592-597), not the whole CResourceInfo.
local ResInfoRecyclingTanks = ffi.cast("int32_t*", types.globals.ResInfoRecyclingTanks)

local function bounded(name, id, max)
    assert(id >= 0 and id < max, name .. " out of range: " .. tostring(id))
end

local function get(tech_id)
    bounded("tech_id", tech_id, types.counts.MaxTechnologyNum)
    return Tech[tech_id]
end

-- Note: bounded against MaxFacilityArrayNum, not MaxFacilityNum --
-- MaxFacilityNum undercounts (Secret Projects share this array at
-- higher indices). See tools/gen_ffi.cpp for the full story.
local function facility(facility_id)
    bounded("facility_id", facility_id, types.counts.MaxFacilityArrayNum)
    return Facility[facility_id]
end

local function reactor(reactor_id)
    bounded("reactor_id", reactor_id, types.counts.MaxReactorNum)
    return Reactor[reactor_id]
end

local function weapon(weapon_id)
    bounded("weapon_id", weapon_id, types.counts.MaxWeaponNum)
    return Weapon[weapon_id]
end

local function chassis(chassis_id)
    bounded("chassis_id", chassis_id, types.counts.MaxChassisNum)
    return Chassis[chassis_id]
end

local function proto(unit_id)
    bounded("unit_id", unit_id, types.counts.MaxProtoNum)
    return Units[unit_id]
end

local function proto_offense_value(unit_id)
    return weapon(proto(unit_id).weapon_id).offense_value
end

local function proto_defense_value(unit_id)
    return Armor[proto(unit_id).armor_id].defense_value
end

local function proto_speed(unit_id)
    return chassis(proto(unit_id).chassis_id).speed
end

-- Production/plans port, first slice (porting-order item 3,
-- IMPLEMENTATION_DETAILS.md 4.7): re-ports more of UNIT's inline methods
-- (engine_veh.h) the same way proto_offense_value/proto_defense_value/
-- proto_speed already do -- one-liners over the tables already exposed
-- above. Kept here rather than a separate module: tech.lua already owns
-- every CChassis/CWeapon/UNIT accessor these need.
local function proto_is_missile(unit_id)
    return chassis(proto(unit_id).chassis_id).missile ~= 0
end

local function proto_is_planet_buster(unit_id)
    local u = proto(unit_id)
    if u.plan == types.enums.PLAN_PLANET_BUSTER then
        return u.reactor_id
    end
    return 0
end

local function proto_is_psi_unit(unit_id)
    return proto_offense_value(unit_id) < 0
end

local function proto_is_colony(unit_id)
    return proto(unit_id).plan == types.enums.PLAN_COLONY
end

local function proto_is_prototyped(unit_id)
    return bit.band(proto(unit_id).unit_flags, types.enums.UNIT_PROTOTYPED) ~= 0
end

local function proto_triad(unit_id)
    return chassis(proto(unit_id).chassis_id).triad
end

local function proto_range(unit_id)
    return chassis(proto(unit_id).chassis_id).range
end

-- select_build itself (porting-order item 3, final piece,
-- IMPLEMENTATION_DETAILS.md 4.10.1), step 1: more UNIT inline methods
-- (engine_veh.h:462-478/446-457) that VEH's own is_*()/is_garrison_unit()
-- delegate to, needed by the vehicle-count loop in select_build.
local function proto_is_former(unit_id)
    return proto(unit_id).plan == types.enums.PLAN_TERRAFORM
end

local function proto_is_probe(unit_id)
    return proto(unit_id).plan == types.enums.PLAN_PROBE
end

local function proto_is_supply(unit_id)
    return proto(unit_id).plan == types.enums.PLAN_SUPPLY
end

local function proto_is_transport(unit_id)
    return proto(unit_id).plan == types.enums.PLAN_NAVAL_TRANSPORT
end

local function proto_is_artifact(unit_id)
    return proto(unit_id).plan == types.enums.PLAN_ARTIFACT
end

local function proto_is_combat_unit(unit_id)
    return proto_offense_value(unit_id) ~= 0
end

local function proto_is_armored(unit_id)
    return proto_defense_value(unit_id) ~= 1
end

local function proto_is_garrison_unit(unit_id)
    local u = proto(unit_id)
    return (u.plan <= types.enums.PLAN_RECON
        or (u.plan == types.enums.PLAN_PROBE and proto_is_armored(unit_id)))
        and proto_triad(unit_id) == types.enums.TRIAD_LAND
end

-- combat_move port, sub-stage A (IMPLEMENTATION_DETAILS.md 4.15):
-- stack_search's own weapon_mode() check and veh_base_check's own
-- is_police_unit() check (engine_veh.h:459-461/416-418) -- both are
-- UNIT-level (prototype) methods VEH's own weapon_mode()/is_police_unit()
-- purely delegate to (engine_veh.h:568-569/601-603), same tier as
-- proto_is_garrison_unit above.
local function proto_weapon_mode(unit_id)
    return weapon(proto(unit_id).weapon_id).mode
end

local function proto_is_police_unit(unit_id)
    return proto(unit_id).plan <= types.enums.PLAN_RECON
        and proto_triad(unit_id) ~= types.enums.TRIAD_SEA
end

-- proto_offense/proto_defense (src/veh.cpp:3166-3182) are *not* the same
-- computation as proto_offense_value/proto_defense_value above (those are
-- UNIT::offense_value()/defense_value(), the raw weapon/armor field with
-- no reactor multiplier) -- these apply the reactor multiplier and a
-- planet-buster special case. Different functions, same name pattern.
local function proto_offense(unit_id)
    local u = proto(unit_id)
    local atk_val = weapon(u.weapon_id).offense_value
    if proto_is_planet_buster(unit_id) ~= 0 then
        return atk_val * u.reactor_id
    end
    if funcs.ignore_reactor_power() ~= 0 or atk_val < 0 then
        return atk_val * types.enums.REC_FISSION
    end
    return atk_val * u.reactor_id
end

local function proto_defense(unit_id)
    local u = proto(unit_id)
    local def_val = Armor[u.armor_id].defense_value
    if funcs.ignore_reactor_power() ~= 0 or def_val < 0 then
        return def_val * types.enums.REC_FISSION
    end
    return def_val * u.reactor_id
end

-- combat_move port, sub-stage D (IMPLEMENTATION_DETAILS.md 4.15):
-- VEH::reactor_type() (engine_veh.h:535-538), the artillery-loop damage
-- normalizer -- pure delegation over reactor_id, same tier as
-- proto_speed/proto_offense_value above.
local function proto_reactor_type(unit_id)
    return math.min(4, math.max(1, proto(unit_id).reactor_id))
end

-- TechOwners is a bitfield byte per tech_id, one bit per faction slot
-- (MaxPlayerNum=8 fits exactly in a uint8_t).
local function owners(tech_id)
    bounded("tech_id", tech_id, types.counts.MaxTechnologyNum)
    return TechOwners[tech_id]
end

return {
    get = get,
    facility = facility,
    reactor = reactor,
    weapon = weapon,
    chassis = chassis,
    proto = proto,
    proto_offense_value = proto_offense_value,
    proto_defense_value = proto_defense_value,
    proto_speed = proto_speed,
    proto_is_missile = proto_is_missile,
    proto_is_planet_buster = proto_is_planet_buster,
    proto_is_psi_unit = proto_is_psi_unit,
    proto_is_colony = proto_is_colony,
    proto_is_prototyped = proto_is_prototyped,
    proto_triad = proto_triad,
    proto_range = proto_range,
    proto_is_former = proto_is_former,
    proto_is_probe = proto_is_probe,
    proto_is_supply = proto_is_supply,
    proto_is_transport = proto_is_transport,
    proto_is_artifact = proto_is_artifact,
    proto_is_combat_unit = proto_is_combat_unit,
    proto_is_armored = proto_is_armored,
    proto_is_garrison_unit = proto_is_garrison_unit,
    proto_weapon_mode = proto_weapon_mode,
    proto_is_police_unit = proto_is_police_unit,
    proto_offense = proto_offense,
    proto_defense = proto_defense,
    proto_reactor_type = proto_reactor_type,
    owners = owners,
    rules = function() return Rules[0] end,
    recycling_tanks = function()
        return { nutrient = ResInfoRecyclingTanks[0], mineral = ResInfoRecyclingTanks[1],
            energy = ResInfoRecyclingTanks[2] }
    end,
    has_tech = funcs.has_tech,
    tech_level = funcs.tech_level,
    tech_is_preq = funcs.tech_is_preq,
    mod_tech_avail = funcs.mod_tech_avail,
    revised_tech_cost = funcs.revised_tech_cost,
    tech_balance_enabled = funcs.tech_balance_enabled,
}
