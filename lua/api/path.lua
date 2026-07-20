-- Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12): the first
-- path-domain wrapper (IMPLEMENTATION_PLAN.md Phase 3.2 planned this as
-- its own module, built on demand). TileSearch itself stays entirely in
-- C++ (Phase 4.3) -- search_route constructs and discards its own local
-- TileSearch on the host side; only the result (found/tx/ty) crosses
-- into Lua.
local funcs = dofile_once("lua/ffi/funcs.lua")

-- x/y seed the search (the vehicle's current position) -- tx/ty in the
-- returned table equal x/y unchanged if no route was found.
local function search_route(veh_id, x, y)
    local out = ffi.new("int32_t[3]")
    funcs.search_route(veh_id, x, y, out, out + 1, out + 2)
    return { found = out[0] ~= 0, tx = out[1], ty = out[2] }
end

return {
    search_route = search_route,
}
