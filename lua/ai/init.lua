-- Collects every ported module's hooks into the table src/luaai.cpp's
-- register_hooks() reads at (re)load (IMPLEMENTATION_PLAN.md Phase 4.1/
-- 4.4: "one module per domain ... registering hooks in a central table").
local tech = dofile("lua/ai/tech.lua")
local social = dofile("lua/ai/social.lua")

return {
    mod_tech_val = tech.mod_tech_val,
    mod_tech_ai = tech.mod_tech_ai,
    mod_social_ai = social.mod_social_ai,
}
