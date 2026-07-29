-- Probe port, porting-order item 5 (IMPLEMENTATION_PLAN.md Phase 4.2
-- item 5, IMPLEMENTATION_DETAILS.md 4.19 for the survey that scoped
-- this). `probe()` (src/probe.cpp:327-1917 as of this port) is a single
-- ~1590-line, goto-driven, decompiled function mixing AI decision, RNG
-- success rolls, popups and state mutation line by line -- unlike every
-- prior porting item, it can't be ported whole. Only the genuinely pure,
-- isolable AI-decision fragments are hooked; everything else (all UI,
-- all success/failure resolution, all effect application) stays
-- untouched C++.
--
-- probe_choose_action re-ports MOV_CHECK (probe.cpp, the non-human
-- action_id decision): zero engine-state mutation, only local-variable
-- computation, so it's Class 1 (pure query) via the existing generic
-- lua_ai_hook mechanism -- no new hook shape needed. Hooked at both of
-- MOV_CHECK's two entry points (the initial `!is_human` branch and the
-- mind-control-retry `goto MOV_CHECK`), since it's reentrant within a
-- single probe() call. probe_choose_sabotage re-ports MOV_SABOTAGE's own
-- AI-only block the same way (stage 2 of 3).
local port = {
    source = {
        probe_choose_action = { file = "src/probe.cpp", func = "probe",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
        probe_choose_sabotage = { file = "src/probe.cpp", func = "probe",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local base_api = dofile("lua/api/base.lua")
local faction = dofile("lua/api/faction.lua")
local veh = dofile("lua/api/veh.lua")
local tech = dofile("lua/api/tech.lua")
local rand = dofile("lua/api/rand.lua")
local cmath = dofile("lua/api/cmath.lua")

local E = types.enums
local idiv = cmath.idiv

-- Same one-field-address technique as move.lua's own MultiplayerActive/
-- plan.lua's ExpansionEnabled use elsewhere -- each module re-declares
-- the tiny casts it needs.
local ExpansionEnabled = ffi.cast("int32_t*", types.globals.ExpansionEnabled)
local MultiplayerActive = ffi.cast("int32_t*", types.globals.MultiplayerActive)

-- probe.cpp:978-1080 (MOV_CHECK) as of this port. gene_warfare_allow is
-- threaded in as a precomputed argument (probe.cpp:419-434, shared
-- preamble computed before the human/AI fork) rather than recomputed
-- here -- it only needs Tech[].flags/TFLAG_ALLOW_GENE_WARFARE for a
-- single boolean gate, not worth re-exposing for that alone.
--
-- Known dead branch in the original, preserved faithfully rather than
-- second-guessed: prb_action_check is always false on entry to MOV_CHECK
-- (only ever set true *after* this point in the original, both at the
-- FREE_CAPTURED_FACTION_LEADER early-return and at the function's own
-- tail) so its `if (prb_action_check) goto MOV_START;` check can never
-- fire -- there is no Lua equivalent of that branch, matching that it
-- never executes in C++ either.
local function probe_choose_action(veh_id, tgt_base_id, gene_warfare_allow)
    local v = veh.get(veh_id)
    local veh_fc_id = v.faction_id
    local b = base_api.get(tgt_base_id)
    local tgt_fc_id = b.faction_id
    local plr = faction.get(veh_fc_id)
    local tgt = faction.get(tgt_fc_id)

    local plr_diplo = plr.diplo_status[tgt_fc_id]
    local check = bit.band(plr_diplo, bit.bor(E.DIPLO_WANT_REVENGE, E.DIPLO_VENDETTA)) ~= 0
    local action_id = check and E.PRB_ACTIVATE_SABOTAGE_VIRUS or E.PRB_INFILTRATE_DATALINKS
    local tgt_region = funcs.tile_region(b.x, b.y)
    if check then
        if plr.region_base_plan[tgt_region] ~= 0
            and b.talent_total == b.drone_total then
            if rand.game(2) == 0 and b.pop_size > 3 then
                action_id = E.PRB_INCITE_DRONE_RIOTS
            end
        end
    end
    if gene_warfare_allow ~= 0 then
        if b.pop_size >= 6 then
            if (bit.band(plr_diplo, E.DIPLO_ATROCITY_VICTIM) ~= 0
                or (not funcs.un_charter() and bit.band(plr_diplo, E.DIPLO_WANT_REVENGE) ~= 0))
                and plr.region_base_plan[tgt_region] == E.PLAN_DEFENSE then
                action_id = E.PRB_INTRODUCE_GENETIC_PLAGUE
            end
        end
        if b.pop_size >= 4 then
            if bit.band(plr.player_flags, E.PFLAG_COMMIT_ATROCITIES_WANTONLY) ~= 0 then
                if bit.band(plr_diplo, bit.bor(E.DIPLO_TRUCE, E.DIPLO_TREATY, E.DIPLO_PACT)) == 0
                    or bit.band(plr_diplo, E.DIPLO_WANT_REVENGE) ~= 0 then
                    action_id = E.PRB_INTRODUCE_GENETIC_PLAGUE
                end
            end
        end
    end
    local activate = false
    if bit.band(plr_diplo, bit.bor(E.DIPLO_WANT_REVENGE, E.DIPLO_VENDETTA)) ~= 0 then
        if funcs.probe_activate_check(tgt_base_id, veh_fc_id) then
            activate = true
            action_id = E.PRB_ACTIVATE_SABOTAGE_VIRUS
        end
    end
    if tech.rules().tgl_probe_steal_tech ~= 0 then
        if bit.band(b.state_flags, E.BSTATE_RESEARCH_DATA_STOLEN) == 0
            or funcs.mod_morale_veh(veh_id, 1, 0) >= 4
            or (action_id == E.PRB_INFILTRATE_DATALINKS
                and bit.band(plr_diplo, E.DIPLO_HAVE_INFILTRATOR) ~= 0) then
            if not activate and tgt.region_base_plan[tgt_region] ~= E.PLAN_DEFENSE then
                action_id = E.PRB_PROCURE_RESEARCH_DATA
            end
        end
    end
    if gene_warfare_allow ~= 0 then
        if b.pop_size >= 4 and funcs.aah_ooga(veh_fc_id, veh_fc_id) == tgt_fc_id
            and funcs.climactic_battle() ~= 0 then
            if plr.AI_fight > 0
                or (plr.AI_fight == 0 and bit.band(plr_diplo, E.DIPLO_WANT_REVENGE) ~= 0) then
                if bit.band(plr_diplo, bit.bor(E.DIPLO_UNK_800, E.DIPLO_SHALL_BETRAY,
                    E.DIPLO_WANT_REVENGE, E.DIPLO_VENDETTA)) ~= 0 then
                    action_id = E.PRB_INTRODUCE_GENETIC_PLAGUE
                end
            end
        end
    end

    if funcs.has_fac_built(E.FAC_HEADQUARTERS, tgt_base_id) ~= 0 then
        if action_id ~= E.PRB_PROCURE_RESEARCH_DATA
            and tgt.tech_accumulated >= idiv(tgt.tech_cost, 2)
            and (bit.band(plr_diplo, bit.bor(E.DIPLO_WANT_REVENGE, E.DIPLO_VENDETTA)) ~= 0
                or idiv(tgt.tech_ranking, 2) > idiv(plr.tech_ranking, 2) + 4) then
            action_id = E.PRB_ASSASSINATE_PROMINENT_RESEARCHERS
        end
        if ExpansionEnabled[0] ~= 0 and MultiplayerActive[0] == 0 then
            local out_ids = ffi.new("int32_t[7]")
            local count = funcs.captured_leaders(tgt_fc_id, out_ids)
            local found = false
            local prb_free_leader = -1
            for i = 0, count - 1 do
                local cur_id = out_ids[i]
                if bit.band(plr.diplo_status[cur_id], E.DIPLO_VENDETTA) == 0 then
                    found = true
                    if prb_free_leader < 0
                        or bit.band(plr.diplo_status[cur_id], E.DIPLO_PACT) ~= 0
                        or (bit.band(plr.diplo_status[cur_id], E.DIPLO_TREATY) ~= 0
                            and bit.band(plr.diplo_status[prb_free_leader], E.DIPLO_PACT) == 0) then
                        prb_free_leader = cur_id
                    end
                end
            end
            if found then
                return E.PRB_FREE_CAPTURED_FACTION_LEADER
            end
        end
    elseif bit.band(plr_diplo, bit.bor(E.DIPLO_WANT_REVENGE, E.DIPLO_VENDETTA)) ~= 0
        and (tgt.diff_level > 2 or not funcs.is_human(tgt_fc_id))
        and tgt.SE_probe < 3 then
        action_id = E.PRB_MIND_CONTROL_CITY
    end
    return action_id
end

-- Probe port, stage 2 (IMPLEMENTATION_DETAILS.md 4.19): MOV_SABOTAGE's
-- own AI-only block (probe.cpp:1082-1099 as of this port). Class 1 like
-- stage 1 -- zero engine-state mutation, only sabotage_id/prb_diff
-- locals. sabotage_id is threaded in (not just out): on a low-morale
-- probe, the incoming value (set by the switch statement before
-- `goto MOV_SABOTAGE`, either 0 or 98) passes through unchanged.
local SABOTAGE_FACILITIES = {
    E.FAC_TACHYON_FIELD, E.FAC_PERIMETER_DEFENSE, E.FAC_CHILDREN_CRECHE, E.FAC_COMMAND_CENTER,
}

local function probe_choose_sabotage(veh_id, tgt_base_id, sabotage_id)
    local prb_diff = 0
    if funcs.mod_morale_veh(veh_id, 1, 0) >= 5 then
        local b = base_api.get(tgt_base_id)
        if funcs.mod_stack_check(funcs.veh_at(b.x, b.y), 2, 5, -1, -1) ~= 0 then
            sabotage_id = 98
            prb_diff = 1
        else
            for _, item_id in ipairs(SABOTAGE_FACILITIES) do
                if funcs.has_fac_built(item_id, tgt_base_id) ~= 0 then
                    sabotage_id = item_id
                    prb_diff = 1
                    break
                end
            end
        end
    end
    return {sabotage_id, prb_diff}
end

port.probe_choose_action = probe_choose_action
port.probe_choose_sabotage = probe_choose_sabotage
return port
