#include "autoplay.h"
#include "main.h"

#include <cstdio>
#include <cstdarg>
#include <cstring>

// Dedicated always-on log file, same rationale as lua.log (IMPLEMENTATION_
// DETAILS.md 2.6): autoplay is meant to be usable in non-debug builds too,
// so it can't rely on debug()/debug.txt (no-op outside BUILD_DEBUG).
void autoplay_logf(const char* fmt, ...) {
    static FILE* f = fopen("autoplay.log", "a");
    if (!f) {
        return;
    }
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    va_end(args);
    fflush(f);
}

void autoplay_demote_human() {
    if (!conf.autoplay) {
        return;
    }
    // MPREF_AUTO_ALWAYS_INSPECT_MONOLITH already exists as a real Preferences-
    // screen checkbox (engine_enums.h) that mod_monolith (veh.cpp:1031/1041)
    // checks before showing the "MONOLITH"/"SEEMONOLITH" popups -- belt and
    // suspenders alongside the human-bit clear below, since that popup is
    // additionally gated on is_human() and demotion should already prevent it.
    *GameMorePreferences |= MPREF_AUTO_ALWAYS_INSPECT_MONOLITH;
    int faction_id = *CurrentPlayerFaction;
    if (faction_id > 0 && faction_id < MaxPlayerNum && (FactionStatus[0] & (1 << faction_id))) {
        FactionStatus[0] &= ~(1 << faction_id);
        autoplay_logf("demoted faction %d (%s) from human to Thinker AI control\n",
            faction_id, MFactions[faction_id].filename);
    }
}

// EXPERIMENTAL, unverified: thinker_enabled()/is_human() (cleared above)
// only gate Thinker's own AI decision-making. Whether the game's own UI
// loop sits waiting for a manual End Turn click appears to be a *separate*
// mechanism -- confirmed by testing: even after demotion, End Turn still
// had to be pressed every turn. `Console_end_my_turn` (engine.cpp:2135,
// address 0x5169F0, __thiscall on the Console* singleton `MapWin`) is the
// closest match found by name to the button/keypress handler, but nothing
// in this codebase has ever called it before now -- its preconditions and
// safety are unconfirmed. Wired behind conf.autoplay only, called from
// mod_blink_timer (gui.cpp:519, an existing periodic UI-idle callback --
// see write_offset(0x50F3DC, mod_blink_timer) in patch.cpp -- so it can
// fire while the game is sitting idle "waiting for input", unlike
// mod_turn_upkeep which only runs once a turn has already ended). Logged
// every attempt without throttling for now, on purpose: if this crashes,
// autoplay.log's last line is the diagnostic. Try it, watch for a crash,
// report back.
void autoplay_try_end_turn() {
    if (!conf.autoplay || *GameHalted || *MultiplayerActive) {
        return;
    }
    autoplay_logf("attempting Console_end_my_turn(MapWin)\n");
    Console_end_my_turn(MapWin);
}

int __cdecl autoplay_pop2(const char* label, const char* pcx_filename, int a3) {
    if (conf.autoplay) {
        autoplay_logf("POP2 label=%s a3=%d\n", label ? label : "(null)", a3);
        return 0;
    }
    return POP2_engine(label, pcx_filename, a3);
}

int __cdecl autoplay_popp(const char* filename, const char* label, int a3, const char* pcx_filename, fp_none fn) {
    if (conf.autoplay) {
        autoplay_logf("popp filename=%s label=%s a3=%d\n",
            filename ? filename : "(null)", label ? label : "(null)", a3);
        return 0;
    }
    return popp_engine(filename, label, a3, pcx_filename, fn);
}

int __cdecl autoplay_popp_2(const char* filename, const char* label, fp_none fn) {
    if (conf.autoplay) {
        autoplay_logf("popp_2 filename=%s label=%s\n",
            filename ? filename : "(null)", label ? label : "(null)");
        return 0;
    }
    return popp_2_engine(filename, label, fn);
}

void __cdecl autoplay_interlude(int event_id, const char* text, int a3, int a4) {
    if (conf.autoplay) {
        autoplay_logf("interlude event_id=%d text=%s a3=%d a4=%d\n",
            event_id, text ? text : "(null)", a3, a4);
        return;
    }
    interlude_engine(event_id, text, a3, a4);
}

int __cdecl autoplay_x_pop_9(const char* filename, const char* label, int a3, char* a4, int a5, fp_none fn) {
    if (conf.autoplay) {
        // Confirmed by testing: the default 0 (== "no"/"cancel" for this
        // dialog) made the Quit menu's confirmation do nothing. 1 answers
        // "yes" instead. This is the one label-specific override so far --
        // exactly the "add a case" iteration the surrounding spike expects.
        if (label && !strcmp(label, "REALLYQUIT")) {
            autoplay_logf("X_pop_9 filename=%s label=%s a3=%d a5=%d -> answering yes (quit)\n",
                filename ? filename : "(null)", label, a3, a5);
            return 1;
        }
        autoplay_logf("X_pop_9 filename=%s label=%s a3=%d a5=%d\n",
            filename ? filename : "(null)", label ? label : "(null)", a3, a5);
        return 0;
    }
    return X_pop_9_engine(filename, label, a3, a4, a5, fn);
}

int __cdecl autoplay_x_pops_18(const char* filename, const char* label, int a3, char* a4, int a5, Sprite* a6, int a7, int a8, fp_none fn) {
    if (conf.autoplay) {
        autoplay_logf("X_pops_18 filename=%s label=%s a3=%d a5=%d\n",
            filename ? filename : "(null)", label ? label : "(null)", a3, a5);
        return 0;
    }
    return X_pops_18_engine(filename, label, a3, a4, a5, a6, a7, a8, fn);
}
