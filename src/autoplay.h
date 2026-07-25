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
 * Originally scoped (2026-07-14) as "exactly six raw engine primitives",
 * found by grepping call sites for six specific wrapper names. **That
 * catalog was wrong, corrected 2026-07-15 by reading engine.h directly**:
 * X_pop_9/X_pops_18 are only two members of a much larger family --
 * X_pop through X_pop_9 (9), X_pops through X_pops_18 (18), and
 * X_pop_ask/X_pop_ask_number families (10 more) -- each its own distinct
 * raw engine address, not a variant of the same function. The original
 * grep only found calls that happened to route through Thinker's own
 * convenience wrappers (X_pop2/X_pop3/X_pop7/X_pops3/X_pops4/X_dialog,
 * gui_dialog.cpp), which do funnel into X_pop_9/X_pops_18 -- but plenty of
 * call sites use the *bare* numbered primitives directly, invisible to a
 * name-based grep for the wrapper names. A live all-AI session (2026-07-15)
 * hit two of these directly: probe-team post-action "excuse" dialogs
 * (X_pops, probe.cpp) required a manual click even with autoplay=1.
 * Checked which of the ~33 unshimmed primitives actually have call sites
 * in Thinker's own recompiled source (the only ones a pointer redirect can
 * reach -- calls baked into the original, un-decompiled engine binary,
 * like tech_achieved's tech-discovery announcement, are a different,
 * still-open problem no pointer redirect fixes): only X_pop (8 sites),
 * X_pop_2 (6 sites), X_pops (5 sites) are actually used. The rest
 * (X_pop_3..X_pop_8, X_pops_2..X_pops_17, all X_pop_ask*) have zero call
 * sites in the recompiled source tree and are left unshimmed -- nothing
 * to redirect.
 *
 * Now eleven primitives, all following the same mechanism: POP2, popp,
 * popp_2, interlude, X_pop_9, X_pops_18, X_pop, X_pop_2, X_pops,
 * NetMsg_pop, NetMsg_pop_2 (the last two added 2026-07-24, see the comment
 * above their declarations below -- a different, non-is_human gate than
 * every primitive before them).
 * engine.cpp points each public global at the shim below instead of the
 * raw address (kept as the matching *_engine global); everything else in
 * the codebase keeps calling the same names unchanged. No per-call-site
 * patch needed for any of the eleven.
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
int __cdecl autoplay_x_pop(const char* label, fp_none fn);
int __cdecl autoplay_x_pop_2(const char* filename, const char* label, fp_none fn);
int __cdecl autoplay_x_pops(const char* label, Sprite* sprite, fp_none fn);

// Found 2026-07-24, live: dozens of popups per turn, several per turn once
// probe teams become common, invisible in autoplay.log (proof they bypass
// every shim above). Root cause is a *different* gate than every popup
// above: probe.cpp's decision dialogs (EXCUSE/PACTEXCUSE/the probe-action
// menu, via BasePop_exec_2/_3) are gated on is_human(), which
// autoplay_demote_human() already neutralizes for the whole game -- those
// were never the problem. The actual flood is probe.cpp's *mission-report*
// messages (BUSTED, STOLENOTHING, GOTENERGY/TOOKENERGY, PROBECAUGHT,
// ASSASSINATED, FRAMEJOB/FRAMED, DRONEINCITE*, ...), which go through
// NetMsg_pop/NetMsg_pop_2 and are gated only on `veh_fc_id == MapWin->
// cOwner || tgt_fc_id == MapWin->cOwner` -- MapWin->cOwner stays pinned to
// the original New-Game human pick for the whole session, untouched by
// demotion, so any probe mission touching that faction (as either side)
// still pops. NetMsg_pop is also the general-purpose "flash a message"
// primitive used ~150 places outside probe.cpp (combat, goodie pods,
// morale, terraforming, ...) -- its return value is never consumed by any
// caller in this codebase, so a blanket safe default covers all of them,
// unlike BasePop_exec_2/_3 (real decision outcomes, left unshimmed --
// already unreachable via is_human, and a wrong per-call default there
// would silently change game state, e.g. FREEWHO's capture_id).
int __thiscall autoplay_netmsg_pop(NetMessage* This, const char* label, int delay, int a4, const char* filename);
int __cdecl autoplay_netmsg_pop_2(const char* label, const char* filename);

// tech_achieved has a *second*, more heavily-travelled un-shimmed path:
// when the faction achieving the tech isn't the one tracked by a fixed
// internal flag (the common case in an all-AI session -- most factions
// aren't it), it shows a BasePop_exec_3 dialog (src/patch.cpp's write_call
// at 0x5BBA37) instead of the NetMsg_pop banners above. Confirmed by
// disassembly that THIS specific call site's return value is discarded by
// the caller (`xor eax,eax` immediately follows the call, never read) --
// unlike BasePop_exec_2/_3's other call sites (probe.cpp, veh_action.cpp,
// base.cpp), which do consume the choice and are deliberately left
// unshimmed. This is one targeted write_call at a single address, not a
// redirect of the global BasePop_exec_3 pointer, so those other call
// sites are unaffected.
int __thiscall autoplay_tech_achieved_basepop3(BasePop* This, int a2, int a3);

// mon_tech_discovered (0x476C90, called from src/tech.cpp right after
// tech_advance -- outside the SkipTechScreenA-guarded block, since this
// function has no SkipTechScreenA check of its own) shows the "RESEARCH
// BREAKTHROUGH / WE HAVE ACQUIRED TECHNOLOGY!" announcement (labels.txt
// #551-553, an index-based text system, different from tech_achieved's
// named labels) via one internal call to `monument` (0x476A50, already
// declared in engine.h/.cpp but with zero callers anywhere in this
// codebase until now), gated the same way tech_achieved gates
// TECHOBTAINED: achieving faction == the same tracked global
// (ds:0x939284). `monument` returns void -- nothing to discard, uniform
// suppression is unambiguously safe. Single targeted write_call at
// 0x476D85, same technique as the tech_achieved BasePop_exec_3 fix.
void __cdecl autoplay_monument(int a1);

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

// Complementary to autoplay_try_end_turn, same idea applied to popups
// instead of the End Turn button: rather than chasing every individual
// raw popup call site (autoplay.h/.cpp's own history above is the
// cautionary tale -- six rounds of disassembly on a single announcement
// that still wasn't fully covered), dismiss whatever's currently blocking
// generically. See autoplay.cpp for the mechanism (gui.h's win_dialog_open()
// + a synthetic Enter keypress via the same PostMessage pattern already
// used at gui.cpp's wheel-to-arrow-key translation). EXPERIMENTAL, not yet
// live-tested: call from mod_blink_timer, same cadence as
// autoplay_try_end_turn.
void autoplay_dismiss_dialog();
