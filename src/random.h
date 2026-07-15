#pragma once

#include "main.h"

uint32_t game_rand_state();
void game_rand_restore(uint32_t saved);
int32_t game_randv(int32_t value);
void random_reseed(uint32_t value);
uint32_t pair_hash(uint32_t a, uint32_t b);
uint32_t random_state();
int32_t random(int32_t limit);
int32_t random_get(int32_t low, int32_t high);

// Phase 5.3.5 determinism diagnostics: cheap, always-incrementing draw
// counters (never reset), one per RNG stream. Not a state snapshot -- a
// running count of how many times each stream has been drawn from since
// process start, so two runs' logs can be diffed to find the first turn/
// faction where a *count* diverges, without needing the actual random
// values to differ yet (a divergence here always precedes -- and often
// far predates -- a visible state_hash mismatch). See
// IMPLEMENTATION_DETAILS.md 5.3.5.
extern uint32_t g_mod_rng_draws;   // random()/random_get(), this file
extern uint32_t g_game_rand_draws; // game_randv(), the engine's own RNG
extern uint32_t g_map_rand_draws;  // GameRandom::get*(), below (map_rand)

class GameRandom {
    private:
    uint32_t state = 0;
    public:
    void reseed(uint32_t value);
    uint32_t get_state();
    int32_t get(int32_t limit);
    int32_t get(int32_t low, int32_t high);
    MAP* pick_tile(int dy, int& x, int& y);
};
extern GameRandom map_rand;

template <class T, class C>
const T& pick_random(const std::set<T,C>& s) {
    auto it = std::begin(s);
    std::advance(it, random(s.size()));
    return *it;
}

template <class T>
const T& pick_random(const std::set<T>& s) {
    auto it = std::begin(s);
    std::advance(it, random(s.size()));
    return *it;
}

#ifdef BUILD_DEBUG
uint64_t hash64(const void* input, size_t len, uint64_t seed);
uint32_t hash32(const void* input, size_t len, uint64_t seed);
#endif

