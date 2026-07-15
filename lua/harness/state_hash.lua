-- Per-turn state-hash dump for the autoplay determinism harness
-- (IMPLEMENTATION_PLAN.md "Consolidation gate (2026-07-14)" item a;
-- Phase 5.3's "State hash: end-of-turn Lua script iterating factions/
-- bases/vehs writing one line per turn to a hash log"). Not an AI
-- decision hook -- there is nothing to propose or fall back on here --
-- but it is wired through the same lua_ai_hook dispatch that
-- lua/ai/build.lua's vehicle_counts_check already established as the way
-- to get a Lua function called from a C++ seam with zero new host-API
-- plumbing (src/game.cpp's mod_turn_upkeep calls it once per turn, right
-- after the lazy Lua init, i.e. before this turn's own processing has
-- touched anything -- so this is exactly "end of the previous turn").
--
-- tools/autoplay_run.sh's progress watchdog tails lua.log for this line:
-- a new turn number resets its stall timer. The hash itself only needs
-- to be internally consistent (same Lua code, same inputs -> same
-- output) for "two runs with the same seed produce identical files" --
-- there's no C++ reference hash to match bit-for-bit against, unlike the
-- dual-run mismatch checks elsewhere in lua/ai/.
--
-- Folds in unit positions, base count/locations and per-faction
-- tech/energy, all read in index order (0..count-1 / 1..MaxPlayerNum-1),
-- never pairs() -- IMPLEMENTATION_PLAN.md's "no decision may depend on
-- Lua hash-table iteration order" rule, applied here too even though
-- this isn't a decision: a nondeterministic hash would defeat the
-- harness's whole purpose of catching real divergences.
local types = dofile_once("lua/ffi/validate.lua")
local faction = dofile("lua/api/faction.lua")
local base = dofile("lua/api/base.lua")
local veh = dofile("lua/api/veh.lua")
local log = dofile("lua/api/log.lua")
local rand = dofile("lua/api/rand.lua")

-- FNV-1a-style mix using only exact bitwise ops (bxor/rol) -- deliberately
-- not a multiplicative hash, to avoid floating-point precision loss on
-- values approaching 2^53 (Lua numbers are doubles; bit.* truncates its
-- result to a 32-bit signed integer exactly, a plain multiply would not).
local function mix(h, v)
    return bit.bxor(bit.rol(h, 7), v)
end

local function dump(turn)
    local h = bit.tobit(0x811c9dc5) -- FNV-1a 32-bit offset basis

    local base_count = base.count()
    h = mix(h, base_count)
    for base_id = 0, base_count - 1 do
        local b = base.get(base_id)
        h = mix(h, b.faction_id)
        h = mix(h, b.x)
        h = mix(h, b.y)
    end

    local veh_count = veh.count()
    h = mix(h, veh_count)
    for veh_id = 0, veh_count - 1 do
        local v = veh.get(veh_id)
        h = mix(h, v.faction_id)
        h = mix(h, v.x)
        h = mix(h, v.y)
        h = mix(h, v.unit_id)
    end

    for faction_id = 1, types.counts.MaxPlayerNum - 1 do
        local f = faction.get(faction_id)
        h = mix(h, f.tech_ranking)
        h = mix(h, f.energy_credits)
        h = mix(h, f.base_count)
    end

    -- Phase 5.3.5 determinism diagnostics (IMPLEMENTATION_DETAILS.md):
    -- RNG *states*, not folded into the hash above -- a different signal,
    -- deliberately kept separate and visible, so the first turn where
    -- these diverge between two runs (while the hash above still matches)
    -- is directly readable from state_hashes.log, without needing to
    -- correlate against debug.txt's per-faction draw counts first.
    local rng = string.format("%08x:%08x:%08x",
        rand.game_state(), rand.mod_state(), rand.map_state())

    log.debug("state_hash turn=%d bases=%d vehs=%d hash=%s rng=%s",
        turn, base_count, veh_count, bit.tohex(h), rng)
    return 0
end

return { dump = dump }
