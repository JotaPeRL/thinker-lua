-- LuaHostApi binding (IMPLEMENTATION_PLAN.md Phase 3.1). Unlike
-- lua/ffi/types.lua (generated, mirrors opaque engine memory), this cdef
-- is small and hand-written: LuaHostApi is a type we fully control
-- (defined in src/luaai.h), not a projection of an engine struct.
--
-- src/luaai.cpp pushes a `LuaHostApi*` as a lightuserdata global
-- (`__host_api_ptr`) before loading init.lua. Call dofile on this file
-- exactly once per Lua state (the ffi.cdef below can only run once).
ffi.cdef[[
typedef struct {
    uint32_t api_version;
    int32_t (*rand_game)(int32_t value);
    int32_t (*rand_map)(int32_t low, int32_t high);
} LuaHostApi;
]]

local HOST_API_VERSION = 1

local api = ffi.cast("LuaHostApi*", __host_api_ptr)
assert(api.api_version == HOST_API_VERSION, string.format(
    "LuaHostApi version mismatch: host is %d, lua/ffi/funcs.lua expects %d",
    api.api_version, HOST_API_VERSION))

return {
    rand_game = function(value) return api.rand_game(value) end,
    rand_map = function(low, high) return api.rand_map(low, high) end,
}
