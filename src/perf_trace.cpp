#include "main.h"
#include "perf_trace.h"
#include <cstdio>

static double g_perf_totals_ms[PERF_PHASE_COUNT] = {};

PerfScope::PerfScope(PerfPhase phase) : phase_(phase), active_(conf.perf_trace != 0) {
    if (active_) {
        start_ = std::chrono::high_resolution_clock::now();
    }
}

PerfScope::~PerfScope() {
    if (active_) {
        auto end = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(end - start_).count();
        g_perf_totals_ms[phase_] += ms;
    }
}

// Lazily opened, kept open for the process lifetime -- appended to, same
// "grow across sessions" convention as golden_traces.jsonl.
static FILE* perf_trace_log_file = NULL;

static FILE* perf_trace_file() {
    if (!perf_trace_log_file) {
        perf_trace_log_file = fopen("perf_trace.log", "a");
    }
    return perf_trace_log_file;
}

void perf_trace_log_turn(int turn) {
    if (!conf.perf_trace) {
        return;
    }
    FILE* f = perf_trace_file();
    if (f) {
        fprintf(f,
            "perf_turn %d production_ms=%.3f movement_plan_ms=%.3f "
            "movement_dispatch_ms=%.3f base_upkeep_ms=%.3f\n",
            turn,
            g_perf_totals_ms[PERF_PRODUCTION],
            g_perf_totals_ms[PERF_MOVEMENT_PLAN],
            g_perf_totals_ms[PERF_MOVEMENT_DISPATCH],
            g_perf_totals_ms[PERF_BASE_UPKEEP]);
        fflush(f);
    }
    for (int i = 0; i < PERF_PHASE_COUNT; i++) {
        g_perf_totals_ms[i] = 0;
    }
}
