-- "Hello AI": a minimal, heavily-commented example of overriding one of
-- Thinker's Lua AI hooks. This file is NOT loaded by the game -- it exists
-- purely as a reference for modders. See the bottom of this file for the
-- one-line change that actually wires it in.
--
-- Read docs/LUA_API.md first for the full picture (layering, determinism
-- rules, hook classes). The short version needed to follow this example:
--
-- * lua/ai/init.lua returns one flat table mapping hook name -> Lua
--   function. src/luaai.cpp's register_hooks() reads that table once per
--   (re)load and resolves each entry into a registry reference; from then
--   on, the matching C++ call site invokes it directly by name.
-- * This is a "Class 1" hook: a pure query. The C++ side calls it, gets a
--   value back, and uses that value -- your Lua function must not mutate
--   any engine state (no funcs.* calls that change the game), only read
--   state and return a decision. No fallback is needed on error beyond
--   what the hook already provides, since nothing has happened yet.
-- * lua/ai/ code never requires "ffi" directly -- all engine reads go
--   through the lua/api/ wrappers (faction.lua, base.lua, veh.lua, ...),
--   which return plain Lua values/booleans/cdata with named fields.

local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local faction = dofile("lua/api/faction.lua")
local log = dofile("lua/api/log.lua")

local E = types.enums

-- The hook we're overriding: probe_choose_frame_target (ported from
-- src/probe.cpp's MOV_FRAME branch, see lua/ai/probe.lua for the original
-- 1:1 port). Signature: (veh_fc_id, tgt_fc_id) -> faction_id_to_frame, or
-- 0 to frame nobody. It runs when a probe team's action needs a "frame
-- this other faction for it" target, and picks the top-ranked human
-- faction currently in communication and not already at vendetta with the
-- target.
--
-- The original logic (lua/ai/probe.lua's probe_choose_frame_target) walks
-- every faction slot in order and only ever returns the one faction the
-- engine already tracks as top-ranked (RankingFactionIDUnk1). As a small,
-- easy-to-explain example tweak, this version instead frames the FIRST
-- eligible human faction it finds -- still deterministic (plain index
-- order, 1..MaxPlayerNum-1, never pairs()), just a different tie-break
-- rule than the original. This is meant purely to show the shape of an
-- override, not as a serious gameplay change.
local function probe_choose_frame_target(veh_fc_id, tgt_fc_id)
    local tgt = faction.get(tgt_fc_id)
    for i = 1, types.counts.MaxPlayerNum - 1 do
        if i ~= veh_fc_id and i ~= tgt_fc_id and funcs.is_human(i) and funcs.is_alive(i) ~= 0 then
            if bit.band(tgt.diplo_status[i], E.DIPLO_VENDETTA) == 0
                and bit.band(tgt.diplo_status[i], E.DIPLO_COMMLINK) ~= 0 then
                -- log.debug (lua/api/log.lua) writes to lua.log, mirrored
                -- to debug.txt on debug builds -- the normal way to make a
                -- hook's decisions visible while testing.
                log.debug("hello_ai: framing faction %d for probe by %d against %d\n",
                    i, veh_fc_id, tgt_fc_id)
                return i
            end
        end
    end
    return 0
end

return {
    probe_choose_frame_target = probe_choose_frame_target,
}

--[[
To actually enable this override, edit lua/ai/init.lua:

    local hello_ai = dofile("lua/examples/hello_ai.lua")
    ...
    return {
        ...
        probe_choose_frame_target = hello_ai.probe_choose_frame_target,
        -- (was: probe_choose_frame_target = probe.probe_choose_frame_target,)
        ...
    }

That's the entire integration surface: init.lua's returned table is the
only thing register_hooks() ever reads, so replacing one entry there is
enough to swap in any function with a matching signature -- including one
that doesn't reproduce the original C++ behavior at all, unlike every
other module under lua/ai/ (which are held to a strict 1:1 port
requirement while this project's own porting work is in progress).
--]]
