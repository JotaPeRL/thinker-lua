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
    -- Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12):
    -- artifact_move's own dependencies. base_at is a plain coordinate ->
    -- base_id lookup; safety reads mapdata (PMTable, a
    -- std::unordered_map) -- stays entirely opaque in C++ per Phase 4.3,
    -- exposed only as this one-field read.
    base_at = funcs.base_at,
    safety = funcs.map_safety,
    -- Movement port, stage 2 rework (IMPLEMENTATION_DETAILS.md 4.12):
    -- want_convoy's own dependencies. MAP* can't cross into Lua, so
    -- these substitute single-field reads for it, same tier as safety.
    tile_is_base = funcs.tile_is_base,
    tile_owner = funcs.tile_owner,
    tile_is_base_radius = funcs.tile_is_base_radius,
}
