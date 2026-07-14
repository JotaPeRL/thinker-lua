-- BASE accessors + the base-domain host-API wrappers (porting-order item 3,
-- first slice: unit_score/find_proto, IMPLEMENTATION_PLAN.md Phase 3.2/4,
-- IMPLEMENTATION_DETAILS.md 4.7). Deliberately minimal, same discipline as
-- lua/api/map.lua/faction.lua: only the fields that slice's dependency
-- chain reads, not the whole struct.
--
-- Bases[] is a mutable, re-pointable pointer (unlike Factions/MFactions,
-- which are fixed addresses baked into `types.globals` -- IMPLEMENTATION_
-- DETAILS.md 3.2, same category as Vehs). get() re-fetches the current
-- pointer via the host API on every call instead of caching a single
-- ffi.cast the way faction.lua/tech.lua do for fixed globals, so a
-- re-point is always seen.
local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local faction = dofile("lua/api/faction.lua")

local BaseCount = ffi.cast("int32_t*", types.globals.BaseCount)

local function get(base_id)
    assert(base_id >= 0 and base_id < types.counts.MaxBaseNum,
        "base_id out of range: " .. tostring(base_id))
    local Bases = ffi.cast("BASE*", funcs.bases_ptr())
    return Bases[base_id]
end

local function count()
    return BaseCount[0]
end

-- BASE inline methods dropped by field-only cdef generation
-- (engine_base.h), re-ported the same way tech.lua's proto_* helpers
-- re-port UNIT's.
local function plr_owner(base)
    return funcs.is_human(base.faction_id)
end

-- AI bases are not limited by any governor settings (engine_base.h:248).
local function gov_config(base)
    if funcs.is_human(base.faction_id) then
        return base.governor_flags
    end
    return 0xffffffff
end

-- engine_base.h:294-296. Takes base_id (not the BASE cdata) since
-- has_fac_built needs it too.
local function se_police(base_id, pending)
    local base = get(base_id)
    local f = faction.get(base.faction_id)
    local value = (pending ~= 0) and f.SE_police_pending or f.SE_police
    if funcs.has_fac_built(types.enums.FAC_BROOD_PIT, base_id) ~= 0 then
        value = value + 2
    end
    return value
end

return {
    get = get,
    count = count,
    plr_owner = plr_owner,
    gov_config = gov_config,
    se_police = se_police,
    has_fac_built = funcs.has_fac_built,
}
