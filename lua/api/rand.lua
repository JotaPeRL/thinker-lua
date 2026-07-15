-- Sanctioned RNG bindings (IMPLEMENTATION_PLAN.md / IMPLEMENTATION_DETAILS.md
-- 3.5). `math.random`/`math.randomseed` raise in this runtime
-- (src/luaai.cpp) specifically to force AI code through these instead:
-- both draw from the engine's own RNG streams, so decisions stay
-- reproducible turn-for-turn like the C++ AI.
--
-- rand.game(n): the main engine stream (game_randv, 0..n-1).
-- rand.map(low, high): the mod's own LCG (random_get), used by mapgen and
-- some AI planning.
local funcs = dofile_once("lua/ffi/funcs.lua")

return {
    game = funcs.rand_game,
    map = funcs.rand_map,
    -- Phase 5.3.5 determinism diagnostics (IMPLEMENTATION_DETAILS.md):
    -- read-only peeks, never consume their stream (unlike game/map above).
    game_state = funcs.game_rand_state,
    mod_state = funcs.mod_rand_state,
    map_state = funcs.map_rand_state,
    game_draws = funcs.game_rand_draws,
    mod_draws = funcs.mod_rng_draws,
    map_draws = funcs.map_rng_draws,
}
