-- AI-facing logging (IMPLEMENTATION_PLAN.md Phase 2B "Logging"). Wraps the
-- raw `host_log`/`host_log_ver` globals (src/luaai.cpp) -- those write to
-- lua.log always, mirrored to debug.txt (prefixed `lua:`) when a debug
-- build has one open -- into printf-style calls so AI code never has to
-- string.format by hand.
--
-- log.debug: always written.
-- log.ver: written only when conf.debug_verbose is set (the Alt+M
-- toggle) -- checked host-side, so callers don't need to know about conf.
local function debug(fmt, ...)
    host_log(select("#", ...) > 0 and string.format(fmt, ...) or fmt)
end

local function ver(fmt, ...)
    host_log_ver(select("#", ...) > 0 and string.format(fmt, ...) or fmt)
end

return {
    debug = debug,
    ver = ver,
}
