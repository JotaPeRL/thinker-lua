-- LuaHostApi binding (IMPLEMENTATION_PLAN.md Phase 3.1/3.2). Unlike
-- lua/ffi/types.lua (generated, mirrors opaque engine memory), this cdef
-- is small and hand-written: LuaHostApi is a type we fully control
-- (defined in src/luaai.h), not a projection of an engine struct.
--
-- src/luaai.cpp pushes a `LuaHostApi*` as a lightuserdata global
-- (`__host_api_ptr`) before loading init.lua. Load via dofile_once (see
-- lua/init.lua) -- the ffi.cdef below can only run once per Lua state,
-- and this file now has multiple callers (lua/api/faction.lua,
-- lua/api/tech.lua, lua/api/map.lua).
ffi.cdef[[
typedef struct {
    uint32_t api_version;
    int32_t (*rand_game)(int32_t value);
    int32_t (*rand_map)(int32_t low, int32_t high);
    bool (*is_human)(int32_t faction_id);
    int32_t (*has_treaty)(int32_t faction_id_1, int32_t faction_id_2, uint32_t status);
    int32_t (*climactic_battle)();
    int32_t (*mod_wants_to_attack)(int32_t faction_id, int32_t faction_id_tgt, int32_t faction_id_unk);
    int32_t (*has_tech)(int32_t tech_id, int32_t faction_id);
    int32_t (*tech_level)(int32_t tech_id, int32_t lvl);
    int32_t (*mod_tech_avail)(int32_t tech_id, int32_t faction_id);
    int32_t (*tech_is_preq)(int32_t preq_tech_id, int32_t parent_tech_id, int32_t range);
    int32_t (*bad_reg)(int32_t region);
} LuaHostApi;
]]

local HOST_API_VERSION = 2

local api = ffi.cast("LuaHostApi*", __host_api_ptr)
assert(api.api_version == HOST_API_VERSION, string.format(
    "LuaHostApi version mismatch: host is %d, lua/ffi/funcs.lua expects %d",
    api.api_version, HOST_API_VERSION))

return {
    rand_game = function(value) return api.rand_game(value) end,
    rand_map = function(low, high) return api.rand_map(low, high) end,
    is_human = function(faction_id) return api.is_human(faction_id) end,
    has_treaty = function(f1, f2, status) return api.has_treaty(f1, f2, status) end,
    climactic_battle = function() return api.climactic_battle() end,
    mod_wants_to_attack = function(f, tgt, unk) return api.mod_wants_to_attack(f, tgt, unk) end,
    has_tech = function(tech_id, faction_id) return api.has_tech(tech_id, faction_id) end,
    tech_level = function(tech_id, lvl) return api.tech_level(tech_id, lvl) end,
    mod_tech_avail = function(tech_id, faction_id) return api.mod_tech_avail(tech_id, faction_id) end,
    tech_is_preq = function(preq, parent, range) return api.tech_is_preq(preq, parent, range) end,
    bad_reg = function(region) return api.bad_reg(region) end,
}
