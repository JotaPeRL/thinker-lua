-- 1:1 port of evaluate_attack (src/faction.cpp:1539-1718), the Class-1 pure
-- query behind mod_wants_to_attack (porting-order item 2b,
-- IMPLEMENTATION_PLAN.md Phase 4, IMPLEMENTATION_DETAILS.md 4.6). Registered
-- as a plain value-in/value-out hook: returns 1/0 (lua_ai_hook is int-only,
-- no native booleans) matching C++'s bool-as-int return. No RNG consumed.
--
-- Deliberately kept opaque, not ported (IMPLEMENTATION_DETAILS.md 4.6):
-- great_beelzebub/great_satan ("who's the dominant AI threat" heuristics,
-- pull in aah_ooga/climactic_battle/diff_level trees not worth porting for
-- two boolean reads) and has_agenda (trivial, but kept a host wrapper for
-- consistency with is_human/has_treaty). hq_region replaces the original's
-- own Bases[]/has_fac_built/region_at scan so BASE never needs FFI exposure
-- here (deferred to porting-order item 3, production/plans).
--
-- Translation notes (mirrors lua/ai/social.lua):
-- * idiv for every C truncating division; bit.band/bit.bor for `&`/`|`.
-- * MFaction::is_alien() (rule_flags & RFLAG_ALIEN) is a one-field flag
--   check, ported directly rather than kept as a host wrapper -- distinct
--   from the free is_alien(faction_id), which also checks *ExpansionEnabled
--   and isn't what evaluate_attack calls here.
local port = {
    source = {
        evaluate_attack = { file = "src/faction.cpp", func = "evaluate_attack",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local faction = dofile("lua/api/faction.lua")
local game = dofile("lua/api/game.lua")
local map = dofile("lua/api/map.lua")
local cmath = dofile("lua/api/cmath.lua")

local idiv = cmath.idiv
local clamp = cmath.clamp
local E = types.enums
local C = types.counts

local function is_alien(mf)
    return bit.band(mf.rule_flags, E.RFLAG_ALIEN) ~= 0
end

-- faction.cpp:1539-1718
local function evaluate_attack(faction_id, faction_id_tgt, faction_id_unk)
    local plr = faction.get(faction_id)
    local plr_tgt = faction.get(faction_id_tgt)
    local peace_faction_id = 0
    local common_enemy = false

    if is_alien(faction.meta(faction_id)) and is_alien(faction.meta(faction_id_tgt)) then
        return 1
    end
    if faction.has_treaty(faction_id, faction_id_tgt,
        bit.bor(E.DIPLO_WANT_REVENGE, E.DIPLO_UNK_40, E.DIPLO_ATROCITY_VICTIM)) ~= 0 then
        return 1
    end
    if plr.major_atrocities == 0 and plr_tgt.major_atrocities ~= 0 then
        return 1
    end
    if faction.has_treaty(faction_id, faction_id_tgt, E.DIPLO_UNK_4000000) ~= 0 then
        return 0
    end
    if not faction.is_human(faction_id_tgt)
    and bit.band(plr.player_flags, E.PFLAG_TEAM_UP_VS_HUMAN) ~= 0 then
        return 0
    end

    local modifier = 0
    for i = 1, C.MaxPlayerNum - 1 do
        if i ~= faction_id and i ~= faction_id_tgt then
            local has_surrender = faction.has_treaty(faction_id, i, E.DIPLO_HAVE_SURRENDERED) ~= 0
            if has_surrender and faction.has_treaty(faction_id, i, E.DIPLO_PACT) ~= 0 then
                peace_faction_id = i
            end
            if faction.has_treaty(faction_id, i, E.DIPLO_VENDETTA) ~= 0
            and faction.has_treaty(faction_id_tgt, i, E.DIPLO_PACT) == 0 then
                modifier = modifier + 1
                if faction.get(i).mil_strength_1 > idiv(plr_tgt.mil_strength_1 * 3, 2) then
                    modifier = modifier + 1
                end
            end
            if faction.great_beelzebub(i, 0) ~= 0
            and (game.turn() >= 100 or bit.band(game.rules(), E.RULES_INTENSE_RIVALRY) ~= 0) then
                if faction.has_treaty(faction_id_tgt, i, E.DIPLO_VENDETTA) ~= 0 then
                    modifier = modifier + 1
                end
                if faction.has_treaty(faction_id_tgt, i, E.DIPLO_COMMLINK) ~= 0
                and faction.has_treaty(faction_id, i, E.DIPLO_COMMLINK) ~= 0 then
                    modifier = modifier + 1
                end
            end
            if faction.has_treaty(faction_id, i, E.DIPLO_PACT) ~= 0 and faction.is_human(i) then
                if faction.has_treaty(faction_id_tgt, i, E.DIPLO_PACT) ~= 0 then
                    modifier = modifier + 2
                end
                if has_surrender and faction.has_treaty(i, faction_id_tgt,
                    bit.bor(E.DIPLO_PACT, E.DIPLO_TREATY)) ~= 0 then
                    return 0
                end
                if faction.has_treaty(faction_id_tgt, i, E.DIPLO_VENDETTA) ~= 0 then
                    common_enemy = true
                    modifier = modifier - (has_surrender and 4 or 2)
                end
            end
        end
    end

    if peace_faction_id ~= 0 then
        if faction.has_treaty(faction_id_tgt, peace_faction_id, E.DIPLO_VENDETTA) ~= 0 then
            return 1
        end
        if faction.has_treaty(faction_id_tgt, peace_faction_id,
            bit.bor(E.DIPLO_PACT, E.DIPLO_TREATY)) ~= 0 then
            return 0
        end
    end

    if plr.AI_fight < 0 and not common_enemy and game.faction_ranking(7) ~= faction_id_tgt then
        return 0
    end

    -- Modify attacks to be less likely when AI has only few bases
    local score = plr.base_count
        + (plr.best_armor_value > 1 and 5 or 0)
        + (plr.best_weapon_value > 1 and 5 or 0)
    if score <= bit.band(game.turn() + faction_id, 15) then
        return 0
    end

    local region_top_base_count = {}
    for i = 0, C.MaxPlayerNum - 1 do
        region_top_base_count[i] = 0
    end
    for region = 1, C.MaxRegionLandNum - 1 do
        for i = 1, C.MaxPlayerNum - 1 do
            local total_bases = faction.get(i).region_total_bases[region]
            if total_bases > region_top_base_count[i] then
                region_top_base_count[i] = total_bases
            end
        end
    end
    for i = 1, C.MaxPlayerNum - 1 do
        region_top_base_count[i] = region_top_base_count[i] - idiv(region_top_base_count[i], 4)
    end

    -- Replaces the original's own Bases[]/has_fac_built/region_at scan --
    -- see the module comment above.
    local region_hq = faction.hq_region(faction_id)
    local region_target_hq = faction.hq_region(faction_id_tgt)

    local factor_force_rating = 0
    local factor_count = 0
    local factor_unk = 1
    for region = 1, C.MaxRegionLandNum - 1 do
        local force_rating = plr.region_force_rating[region]
        if map.bad_reg(region) == 0 and force_rating ~= 0 then
            local total_cmbt_vehs = plr_tgt.region_total_combat_units[region]
            local total_bases_tgt = plr_tgt.region_total_bases[region]

            if total_cmbt_vehs ~= 0 or total_bases_tgt ~= 0 then
                if plr.region_total_bases[region] >= idiv(region_top_base_count[faction_id], 4) * 3
                or region == region_hq then
                    local unk_term = 0
                    if faction_id_unk > 0 then
                        unk_term = idiv(faction.get(faction_id_unk).region_force_rating[region], 4)
                    end
                    local compare = force_rating + plr.region_total_combat_units[region] + unk_term
                    if plr_tgt.region_force_rating[region] > compare then
                        return 0
                    end
                end
                if total_bases_tgt ~= 0 then
                    local unk_term = 0
                    if faction_id_unk > 0 then
                        unk_term = idiv(faction.get(faction_id_unk).region_force_rating[region], 2)
                    end
                    factor_force_rating = factor_force_rating + force_rating + unk_term
                end
                if (total_bases_tgt >= idiv(region_top_base_count[faction_id_tgt], 4) * 3
                or region == region_target_hq) and force_rating > total_cmbt_vehs then
                    local unk_term = 0
                    if faction_id_unk > 0 then
                        unk_term = idiv(faction.get(faction_id_unk).region_force_rating[region], 2)
                    end
                    factor_force_rating = factor_force_rating + force_rating + unk_term
                end
                local half_term = 0
                if plr.region_total_bases[region] ~= 0 then
                    half_term = idiv(plr_tgt.region_force_rating[region], 2)
                end
                factor_unk = factor_unk + total_cmbt_vehs + half_term
                if plr.region_total_bases[region] ~= 0 then
                    factor_count = factor_count + 1
                end
            end
        end
    end

    modifier = modifier - plr.AI_fight * 2
    if plr.tech_commerce_bonus > idiv(plr_tgt.tech_commerce_bonus * 3, 2) then
        modifier = modifier + 1
    end
    if plr.tech_commerce_bonus < idiv(plr_tgt.tech_commerce_bonus * 2, 3) then
        modifier = modifier - 1
    end
    if plr.best_weapon_value > plr_tgt.best_armor_value * 2 then
        modifier = modifier - 1
    end
    if plr.best_weapon_value <= plr_tgt.best_armor_value then
        modifier = modifier + 1
    end
    if faction.has_treaty(faction_id, faction_id_tgt, E.DIPLO_VENDETTA) == 0 then
        modifier = modifier + 1
    end
    if faction.has_treaty(faction_id, faction_id_tgt, E.DIPLO_PACT) ~= 0 then
        modifier = modifier + 1
    end
    if faction_id_unk > 0 and faction.great_satan(faction_id_unk, 0) == 0 then
        modifier = modifier - 1
    end
    if faction.has_agenda(faction_id, faction_id_tgt, E.AGENDA_UNK_200) ~= 0
    and bit.band(game.rules(), E.RULES_INTENSE_RIVALRY) ~= 0 then
        modifier = modifier - 1
    end
    modifier = modifier - clamp(idiv(plr_tgt.integrity_blemishes - plr.integrity_blemishes + 2, 3), 0, 2)

    local morale_factor = clamp(plr.SE_morale_pending, -4, 4) + faction.meta(faction_id).rule_morale + 16
    local morale_divisor = factor_unk * (clamp(plr_tgt.SE_morale_pending, -4, 4)
        + faction.meta(faction_id_tgt).rule_morale + 16)

    if morale_divisor == 0 then
        -- Matches the original's assert(0)-guarded dead branch (release
        -- builds compile the assert out) -- not expected to be reachable.
        return 0
    end
    if (factor_count ~= 0 or modifier > 0
    or faction.has_treaty(faction_id, faction_id_tgt, E.DIPLO_UNK_20000000) ~= 0)
    and idiv(morale_factor * factor_force_rating * 6, morale_divisor) < modifier + 6 then
        return 0
    end
    return 1
end

port.mod_wants_to_attack = evaluate_attack
return port
