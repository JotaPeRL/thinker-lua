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

-- engine_base.h:221-229. Currently-building item: >=0 is a unit_id,
-- negative is -facility_id (or a secret-project sentinel below
-- -SP_ID_First).
local function item(base)
    return base.queue_items[0]
end

local function item_is_project(base)
    return base.queue_items[0] <= -types.enums.SP_ID_First
end

local function item_is_unit(base)
    return base.queue_items[0] >= 0
end

-- engine_base.h:230-234. select_build itself, facility-branch catalog
-- continued (IMPLEMENTATION_DETAILS.md 4.10.18): the shared FAC_
-- RECREATION_COMMONS/FAC_HOLOGRAM_THEATRE/FAC_RESEARCH_HOSPITAL/
-- FAC_PARADISE_GARDEN branch's drone_riots local
-- (build.cpp:877, `base->drone_riots() || base->drone_riots_active()`).
local function drone_riots_active(base)
    return bit.band(base.state_flags, types.enums.BSTATE_DRONE_RIOTS_ACTIVE) ~= 0
end

local function drone_riots(base)
    return base.drone_total > base.talent_total
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

-- select_build itself, unit-branch catalog continued (IMPLEMENTATION_
-- DETAILS.md 4.10.29): FormerUnit's own tile-quality tally
-- (build.cpp:1157-1166), a two-int32_t*-out-param host wrapper -- same
-- ffi.new-array-as-out-buffer shape as faction.lua's psych_check.
local function former_tile_tally(base_id)
    local out = ffi.new("int32_t[2]")
    funcs.former_tile_tally(base_id, out, out + 1)
    return { num = out[0], sea = out[1] }
end

return {
    get = get,
    count = count,
    plr_owner = plr_owner,
    gov_config = gov_config,
    item = item,
    item_is_project = item_is_project,
    item_is_unit = item_is_unit,
    drone_riots_active = drone_riots_active,
    drone_riots = drone_riots,
    se_police = se_police,
    has_fac_built = funcs.has_fac_built,
    former_tile_tally = former_tile_tally,
    -- Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12):
    -- artifact_move's own dependency (base.cpp:4866), a plain read query.
    can_link_artifact = funcs.can_link_artifact,
}
