#include "autoplay.h"
#include "main.h"
#include "gui.h"

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
    // MRULES_NO_PLANETARY_COUNCIL (a real scenario-rules flag,
    // engine_enums.h) makes can_call_council() return false unconditionally
    // (confirmed by disassembly, 0x52C695: `test byte ptr ds:0x9a681c,0x4`
    // -- 0x9a681c is GameMoreRules -- then an early `xor eax,eax; ret` when
    // set). Unlike every other autoplay fix in this file, this doesn't hide
    // a blocking UI while leaving the underlying mechanic intact -- it
    // disables Planetary Council outright (no faction ever calls/votes) for
    // the rest of the session. Deliberate tradeoff, user-confirmed
    // 2026-07-25: CouncilWindow (0x6FEC80) has none of BasePop/Popup's
    // reverse-engineering investment behind it, and autoplay_dismiss_dialog's
    // generic Enter-dismiss (confirmed live) does not resolve it -- likely
    // because it needs an actual vote/selection, not just a keypress, or
    // its own modal loop doesn't pump the WM_TIMER autoplay_dismiss_dialog
    // relies on. Revisit only if a session specifically needs Council
    // mechanics exercised under autoplay.
    *GameMoreRules |= MRULES_NO_PLANETARY_COUNCIL;
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

// EXPERIMENTAL, unverified, added 2026-07-25 after six rounds of
// disassembly still failed to fully suppress one recurring announcement
// ("WE HAVE ACQUIRED TECHNOLOGY!", tracked in IMPLEMENTATION_DETAILS.md
// 5.3) -- rather than keep chasing individual raw popup call sites,
// dismiss whatever's currently blocking generically. win_dialog_open()
// (gui.cpp) is true whenever the currently-focused window is neither the
// main map, the base screen, nor the design screen -- in an all-AI
// autoplay session there's no legitimate reason for anything else to have
// focus, so treat it as a blocking dialog and send it a synthetic Enter
// keypress via PostMessage, the same pattern already used (non-autoplay,
// proven safe) at gui.cpp's WM_MOUSEWHEEL-to-arrow-key translation. Real
// crash/side-effect risk is unverified -- try it, watch for a crash or a
// wrong AI action, report back.
void autoplay_dismiss_dialog() {
    if (!conf.autoplay || *GameHalted || !phWnd || !*phWnd) {
        return;
    }
    if (!win_dialog_open()) {
        return;
    }
    autoplay_logf("dismissing blocking dialog (win_dialog_open)\n");
    PostMessage(*phWnd, WM_KEYDOWN, VK_RETURN, 0);
    PostMessage(*phWnd, WM_KEYUP, VK_RETURN, 0);
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

// Found 2026-07-15 (autoplay.h has the full story): X_pop/X_pop_2/X_pops
// are raw engine primitives distinct from X_pop_9/X_pops_18, with real
// call sites in the recompiled source (end-of-game/scenario dialogs,
// probe-team post-action "excuse" dialogs) that a live all-AI session hit
// directly, unbypassed, even with autoplay=1.
int __cdecl autoplay_x_pop(const char* label, fp_none fn) {
    if (conf.autoplay) {
        autoplay_logf("X_pop label=%s\n", label ? label : "(null)");
        return 0;
    }
    return X_pop_engine(label, fn);
}

int __cdecl autoplay_x_pop_2(const char* filename, const char* label, fp_none fn) {
    if (conf.autoplay) {
        autoplay_logf("X_pop_2 filename=%s label=%s\n",
            filename ? filename : "(null)", label ? label : "(null)");
        return 0;
    }
    return X_pop_2_engine(filename, label, fn);
}

int __cdecl autoplay_x_pops(const char* label, Sprite* sprite, fp_none fn) {
    if (conf.autoplay) {
        autoplay_logf("X_pops label=%s\n", label ? label : "(null)");
        return 0;
    }
    return X_pops_engine(label, sprite, fn);
}

// See autoplay.h for the long story: this pair, not is_human(), is the real
// fix for probe-mission popup spam. Return value confirmed unused by every
// caller in this codebase (autoplay.h's comment).
int __thiscall autoplay_netmsg_pop(NetMessage* This, const char* label, int delay, int a4, const char* filename) {
    if (conf.autoplay) {
        autoplay_logf("NetMsg_pop label=%s delay=%d\n", label ? label : "(null)", delay);
        return 0;
    }
    return NetMsg_pop_engine(This, label, delay, a4, filename);
}

int __cdecl autoplay_netmsg_pop_2(const char* label, const char* filename) {
    if (conf.autoplay) {
        autoplay_logf("NetMsg_pop_2 label=%s\n", label ? label : "(null)");
        return 0;
    }
    return NetMsg_pop_2_engine(label, filename);
}

// See autoplay.h: single write_call target inside tech_achieved, not a
// global BasePop_exec_3 redirect. BasePop_exec_3 itself is never
// repointed, so this calls straight through to the real engine function
// (never *_engine -- there's nothing to fall back from here).
int __thiscall autoplay_tech_achieved_basepop3(BasePop* This, int a2, int a3) {
    if (conf.autoplay) {
        autoplay_logf("BasePop_exec_3 (tech_achieved)\n");
        return 0;
    }
    return BasePop_exec_3(This, a2, a3);
}

// See autoplay.h. `monument` (the global) is otherwise uncalled anywhere
// in this codebase, so this is the only caller that matters.
void __cdecl autoplay_monument(int a1) {
    if (conf.autoplay) {
        autoplay_logf("monument (mon_tech_discovered: RESEARCH BREAKTHROUGH)\n");
        return;
    }
    monument(a1);
}
