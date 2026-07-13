-- Deliberately minimal (IMPLEMENTATION_PLAN.md Phase 3.2, narrowed to the
-- tech-AI pilot): bad_reg is the only map-domain dependency
-- mod_tech_val/mod_tech_ai has. Real tile/veh/base access (map.tile,
-- map.iter_near, ...) is Phase 4's movement/goal work, on demand.
local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")

local Continents = ffi.cast("Continent*", types.globals.Continents)

local function continent(region)
    assert(region >= 0 and region < types.counts.MaxRegionNum,
        "region out of range: " .. tostring(region))
    return Continents[region]
end

return {
    continent = continent,
    bad_reg = funcs.bad_reg,
}
