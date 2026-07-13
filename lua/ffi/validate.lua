-- Startup layout validation (IMPLEMENTATION_PLAN.md Phase 3.1). Loads the
-- generated cdefs and asserts every sizeof/alignof/offsetof value gen_ffi
-- computed against what LuaJIT's own ffi.* reports for the *actual*
-- mingw-compiled struct layout inside this thinker.dll. A mismatch means
-- gen_ffi (built with a different, native host compiler) disagrees with
-- the real target build -- raising here routes through the same
-- lua_ai_init error path as any other init failure (src/luaai.cpp), so
-- Lua AI simply refuses to enable rather than risk misreading engine
-- memory.
--
-- Registers the cdefs as a side effect of dofile (ffi.cdef can only run
-- once per struct name per Lua state) -- call this exactly once, from
-- init.lua, not from every module that needs the struct/global tables.
local types = dofile("lua/ffi/types.lua")

for _, v in ipairs(types.validation) do
    local actual
    if v.check == "sizeof" then
        actual = ffi.sizeof(v.struct)
    elseif v.check == "alignof" then
        actual = ffi.alignof(v.struct)
    elseif v.check == "offsetof" then
        actual = ffi.offsetof(v.struct, v.field)
    else
        error("unknown validation check: " .. tostring(v.check))
    end
    assert(actual == v.expected, string.format(
        "ffi layout mismatch: %s%s %s expected %d, got %s",
        v.struct, v.field and ("." .. v.field) or "", v.check,
        v.expected, tostring(actual)))
end

return types
