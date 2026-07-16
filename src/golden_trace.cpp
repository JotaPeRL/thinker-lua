#include "main.h"
#include "golden_trace.h"
#include "random.h"

// Lazily opened, kept open for the process lifetime -- appended to, not
// truncated (unlike lua_log's per-VM-init "w"), so a fixture corpus can
// grow across multiple sessions/games instead of only capturing one run.
// tools/autoplay_run.sh's stale-log cleanup deliberately does not delete
// this file, for the same reason.
static FILE* golden_trace_log = NULL;

static FILE* golden_trace_file() {
    if (!golden_trace_log) {
        golden_trace_log = fopen("golden_traces.jsonl", "a");
    }
    return golden_trace_log;
}

void golden_trace_facility_score(int item_id,
        int wgov_growth, int wgov_tech, int wgov_wealth, int wgov_power, int wgov_fight,
        int p_growth, int p_tech, int p_wealth, int p_power, int p_fight,
        int result) {
    if (!conf.golden_trace) {
        return;
    }
    FILE* f = golden_trace_file();
    if (!f) {
        return;
    }
    uint32_t rng = game_rand_state();
    fprintf(f,
        "{\"function\":\"facility_score\","
        "\"args\":{\"item_id\":%d,\"AI_growth\":%d,\"AI_tech\":%d,\"AI_wealth\":%d,\"AI_power\":%d,\"AI_fight\":%d},"
        "\"observed_state\":{\"p\":{\"AI_growth\":%d,\"AI_tech\":%d,\"AI_wealth\":%d,\"AI_power\":%d,\"AI_fight\":%d}},"
        "\"result\":{\"value\":%d},"
        "\"rng_before\":%u,\"rng_after\":%u}\n",
        item_id, wgov_growth, wgov_tech, wgov_wealth, wgov_power, wgov_fight,
        p_growth, p_tech, p_wealth, p_power, p_fight,
        result, rng, rng);
    fflush(f);
}

void golden_trace_governor_priorities(int base_id,
        int governor_flags, int defend_goal, int faction_id, int is_human,
        int f_growth, int f_tech, int f_wealth, int f_power, int f_fight,
        int result_growth, int result_tech, int result_wealth, int result_power, int result_fight) {
    if (!conf.golden_trace) {
        return;
    }
    FILE* f = golden_trace_file();
    if (!f) {
        return;
    }
    uint32_t rng = game_rand_state();
    fprintf(f,
        "{\"function\":\"governor_priorities\","
        "\"args\":{\"base_id\":%d},"
        "\"observed_state\":{"
            "\"base\":{\"governor_flags\":%d,\"defend_goal\":%d,\"faction_id\":%d,\"is_human\":%d},"
            "\"faction\":{\"AI_growth\":%d,\"AI_tech\":%d,\"AI_wealth\":%d,\"AI_power\":%d,\"AI_fight\":%d}},"
        "\"result\":{\"AI_growth\":%d,\"AI_tech\":%d,\"AI_wealth\":%d,\"AI_power\":%d,\"AI_fight\":%d},"
        "\"rng_before\":%u,\"rng_after\":%u}\n",
        base_id,
        governor_flags, defend_goal, faction_id, is_human,
        f_growth, f_tech, f_wealth, f_power, f_fight,
        result_growth, result_tech, result_wealth, result_power, result_fight,
        rng, rng);
    fflush(f);
}
