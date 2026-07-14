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
    owners = owners,
    rules = function() return Rules[0] end,
    has_tech = funcs.has_tech,
    tech_level = funcs.tech_level,
    tech_is_preq = funcs.tech_is_preq,
    mod_tech_avail = funcs.mod_tech_avail,
    revised_tech_cost = funcs.revised_tech_cost,
    tech_balance_enabled = funcs.tech_balance_enabled,
}
