-- Golden-trace replay runner (IMPLEMENTATION_PLAN.md Phase 5.2,
-- Consolidation gate item c). Replays fixtures captured by
-- src/golden_trace.cpp (golden_trace=1) through the *real* Lua port,
-- under Arch's native luajit -- no engine, no Wine, no live game needed.
-- See IMPLEMENTATION_DETAILS.md 5.2.1 for the fixture-backed api/
-- substitution this relies on and why it's necessary (native luajit has
-- no access to the embedded 32-bit-Windows process's memory or LuaHostApi
-- at all).
--
-- Usage: luajit tools/golden_trace_replay.lua <path-to-golden_traces.jsonl>
-- Exit code: 0 if every record passes (or the file is empty), 1 on any
-- mismatch, unreadable file, or malformed line.

local path = arg[1]
if not path then
    io.stderr:write("usage: luajit tools/golden_trace_replay.lua <golden_traces.jsonl>\n")
    os.exit(1)
end

-- ---------------------------------------------------------------------
-- Minimal JSON parser: object/string/number/true/false/null only -- the
-- fixture writer (src/golden_trace.cpp) never emits arrays or anything
-- this schema doesn't need, and no JSON library exists anywhere in this
-- repo (checked: no FetchContent/find_package in CMakeLists.txt).
-- ---------------------------------------------------------------------
local function parse_json(s)
    local pos = 1
    local parse_value

    local function skip_ws()
        local _, e = s:find("^%s*", pos)
        pos = e + 1
    end

    local function fail(msg)
        error(string.format("json parse error at byte %d: %s (near %q)",
            pos, msg, s:sub(pos, pos + 20)))
    end

    local function parse_string()
        pos = pos + 1 -- opening quote
        local start = pos
        local out = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then fail("unterminated string") end
            if c == '"' then
                table.insert(out, s:sub(start, pos - 1))
                pos = pos + 1
                break
            elseif c == "\\" then
                table.insert(out, s:sub(start, pos - 1))
                local esc = s:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t" }
                table.insert(out, map[esc] or esc)
                pos = pos + 2
                start = pos
            else
                pos = pos + 1
            end
        end
        return table.concat(out)
    end

    local function parse_number()
        local start = pos
        local _, e = s:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        pos = e + 1
        return tonumber(s:sub(start, e))
    end

    local function parse_object()
        pos = pos + 1 -- opening brace
        local obj = {}
        skip_ws()
        if s:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            if s:sub(pos, pos) ~= '"' then fail("expected string key") end
            local key = parse_string()
            skip_ws()
            if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
            pos = pos + 1
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            local c = s:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                break
            else
                fail("expected ',' or '}'")
            end
        end
        return obj
    end

    parse_value = function()
        skip_ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            return parse_object()
        elseif c == '"' then
            return parse_string()
        elseif s:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif s:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif s:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        elseif c:match("[%-%d]") then
            return parse_number()
        else
            fail("unexpected character")
        end
    end

    skip_ws()
    local value = parse_value()
    return value
end

-- ---------------------------------------------------------------------
-- Fixture-backed api/ substitution. lua/ai/build.lua loads its module
-- dependencies via plain dofile(path) at file scope -- this project
-- never uses require (lua/init.lua: package stays disabled outside
-- debug builds) -- so overriding the global `dofile` before loading
-- build.lua intercepts every one of those calls. Only lua/api/base.lua,
-- lua/api/faction.lua, lua/api/tech.lua are fixture-backed -- the three
-- facility_score/governor_priorities actually call into. Everything else
-- build.lua also dofiles at module scope, for *other* functions this
-- runner never calls, gets a trivial empty-table stub -- except
-- lua/api/cmath.lua, loaded for real: it's pure Lua using only LuaJIT's
-- built-in `bit` library, no ffi/host dependency, so no reason to fake
-- it. lua/ffi/validate.lua is the one stub that can't be trivially
-- empty: `local E = types.enums` (build.lua) is evaluated at module
-- load, and governor_priorities indexes E.GOV_PRIORITY_* unconditionally
-- on the is_human branch -- an empty stub crashes on first replay call.
-- Real values hand-copied from engine_base.h / lua/ffi/types.lua (gen_ffi
-- output); these are stable engine constants, not expected to change.
local current = {} -- mutable fixture backing table, replaced per record

local ENUMS = {
    GOV_PRIORITY_EXPLORE = 0x1000000,
    GOV_PRIORITY_DISCOVER = 0x2000000,
    GOV_PRIORITY_BUILD = 0x4000000,
    GOV_PRIORITY_CONQUER = 0x8000000,
}

local STUBS = {
    ["lua/ffi/validate.lua"] = function() return { enums = ENUMS } end,
    ["lua/ffi/funcs.lua"] = function() return {} end,
    ["lua/api/game.lua"] = function() return {} end,
    ["lua/api/rand.lua"] = function() return {} end,
    ["lua/api/veh.lua"] = function() return {} end,
    ["lua/api/base.lua"] = function()
        return { get = function() return current.base end }
    end,
    ["lua/api/faction.lua"] = function()
        return {
            get = function() return current.faction end,
            is_human = function() return current.base.is_human ~= 0 end,
        }
    end,
    ["lua/api/tech.lua"] = function()
        return { facility = function() return current.p end }
    end,
}

local real_dofile = dofile
local memoized = {}
function dofile_once(p)
    if memoized[p] == nil then
        memoized[p] = dofile(p)
    end
    return memoized[p]
end
dofile = function(p)
    local stub = STUBS[p]
    if stub then
        return stub()
    end
    return real_dofile(p)
end

local port = dofile("lua/ai/build.lua")
dofile = real_dofile -- restore; nothing past this point should need the override

-- ---------------------------------------------------------------------
-- Replay
-- ---------------------------------------------------------------------
local total, failed = 0, 0

local function replay_facility_score(rec)
    current.p = rec.observed_state.p
    local wgov = {
        AI_growth = rec.args.AI_growth, AI_tech = rec.args.AI_tech,
        AI_wealth = rec.args.AI_wealth, AI_power = rec.args.AI_power,
        AI_fight = rec.args.AI_fight,
    }
    local result = port.facility_score(rec.args.item_id, wgov)
    total = total + 1
    if result == rec.result.value then
        print(string.format("PASS facility_score(item_id=%d) = %d", rec.args.item_id, result))
    else
        failed = failed + 1
        print(string.format("FAIL facility_score(item_id=%d): expected %d, got %d",
            rec.args.item_id, rec.result.value, result))
    end
end

local function replay_governor_priorities(rec)
    current.base = rec.observed_state.base
    current.faction = rec.observed_state.faction
    local wgov = port.governor_priorities(rec.args.base_id)
    local fields = { "AI_growth", "AI_tech", "AI_wealth", "AI_power", "AI_fight" }
    local ok = true
    for _, field in ipairs(fields) do
        if wgov[field] ~= rec.result[field] then
            ok = false
        end
    end
    total = total + 1
    if ok then
        print(string.format("PASS governor_priorities(base_id=%d)", rec.args.base_id))
    else
        failed = failed + 1
        print(string.format(
            "FAIL governor_priorities(base_id=%d): expected {%d,%d,%d,%d,%d}, got {%d,%d,%d,%d,%d}",
            rec.args.base_id,
            rec.result.AI_growth, rec.result.AI_tech, rec.result.AI_wealth,
            rec.result.AI_power, rec.result.AI_fight,
            wgov.AI_growth, wgov.AI_tech, wgov.AI_wealth, wgov.AI_power, wgov.AI_fight))
    end
end

local REPLAYERS = {
    facility_score = replay_facility_score,
    governor_priorities = replay_governor_priorities,
}

local f = io.open(path, "r")
if not f then
    io.stderr:write("error: cannot open " .. path .. "\n")
    os.exit(1)
end

local line_no = 0
for line in f:lines() do
    line_no = line_no + 1
    if line:match("%S") then
        local ok, rec_or_err = pcall(parse_json, line)
        if not ok then
            io.stderr:write(string.format("line %d: %s\n", line_no, rec_or_err))
            total = total + 1
            failed = failed + 1
        else
            local rec = rec_or_err
            local replayer = REPLAYERS[rec["function"]]
            if replayer then
                replayer(rec)
            else
                io.stderr:write(string.format(
                    "line %d: unknown function %q, skipping\n", line_no, tostring(rec["function"])))
            end
        end
    end
end
f:close()

print(string.format("%d/%d passed", total - failed, total))
os.exit(failed > 0 and 1 or 0)
