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

-- Bit-count of an 8-bit value (replaces C++'s __builtin_popcount usage on
-- TechOwners[tech_id] bitfields, MaxPlayerNum=8 bits).
local bit = bit
local function popcount8(byte)
    local n = 0
    for i = 0, 7 do
        if bit.band(bit.rshift(byte, i), 1) == 1 then
            n = n + 1
        end
    end
    return n
end

-- Mirrors the project's C++ `clamp(v, lo, hi)` helper (used throughout
-- the scoring code being ported).
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

return {
    idiv = idiv,
    imod = imod,
    popcount8 = popcount8,
    clamp = clamp,
}
