-- C integer division/modulo semantics (IMPLEMENTATION_PLAN.md /
-- IMPLEMENTATION_DETAILS.md 3.1/3.7). C truncates toward zero; Lua's
-- native `/` and `%` floor. The ported scoring code is full of integer
-- arithmetic on values that can go negative, so this divergence is
-- silent unless routed through here -- bare `/` and `%` are banned on
-- integers in lua/ai/ (enforced by review + a future luacheck lint pass,
-- Phase 4.4).
local function idiv(a, b)
    local q = a / b
    return q >= 0 and math.floor(q) or math.ceil(q)
end

local function imod(a, b)
    return a - idiv(a, b) * b
end

return {
    idiv = idiv,
    imod = imod,
}
