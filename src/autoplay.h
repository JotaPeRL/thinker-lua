#pragma once
/*
 * Autoplay spike (IMPLEMENTATION_PLAN.md Phase 5.3): unattended all-AI games
 * (every faction set to computer-controlled in the New Game screen, no human
 * present). "No human" is already a native game feature -- is_human() just
 * reads a bitmask set at game setup (faction.cpp:109) -- but several event/
 * announcement dialogs (SEARISING, ALIENSARRIVE, COUNCILOPEN, the victory
 * popups, ...) fire unconditionally, not gated on is_human, and block the
 * window's message loop waiting for a click.
 *
 * All of those calls funnel through exactly six raw engine primitives
 * (confirmed by grepping every popup/dialog call site under src/):
 * POP2, popp, popp_2, interlude, X_pop_9, X_pops_18. engine.cpp points the
 * public POP2/popp/popp_2/interlude/X_pop_9/X_pops_18 globals at the shims
 * below instead of the raw addresses (which are kept as the *_engine
 * globals); everything else in the codebase keeps calling the same names
 * unchanged. This is the whole mechanism -- no per-call-site patch needed.
 *
 * conf.autoplay == 0 (default): shims forward straight to the *_engine
 * pointer, i.e. behave exactly like before this file existed.
 * conf.autoplay != 0: shims log the call to autoplay.log (label + args)
 * and return a safe default without opening the real dialog.
 *
 * This is deliberately a short, iterative spike, not a complete catalog of
 * "every engine path that assumes a live human": run an all-AI game with
 * autoplay=1, see which label shows up (or which decision looks wrong) in
 * autoplay.log, special-case that one label in the relevant shim below if
 * the default of 0 turns out to be wrong for it, rebuild, repeat.
 */
#include "engine.h"

int __cdecl autoplay_pop2(const char* label, const char* pcx_filename, int a3);
int __cdecl autoplay_popp(const char* filename, const char* label, int a3, const char* pcx_filename, fp_none fn);
int __cdecl autoplay_popp_2(const char* filename, const char* label, fp_none fn);
void __cdecl autoplay_interlude(int event_id, const char* text, int a3, int a4);
int __cdecl autoplay_x_pop_9(const char* filename, const char* label, int a3, char* a4, int a5, fp_none fn);
int __cdecl autoplay_x_pops_18(const char* filename, const char* label, int a3, char* a4, int a5, Sprite* a6, int a7, int a8, fp_none fn);

// Shared with autoplay.cpp's shims; exposed so other seams (e.g.
// autoplay_demote_human below) can log to the same autoplay.log.
void autoplay_logf(const char* fmt, ...);

// The New Game screen always requires picking one faction to control --
// there is no "0 human players" setup option -- and thinker_enabled()
// (faction.cpp:142) excludes whichever faction is marked human from
// Thinker's entire AI stack (social_ai, tech_ai, design_units, ...), not
// just its popups. Bypassing dialogs (above) is therefore not enough for
// an unattended all-AI session: called every mod_turn_upkeep, this clears
// *CurrentPlayerFaction's bit in FactionStatus[0] when conf.autoplay is on,
// so that faction gets the full Thinker AI treatment too. Idempotent (a
// no-op once the bit is already clear), safe to call unconditionally.
void autoplay_demote_human();

// See the long comment above this function's definition in autoplay.cpp:
// experimental, calls an engine UI function this codebase has never called
// before. Call from a periodic idle callback (mod_blink_timer), not a
// once-per-turn one.
void autoplay_try_end_turn();
