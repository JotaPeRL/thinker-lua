/*
 * Generates lua/ffi/types.lua: LuaJIT ffi.cdef struct declarations
 * (field-only, padded to match the real in-memory layout) plus a
 * validation table of sizeof/alignof/offsetof, computed by this same
 * toolchain's compiler frontend rather than typed in by hand
 * (IMPLEMENTATION_PLAN.md Phase 3.1).
 *
 * Deliberately does NOT include engine.h (the aggregator, which pulls in
 * <windows.h> for unrelated reasons) -- only the three portable,
 * #pragma pack(1) struct headers plus engine_enums.h. Compiled as a
 * native host binary (see CMakeLists.txt) since sizeof/offsetof/alignof
 * are pure compiler-frontend values that don't require running on the
 * real target OS; the real safety net is the startup validation inside
 * thinker.dll itself (src/luaai.cpp), which re-checks every value
 * emitted here against the actual mingw-compiled LuaJIT at game launch.
 *
 * Only the struct/global surface needed by the tech-AI pilot (Phase 4
 * milestone M4, mod_tech_val/mod_tech_ai in src/tech.cpp) is exposed
 * here, per milestone M3A ("build the vertical slice for the pilot
 * first"). Exposed fields are a deliberate projection, not the whole
 * struct -- unexposed regions become anonymous padding so that sizeof
 * still matches exactly (required for correct pointer arithmetic on
 * array globals such as Factions[faction_id]).
 */

#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <algorithm>
#include <type_traits>

// The struct headers below define several inline C++ methods (VEH::triad(),
// Faction::corner_market_active(), BASE::plr_owner(), ...) alongside their
// data fields. gen_ffi never calls these methods -- it only reads field
// offsets -- but non-template member function bodies are still fully name-
// resolved by the compiler wherever the enclosing struct is defined (C++
// "complete-class context" rules), so every global/function they reference
// must at least be *declared* before these headers are included. These
// stubs exist purely to satisfy that compile-time check; since nothing here
// ever calls them, they never need real definitions or to link against the
// actual engine. This is what lets gen_ffi include only the three portable
// struct headers instead of the Windows-dependent engine.h aggregator.
struct Faction;
struct CChassis;
struct CWeapon;
struct CArmor;
struct UNIT;
extern Faction* Factions;
extern CChassis* Chassis;
extern CWeapon* Weapon;
extern CArmor* Armor;
extern UNIT* Units;
extern int* const CurrentTurn;
extern const int MaxPlayerNum;
extern const int MaxBaseSpecNum;
extern const int MaxProtoFactionNum;
bool is_human(int faction_id);
bool map_is_known(int faction_id);
bool can_repair(int unit_id);
bool can_monolith(int unit_id);

#include "engine_enums.h"
#include "engine_types.h"
#include "engine_base.h"
#include "engine_veh.h"

struct FieldDesc {
    const char* name;
    const char* ctype;  // element C type for the cdef, e.g. "int32_t", "char"
    size_t offset;
    size_t count;        // array length (1 for scalars)
    size_t elem_size;     // sizeof of one element
};

// Maps a real C++ field type to the cdef label used for it. Deliberately a
// closed set (no generic fallback): an unlisted type is a compile error here
// rather than a guessed/wrong cdef string, so the label can never drift from
// the size gen_ffi actually measured with sizeof/offsetof -- unlike a
// hand-typed string, which can silently name the wrong width (caught the
// hard way once already: CChassis::preq_tech is int16_t, not int32_t).
template<typename T> struct CTypeName; // no generic definition on purpose
#define DECLARE_CTYPE(T, label) \
    template<> struct CTypeName<T> { static constexpr const char* value = label; }
DECLARE_CTYPE(int8_t, "int8_t");
DECLARE_CTYPE(uint8_t, "uint8_t");
DECLARE_CTYPE(int16_t, "int16_t");
DECLARE_CTYPE(uint16_t, "uint16_t");
DECLARE_CTYPE(int32_t, "int32_t");
DECLARE_CTYPE(uint32_t, "uint32_t");
DECLARE_CTYPE(char, "char");
DECLARE_CTYPE(char*, "char*");
#undef DECLARE_CTYPE

// Element type + array length for a field's real type: T for scalars,
// (element type, N) for a T[N] array member.
template<typename T> struct FieldShape {
    using Elem = T;
    static constexpr size_t count = 1;
};
template<typename T, size_t N> struct FieldShape<T[N]> {
    using Elem = T;
    static constexpr size_t count = N;
};
// 2D array fields (e.g. Faction::social_psych[8][9]) flatten to a single
// cdef array of N*M elements -- Lua indexes it arr[i*M+j] to reproduce C's
// row-major layout. More specialized than FieldShape<T[N]> (which would
// otherwise match with Elem deduced as the inner array type), so overload
// resolution picks this one for genuine 2D array members.
template<typename T, size_t N, size_t M> struct FieldShape<T[N][M]> {
    using Elem = T;
    static constexpr size_t count = N * M;
};

template<typename MemberT>
static FieldDesc make_field(const char* name, size_t offset) {
    using Elem = typename FieldShape<MemberT>::Elem;
    return FieldDesc{ name, CTypeName<Elem>::value, offset,
        FieldShape<MemberT>::count, sizeof(Elem) };
}

// FIELD(Faction, AI_growth) -- ctype and element size are both derived from
// the field's actual declared type, never typed in separately.
#define FIELD(Struct, member) \
    make_field<decltype(((Struct*)0)->member)>(#member, offsetof(Struct, member))

struct StructDesc {
    const char* name;
    size_t total_size;
    size_t total_align;
    std::vector<FieldDesc> fields;
};

static std::vector<std::string> validation_rows;

static void emit_struct(FILE* out, StructDesc desc) {
    std::sort(desc.fields.begin(), desc.fields.end(),
        [](const FieldDesc& a, const FieldDesc& b) { return a.offset < b.offset; });

    fprintf(out, "typedef struct __attribute__((packed)) {\n");
    size_t cursor = 0;
    int pad_n = 0;
    for (const FieldDesc& f : desc.fields) {
        if (f.offset > cursor) {
            fprintf(out, "    char _pad_%d[%zu];\n", pad_n++, f.offset - cursor);
        }
        if (f.count > 1) {
            fprintf(out, "    %s %s[%zu];\n", f.ctype, f.name, f.count);
        } else {
            fprintf(out, "    %s %s;\n", f.ctype, f.name);
        }
        cursor = f.offset + f.count * f.elem_size;

        char row[256];
        snprintf(row, sizeof(row),
            "    {struct=\"%s\", field=\"%s\", check=\"offsetof\", expected=%zu},",
            desc.name, f.name, f.offset);
        validation_rows.push_back(row);
    }
    if (desc.total_size > cursor) {
        fprintf(out, "    char _pad_%d[%zu];\n", pad_n++, desc.total_size - cursor);
    }
    fprintf(out, "} %s;\n\n", desc.name);

    char row[256];
    snprintf(row, sizeof(row),
        "    {struct=\"%s\", check=\"sizeof\", expected=%zu},", desc.name, desc.total_size);
    validation_rows.push_back(row);
    snprintf(row, sizeof(row),
        "    {struct=\"%s\", check=\"alignof\", expected=%zu},", desc.name, desc.total_align);
    validation_rows.push_back(row);
}

int main() {
    printf("-- GENERATED FILE -- do not edit.\n");
    printf("-- Produced by tools/gen_ffi.cpp from src/engine_types.h, engine_base.h,\n");
    printf("-- engine_veh.h (IMPLEMENTATION_PLAN.md Phase 3.1). Regenerated on every\n");
    printf("-- build; validated at Lua init time against the real thinker.dll layout\n");
    printf("-- (src/luaai.cpp) before any of this is trusted.\n");
    printf("-- `ffi` is already a global (opened directly by the sandbox, not via\n");
    printf("-- require -- package/require stays disabled outside debug builds).\n\n");
    printf("ffi.cdef[[\n");

    emit_struct(stdout, {"CTech", sizeof(CTech), alignof(CTech), {
        FIELD(CTech, flags),
        FIELD(CTech, name),
        FIELD(CTech, short_name),
        FIELD(CTech, AI_growth),
        FIELD(CTech, AI_tech),
        FIELD(CTech, AI_wealth),
        FIELD(CTech, AI_power),
        FIELD(CTech, preq_tech1),
        FIELD(CTech, preq_tech2),
    }});

    emit_struct(stdout, {"CFacility", sizeof(CFacility), alignof(CFacility), {
        FIELD(CFacility, name),
        FIELD(CFacility, effect),
        FIELD(CFacility, cost),
        FIELD(CFacility, maint),
        FIELD(CFacility, preq_tech),
        FIELD(CFacility, free_tech),
        FIELD(CFacility, AI_fight),
        FIELD(CFacility, AI_growth),
        FIELD(CFacility, AI_tech),
        FIELD(CFacility, AI_wealth),
        FIELD(CFacility, AI_power),
    }});

    emit_struct(stdout, {"CReactor", sizeof(CReactor), alignof(CReactor), {
        FIELD(CReactor, preq_tech),
    }});

    emit_struct(stdout, {"CWeapon", sizeof(CWeapon), alignof(CWeapon), {
        FIELD(CWeapon, offense_value),
        FIELD(CWeapon, preq_tech),
        FIELD(CWeapon, mode), // production/plans port (item 3, IMPLEMENTATION_DETAILS.md 4.7)
    }});

    emit_struct(stdout, {"CChassis", sizeof(CChassis), alignof(CChassis), {
        FIELD(CChassis, preq_tech),
        FIELD(CChassis, speed),
        // production/plans port (item 3, IMPLEMENTATION_DETAILS.md 4.7):
        // backs UNIT::triad()/range()/is_missile(), re-ported below.
        FIELD(CChassis, triad),
        FIELD(CChassis, range),
        FIELD(CChassis, missile),
    }});

    emit_struct(stdout, {"CArmor", sizeof(CArmor), alignof(CArmor), {
        FIELD(CArmor, defense_value),
    }});

    emit_struct(stdout, {"UNIT", sizeof(UNIT), alignof(UNIT), {
        FIELD(UNIT, chassis_id),
        FIELD(UNIT, weapon_id),
        FIELD(UNIT, armor_id),
        FIELD(UNIT, reactor_id),
        FIELD(UNIT, preq_tech),
        // production/plans port (item 3, IMPLEMENTATION_DETAILS.md 4.7).
        FIELD(UNIT, plan),
        FIELD(UNIT, ability_flags),
        FIELD(UNIT, cost),
        FIELD(UNIT, unit_flags), // backs is_prototyped(), needed by proto_extra_cost
    }});

    emit_struct(stdout, {"Continent", sizeof(Continent), alignof(Continent), {
        FIELD(Continent, tile_count),
        // Movement port, route_score sub-stage (IMPLEMENTATION_DETAILS.md
        // 4.12): route_score's own pod-density bonus term.
        FIELD(Continent, pods),
    }});

    emit_struct(stdout, {"MFaction", sizeof(MFaction), alignof(MFaction), {
        FIELD(MFaction, rule_psi),
        FIELD(MFaction, rule_population),
        FIELD(MFaction, soc_priority_category),
        FIELD(MFaction, soc_priority_model),
        FIELD(MFaction, soc_priority_effect),
        FIELD(MFaction, thinker_last_mc_turn),
        FIELD(MFaction, rule_drone),
        FIELD(MFaction, rule_talent),
        // War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md
        // 4.6): rule_flags backs MFaction::is_alien() (rule_flags &
        // RFLAG_ALIEN), ported directly in lua/ai/war.lua rather than kept
        // as a host wrapper -- it's a one-field flag check, same tier as
        // is_human()'s FactionStatus bitmask read.
        FIELD(MFaction, rule_flags),
        FIELD(MFaction, rule_morale),
    }});

    emit_struct(stdout, {"CRules", sizeof(CRules), alignof(CRules), {
        FIELD(CRules, tech_preq_allow_3_nutrients_sq),
        FIELD(CRules, tech_preq_allow_3_minerals_sq),
        FIELD(CRules, tech_preq_allow_3_energy_sq),
        // production/plans port (item 3, IMPLEMENTATION_DETAILS.md 4.7).
        FIELD(CRules, retool_penalty_prod_change),
        FIELD(CRules, retool_exemption),
        FIELD(CRules, extra_cost_prototype_sea),
        FIELD(CRules, extra_cost_prototype_air),
        FIELD(CRules, extra_cost_prototype_land),
        FIELD(CRules, artillery_max_rng),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.21): the shared GOV_MAY_FORCE_
        // PSYCH gate (FAC_PUNISHMENT_SPHERE/FAC_GENEJACK_FACTORY).
        FIELD(CRules, drones_induced_genejack_factory),
        // former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13):
        // can_sensor/can_magtube's fungus-tech gate and can_road's own.
        FIELD(CRules, tech_preq_improv_fungus),
        FIELD(CRules, tech_preq_build_road_fungus),
        // former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
        // select_item's own sea solar_need branch.
        FIELD(CRules, tech_preq_mining_platform_bonus),
    }});

    emit_struct(stdout, {"Faction", sizeof(Faction), alignof(Faction), {
        FIELD(Faction, AI_fight),
        FIELD(Faction, AI_growth),
        FIELD(Faction, AI_tech),
        FIELD(Faction, AI_wealth),
        FIELD(Faction, AI_power),
        FIELD(Faction, base_count),
        FIELD(Faction, region_total_bases),
        FIELD(Faction, region_base_plan),
        FIELD(Faction, best_weapon_value),
        FIELD(Faction, enemy_best_weapon_value),
        FIELD(Faction, SE_planet_base),
        FIELD(Faction, SE_probe_base),
        FIELD(Faction, unk_47),
        FIELD(Faction, region_visible_tiles),
        // Social engineering (porting-order item 2, IMPLEMENTATION_DETAILS.md
        // 4.5): SE_Politics..SE_Future is the "current" category/model
        // array (CSocialCategory overlay); SE_economy..SE_research is the
        // "current" effect-value array (CSocialEffect overlay) -- both are
        // plain consecutive int32_t runs, not separate struct types, see
        // 4.5's "key insight". social_support/social_psych/social_effic are
        // the AI's score lookup tables (social_psych is 2D, flattened here).
        FIELD(Faction, SE_Politics),
        FIELD(Faction, SE_Economics),
        FIELD(Faction, SE_Values),
        FIELD(Faction, SE_Future),
        FIELD(Faction, SE_economy),
        FIELD(Faction, SE_effic),
        FIELD(Faction, SE_support),
        FIELD(Faction, SE_talent),
        FIELD(Faction, SE_morale),
        FIELD(Faction, SE_police),
        FIELD(Faction, SE_growth),
        FIELD(Faction, SE_planet),
        FIELD(Faction, SE_probe),
        FIELD(Faction, SE_industry),
        FIELD(Faction, SE_research),
        FIELD(Faction, social_support),
        FIELD(Faction, social_psych),
        FIELD(Faction, social_effic),
        // War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md
        // 4.6): evaluate_attack's own field reads, re-derived directly from
        // its body (faction.cpp:1539-1718), not from the earlier scope note.
        FIELD(Faction, major_atrocities),
        FIELD(Faction, player_flags),
        FIELD(Faction, mil_strength_1),
        FIELD(Faction, best_armor_value),
        FIELD(Faction, region_force_rating),
        FIELD(Faction, region_total_combat_units),
        FIELD(Faction, tech_commerce_bonus),
        FIELD(Faction, integrity_blemishes),
        FIELD(Faction, SE_morale_pending),
        // production/plans port (item 3, IMPLEMENTATION_DETAILS.md 4.7).
        FIELD(Faction, player_flags_ext),
        FIELD(Faction, diff_level),
        FIELD(Faction, SE_support_pending),
        FIELD(Faction, SE_police_pending), // backs BASE::SE_police(pending)
        // Autoplay harness per-turn state hash (IMPLEMENTATION_PLAN.md
        // "Consolidation gate" item a): energy_credits and tech_ranking
        // ("twice the number of techs discovered", engine_types.h) are the
        // per-faction tech/energy summary the hash line folds in.
        FIELD(Faction, energy_credits),
        FIELD(Faction, tech_ranking),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.17): FAC_BIOLOGY_LAB's own
        // branch (build.cpp:1302-1306).
        FIELD(Faction, SE_planet_pending),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.21): FAC_PUNISHMENT_SPHERE's
        // own branch.
        FIELD(Faction, SE_alloc_labs),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.22): FAC_CHILDREN_CRECHE's own
        // branch.
        FIELD(Faction, SE_growth_pending),
        FIELD(Faction, SE_effic_pending),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.23): FAC_TREE_FARM/
        // FAC_HYBRID_FOREST's shared branch.
        FIELD(Faction, SE_alloc_psych),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.24): the FAC_GENEJACK_FACTORY
        // group's shared branch.
        FIELD(Faction, clean_minerals_modifier),
        // select_build itself, unit-branch catalog (IMPLEMENTATION_
        // DETAILS.md 4.10.27): find_satellite's own dependencies
        // (Satellites branch).
        FIELD(Faction, satellites_nutrient),
        FIELD(Faction, satellites_mineral),
        FIELD(Faction, satellites_energy),
        FIELD(Faction, satellites_ODP),
        FIELD(Faction, planet_busters),
        // select_build itself, unit-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.28): find_project/find_missile/
        // faction_might/has_pact/redundant_project (SecretProject branch).
        FIELD(Faction, diplo_status),
        FIELD(Faction, pop_total),
    }});

    // production/plans port, first slice (porting-order item 3,
    // IMPLEMENTATION_DETAILS.md 4.7): first-ever BASE exposure. Deliberate
    // projection covering only what unit_score/find_proto and their direct
    // helpers (check_retool, base_can_riot) read -- not the whole struct.
    // Bases[] itself is a mutable, re-pointable pointer (like Vehs[],
    // IMPLEMENTATION_DETAILS.md 3.2) so its address is exposed via a
    // LuaHostApi accessor (src/luaai.cpp's host_bases_ptr), fetched fresh
    // by lua/api/base.lua on every access, not baked into `globals` as a
    // fixed address the way Factions/MFactions are.
    emit_struct(stdout, {"BASE", sizeof(BASE), alignof(BASE), {
        FIELD(BASE, x),
        FIELD(BASE, y),
        FIELD(BASE, faction_id),
        FIELD(BASE, governor_flags),
        FIELD(BASE, production_id_last),
        FIELD(BASE, mineral_surplus),
        FIELD(BASE, minerals_accumulated),
        FIELD(BASE, mineral_consumption),
        FIELD(BASE, specialist_adjust),
        FIELD(BASE, state_flags),
        FIELD(BASE, nerve_staple_turns_left),
        FIELD(BASE, drone_total),
        FIELD(BASE, talent_total),
        // Production/plans port, second slice (item 3, IMPLEMENTATION_
        // DETAILS.md 4.8).
        FIELD(BASE, defend_range),
        FIELD(BASE, mineral_intake_2),
        // Production/plans port, third slice (item 3, IMPLEMENTATION_
        // DETAILS.md 4.9).
        FIELD(BASE, defend_goal),
        // select_build itself, step 3 sub-step 1 (item 3, final piece,
        // IMPLEMENTATION_DETAILS.md 4.10.9/4.10.12, resumed after the
        // Consolidation gate): the shared prologue's allow_pods needs
        // these two.
        FIELD(BASE, pop_size),
        FIELD(BASE, nutrient_surplus),
        // select_build itself, step 3 sub-step 3 (the build_order loop's
        // per-item base score, IMPLEMENTATION_DETAILS.md 4.10.9/4.10.14,
        // resumed after the Consolidation gate): Wenergy + the energy gate.
        FIELD(BASE, energy_surplus),
        FIELD(BASE, energy_inefficiency),
        // select_build itself, facility-branch catalog (IMPLEMENTATION_
        // DETAILS.md 4.10.15): the current production item, backing
        // engine_base.h's item()/item_is_project()/item_is_unit() inline
        // methods -- unblocks select_build's project_change/allow_units
        // locals (build.cpp:868-872) and FAC_PSI_GATE's own direct read.
        // Whole 10-slot array exposed (same FieldShape<T[N]> mechanism
        // already proven by Faction::region_force_rating) even though
        // callers so far only need slot 0 -- narrower exposure would need
        // a new FIELD() case for no real benefit.
        FIELD(BASE, queue_items),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.17): FAC_BIOLOGY_LAB/
        // FAC_CENTAURI_PRESERVE's shared branch (build.cpp:1307-1310),
        // also a recurring blocker for FAC_TREE_FARM/FAC_HYBRID_FOREST
        // and the FAC_GENEJACK_FACTORY group (not touched this session).
        FIELD(BASE, eco_damage),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.18): the shared FAC_RECREATION_
        // COMMONS/FAC_HOLOGRAM_THEATRE/FAC_RESEARCH_HOSPITAL/FAC_PARADISE_
        // GARDEN branch's skip check.
        FIELD(BASE, specialist_total),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.21): FAC_PUNISHMENT_SPHERE's
        // own branch.
        FIELD(BASE, assimilation_turns_left),
        // select_build itself, facility-branch catalog continued
        // (IMPLEMENTATION_DETAILS.md 4.10.24): the FAC_GENEJACK_FACTORY
        // group's shared branch. Distinct from the already-exposed
        // mineral_intake_2 -- verified against engine_base.h, not assumed.
        FIELD(BASE, mineral_intake),
    }});

    // select_build itself (porting-order item 3, final piece,
    // IMPLEMENTATION_DETAILS.md 4.10.1): VEH's first-ever exposure.
    // Deliberately narrow -- select_build's only direct VEH reads are in
    // its vehicle-count loop (build.cpp:913-955); everything else in VEH
    // (waypoints, morale, combat state, ...) stays unexposed padding.
    // Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12):
    // iter_count/waypoint_x/waypoint_y/waypoint_count back VEH::at_target(),
    // needed by artifact_move's own re-check-in-progress-order branch.
    emit_struct(stdout, {"VEH", sizeof(VEH), alignof(VEH), {
        FIELD(VEH, x),
        FIELD(VEH, y),
        FIELD(VEH, unit_id),
        FIELD(VEH, faction_id),
        FIELD(VEH, order),
        FIELD(VEH, home_base_id),
        FIELD(VEH, iter_count),
        FIELD(VEH, waypoint_x),
        FIELD(VEH, waypoint_y),
        FIELD(VEH, waypoint_count),
        // Movement port, stage 3 (IMPLEMENTATION_DETAILS.md 4.12):
        // colony_move's own VSTATE_UNK_40000/VSTATE_UNK_2000 waypoint-order
        // read (state is only ever written through the new
        // set_colony_automation_flags host wrapper, never directly from Lua).
        FIELD(VEH, state),
        // former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
        // the player-former auto-order dispatch.
        FIELD(VEH, order_auto_type),
    }});

    // former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
    // Terraform[]'s own .rate lookup (turns remaining for an in-progress
    // terraform order). Only .rate is exposed -- name/name_sea/shortcuts
    // are char* (shortcuts is read natively inside the opaque
    // former_apply_action wrapper instead, never crossing into Lua);
    // preq_tech/preq_tech_sea/bit/bit_incompatible aren't needed by any
    // ported function. Unlike ResInfoRecyclingTanks/ResInfoForestSq, this
    // one CAN use emit_struct (rate is a scalar, not a nested struct) --
    // unexposed leading fields become padding, computed via the real
    // offsetof/sizeof like every other emit_struct call.
    emit_struct(stdout, {"CTerraform", sizeof(CTerraform), alignof(CTerraform), {
        FIELD(CTerraform, rate),
    }});

    printf("]]\n\n");

    printf("return {\n");
    printf("  globals = {\n");
    printf("    Factions = 0x%08X,\n", 0x96C9E0);
    printf("    MFactions = 0x%08X,\n", 0x946A50);
    printf("    Tech = 0x%08X,\n", 0x94F358);
    printf("    Facility = 0x%08X,\n", 0x9A4B68);
    printf("    Reactor = 0x%08X,\n", 0x9527F8);
    printf("    Weapon = 0x%08X,\n", 0x94AE60);
    printf("    Armor = 0x%08X,\n", 0x94F278);
    printf("    Chassis = 0x%08X,\n", 0x94A330);
    printf("    Units = 0x%08X,\n", 0x9AB868);
    printf("    Continents = 0x%08X,\n", 0x9AA730);
    printf("    TechOwners = 0x%08X,\n", 0x9A6670);
    printf("    Rules = 0x%08X,\n", 0x949738);
    printf("    CurrentTurn = 0x%08X,\n", 0x9A64D4);
    printf("    GameRules = 0x%08X,\n", 0x9A649C);
    printf("    MapCloudCover = 0x%08X,\n", 0x94A2B4);
    printf("    BaseCount = 0x%08X,\n", 0x9A64CC);
    // Social engineering (porting-order item 2): plain scalar globals,
    // addresses confirmed against src/engine.cpp (same provenance-by-comment
    // convention as the addresses above).
    printf("    SunspotDuration = 0x%08X,\n", 0x9A6800);
    printf("    DiffLevel = 0x%08X,\n", 0x9A64C4);
    printf("    MapAreaSqRoot = 0x%08X,\n", 0x949888);
    // select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
    // 4.10.27): SeaProbeUnit's own adjacent_region radius.
    printf("    MapAreaTiles = 0x%08X,\n", 0x949884);
    // Movement port, stage 3 (IMPLEMENTATION_DETAILS.md 4.12):
    // base_tile_score's own map-edge distance term (src/engine.cpp).
    printf("    MapAreaY = 0x%08X,\n", 0x949874);
    // War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md
    // 4.6): int* const, same provenance-by-comment convention (src/engine.cpp).
    printf("    FactionRankings = 0x%08X,\n", 0x9A64EC);
    // Production/plans port, first slice (item 3, IMPLEMENTATION_DETAILS.md
    // 4.7): int* const, fixed address (src/engine.cpp).
    printf("    MultiplayerActive = 0x%08X,\n", 0x93F660);
    // select_build itself (item 3, final piece, IMPLEMENTATION_DETAILS.md
    // 4.10.1): int* const, fixed address (src/engine.cpp), same tier as
    // BaseCount above. Vehs itself is mutable/re-pointable (3.2, same
    // category as Bases) -- exposed via a LuaHostApi vehs_ptr() wrapper
    // instead, fetched fresh by lua/api/veh.lua on every access.
    printf("    VehCount = 0x%08X,\n", 0x9A64C8);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.26): FAC_RECYCLING_TANKS's own
    // branch. ResInfo (src/engine.cpp: `CResourceInfo* ResInfo =
    // (CResourceInfo*)0x945F50;`) is a 144-byte, 9-ResValue-member
    // struct (engine_types.h:599-609); only the recycling_tanks member
    // is needed. Rather than emit_struct the whole CResourceInfo (the
    // FIELD()/FieldShape mechanism only handles scalar/array-of-scalar
    // members, not nested-struct members), expose just this one
    // ResValue's address directly -- computed via the real offsetof, not
    // hand-counted, so it stays compiler-verified like every other
    // layout fact this tool emits. ResValue's field order (engine_types.h
    // :592-597) is nutrient, mineral, energy, unused -- read as a plain
    // int32_t[3] (skipping the unused 4th) in lua/api/tech.lua.
    printf("    ResInfoRecyclingTanks = 0x%08X,\n",
        (unsigned)(0x945F50 + offsetof(CResourceInfo, recycling_tanks)));
    // former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13):
    // can_solar's own forest-energy-yield reference point. Same
    // one-ResValue-member-address technique as ResInfoRecyclingTanks
    // above, not a whole-CResourceInfo emit_struct.
    printf("    ResInfoForestSq = 0x%08X,\n",
        (unsigned)(0x945F50 + offsetof(CResourceInfo, forest_sq)));
    // former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
    // select_item's own borehole/sea-solar branches. Same one-ResValue-
    // member-address technique as ResInfoForestSq above.
    printf("    ResInfoBoreholeSq = 0x%08X,\n",
        (unsigned)(0x945F50 + offsetof(CResourceInfo, borehole_sq)));
    printf("    ResInfoImprovedSea = 0x%08X,\n",
        (unsigned)(0x945F50 + offsetof(CResourceInfo, improved_sea)));
    // former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13):
    // int* const, fixed addresses (src/engine.cpp), same tier as
    // MultiplayerActive above.
    printf("    GamePreferences = 0x%08X,\n", 0x9A6490);
    printf("    GameMorePreferences = 0x%08X,\n", 0x9A6494);
    // former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
    // CTerraform* const, fixed address (src/engine.cpp), same tier as
    // Rules/ResInfo.
    printf("    Terraform = 0x%08X,\n", 0x691878);
    printf("  },\n");
    // Array bounds for the exposed rule tables, from src/main.h (not
    // included here -- same provenance-by-comment convention as the
    // addresses above, since main.h pulls in the Windows-dependent
    // engine.h chain gen_ffi otherwise avoids).
    printf("  counts = {\n");
    printf("    MaxPlayerNum = %d,\n", 8);        // main.h:111
    printf("    MaxTechnologyNum = %d,\n", 89);    // main.h:123
    printf("    MaxChassisNum = %d,\n", 9);        // main.h:124
    printf("    MaxWeaponNum = %d,\n", 26);        // main.h:125
    printf("    MaxArmorNum = %d,\n", 14);         // main.h:126
    printf("    MaxReactorNum = %d,\n", 4);        // main.h:127
    printf("    MaxFacilityNum = %d,\n", 64);      // main.h:143
    // MaxFacilityNum (main.h) is NOT the Facility[] array bound -- it
    // undercounts, since the same array also holds Secret Project
    // records at higher indices (e.g. FAC_HUNTER_SEEKER_ALGORITHM=85,
    // FAC_ASCENT_TO_TRANSCENDENCE=102 both exceed 64). Found the hard
    // way: an M4 in-game run hit "facility_id out of range: 85".
    // FAC_EMPTY_SP_64 is the highest member of that enum (padding slots
    // for unused Secret Project data) -- read from the compiler, not
    // hand-typed, so this can't silently drift the way the hand-typed
    // 64 above did.
    printf("    MaxFacilityArrayNum = %d,\n", FAC_EMPTY_SP_64 + 1);
    printf("    MaxProtoNum = %d,\n", 512);        // main.h:116
    printf("    MaxProtoFactionNum = %d,\n", 64);  // main.h:117
    printf("    MaxRegionNum = %d,\n", 128);       // main.h:106
    printf("    MaxRegionLandNum = %d,\n", 64);    // main.h:107
    // select_build step 3 sub-step 1 (IMPLEMENTATION_DETAILS.md 4.10.9/
    // 4.10.12, resumed after the Consolidation gate): defend_range's
    // default and Wbase's clamp condition both need this.
    printf("    MaxEnemyRange = %d,\n", 50);       // main.h:172
    printf("    MaxSocialCatNum = %d,\n", 4);      // main.h:146
    printf("    MaxSocialModelNum = %d,\n", 4);    // main.h:147
    printf("    MaxSocialEffectNum = %d,\n", 11);  // main.h:148
    printf("    GrowthPopBoom = %d,\n", 6);        // main.h:158
    printf("    MaxBaseNum = %d,\n", 512);         // main.h:114
    printf("  },\n");
    // Enum constants the tech-AI port (M4) branches on. Values come
    // straight from engine_enums.h (already included above for the
    // struct headers) rather than being hand-typed into Lua -- the same
    // discipline as `counts`, for the same reason (a hand-typed value
    // can silently drift from the real one; a compiler-read value can't).
    printf("  enums = {\n");
    printf("    TECH_None = %d,\n", TECH_None);
    printf("    TECH_CentMed = %d,\n", TECH_CentMed);
    printf("    TECH_PlaEcon = %d,\n", TECH_PlaEcon);
    printf("    TECH_AlphCen = %d,\n", TECH_AlphCen);
    printf("    TECH_DocInit = %d,\n", TECH_DocInit);
    printf("    TECH_EnvEcon = %d,\n", TECH_EnvEcon);
    printf("    FAC_ASCENT_TO_TRANSCENDENCE = %d,\n", FAC_ASCENT_TO_TRANSCENDENCE);
    printf("    FAC_HUNTER_SEEKER_ALGORITHM = %d,\n", FAC_HUNTER_SEEKER_ALGORITHM);
    printf("    FAC_DREAM_TWISTER = %d,\n", FAC_DREAM_TWISTER);
    printf("    FAC_HYBRID_FOREST = %d,\n", FAC_HYBRID_FOREST);
    printf("    FAC_TREE_FARM = %d,\n", FAC_TREE_FARM);
    printf("    FAC_CENTAURI_PRESERVE = %d,\n", FAC_CENTAURI_PRESERVE);
    printf("    FAC_TEMPLE_OF_PLANET = %d,\n", FAC_TEMPLE_OF_PLANET);
    printf("    FAC_HAB_COMPLEX = %d,\n", FAC_HAB_COMPLEX);
    printf("    FAC_HABITATION_DOME = %d,\n", FAC_HABITATION_DOME);
    printf("    FAC_RECYCLING_TANKS = %d,\n", FAC_RECYCLING_TANKS);
    printf("    FAC_CHILDREN_CRECHE = %d,\n", FAC_CHILDREN_CRECHE);
    printf("    FAC_RECREATION_COMMONS = %d,\n", FAC_RECREATION_COMMONS);
    printf("    REC_FUSION = %d,\n", REC_FUSION);
    printf("    REC_QUANTUM = %d,\n", REC_QUANTUM);
    printf("    BSC_FORMERS = %d,\n", BSC_FORMERS);
    printf("    CHS_FOIL = %d,\n", CHS_FOIL);
    printf("    WPN_TERRAFORMING_UNIT = %d,\n", WPN_TERRAFORMING_UNIT);
    printf("    WPN_SUPPLY_TRANSPORT = %d,\n", WPN_SUPPLY_TRANSPORT);
    printf("    DIPLO_VENDETTA = %d,\n", DIPLO_VENDETTA);
    printf("    DIPLO_COMMLINK = %d,\n", DIPLO_COMMLINK);
    printf("    DIPLO_PACT = %d,\n", DIPLO_PACT);
    printf("    DIPLO_TREATY = %d,\n", DIPLO_TREATY);
    printf("    DIPLO_WANT_REVENGE = %d,\n", DIPLO_WANT_REVENGE);
    printf("    RULES_BLIND_RESEARCH = %d,\n", RULES_BLIND_RESEARCH);
    printf("    TFLAG_SECRETS = %d,\n", TFLAG_SECRETS);
    printf("    PLAN_NAVAL_TRANSPORT = %d,\n", PLAN_NAVAL_TRANSPORT);
    printf("    PLAN_DEFENSE = %d,\n", PLAN_DEFENSE);
    printf("    PLAN_OFFENSE = %d,\n", PLAN_OFFENSE);
    // Social engineering (porting-order item 2, IMPLEMENTATION_DETAILS.md 4.5).
    printf("    FAC_CHILDREN_CRECHE = %d,\n", FAC_CHILDREN_CRECHE);
    printf("    FAC_PUNISHMENT_SPHERE = %d,\n", FAC_PUNISHMENT_SPHERE);
    printf("    FAC_COMMAND_NEXUS = %d,\n", FAC_COMMAND_NEXUS);
    printf("    FAC_LONGEVITY_VACCINE = %d,\n", FAC_LONGEVITY_VACCINE);
    printf("    FAC_CYBORG_FACTORY = %d,\n", FAC_CYBORG_FACTORY);
    printf("    FAC_CLONING_VATS = %d,\n", FAC_CLONING_VATS);
    printf("    FAC_TELEPATHIC_MATRIX = %d,\n", FAC_TELEPATHIC_MATRIX);
    printf("    FAC_MANIFOLD_HARMONICS = %d,\n", FAC_MANIFOLD_HARMONICS);
    printf("    DIFF_LIBRARIAN = %d,\n", DIFF_LIBRARIAN);
    printf("    SOCIAL_C_ECONOMICS = %d,\n", SOCIAL_C_ECONOMICS);
    printf("    SOCIAL_M_FRONTIER = %d,\n", SOCIAL_M_FRONTIER);
    printf("    SOCIAL_M_SIMPLE = %d,\n", SOCIAL_M_SIMPLE);
    printf("    SOCIAL_M_PLANNED = %d,\n", SOCIAL_M_PLANNED);
    printf("    SOCIAL_M_GREEN = %d,\n", SOCIAL_M_GREEN);
    printf("    RULES_SCN_NO_TECH_ADVANCES = %d,\n", RULES_SCN_NO_TECH_ADVANCES);
    // War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md 4.6).
    printf("    DIPLO_UNK_40 = %d,\n", DIPLO_UNK_40);
    printf("    DIPLO_ATROCITY_VICTIM = %d,\n", DIPLO_ATROCITY_VICTIM);
    printf("    DIPLO_HAVE_SURRENDERED = %d,\n", DIPLO_HAVE_SURRENDERED);
    printf("    DIPLO_UNK_4000000 = %d,\n", DIPLO_UNK_4000000);
    printf("    DIPLO_UNK_20000000 = %d,\n", DIPLO_UNK_20000000);
    printf("    PFLAG_TEAM_UP_VS_HUMAN = %d,\n", PFLAG_TEAM_UP_VS_HUMAN);
    printf("    AGENDA_UNK_200 = %d,\n", AGENDA_UNK_200);
    printf("    RULES_INTENSE_RIVALRY = %d,\n", RULES_INTENSE_RIVALRY);
    printf("    RFLAG_ALIEN = %d,\n", RFLAG_ALIEN);
    printf("    FAC_HEADQUARTERS = %d,\n", FAC_HEADQUARTERS);
    // Production/plans port, first slice (porting-order item 3,
    // IMPLEMENTATION_DETAILS.md 4.7).
    printf("    PLAN_PLANET_BUSTER = %d,\n", PLAN_PLANET_BUSTER);
    printf("    PLAN_COLONY = %d,\n", PLAN_COLONY);
    printf("    BSTATE_PRODUCTION_DONE = %d,\n", BSTATE_PRODUCTION_DONE);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.18): backs BASE::drone_riots_active()
    // (engine_base.h:231), needed by the shared FAC_RECREATION_COMMONS/
    // FAC_HOLOGRAM_THEATRE/FAC_RESEARCH_HOSPITAL/FAC_PARADISE_GARDEN branch.
    printf("    BSTATE_DRONE_RIOTS_ACTIVE = %d,\n", BSTATE_DRONE_RIOTS_ACTIVE);
    printf("    RETOOL_ALWAYS_FREE = %d,\n", RETOOL_ALWAYS_FREE);
    printf("    RETOOL_FREE_PROJECT = %d,\n", RETOOL_FREE_PROJECT);
    printf("    RFLAG_FREEPROTO = %d,\n", RFLAG_FREEPROTO);
    printf("    GOV_MAY_PROD_NATIVE = %d,\n", GOV_MAY_PROD_NATIVE);
    printf("    GOV_MAY_PROD_PROTOTYPE = %d,\n", GOV_MAY_PROD_PROTOTYPE);
    printf("    GOV_MAY_PROD_AIR_COMBAT = %d,\n", GOV_MAY_PROD_AIR_COMBAT);
    printf("    GOV_MAY_PROD_AIR_DEFENSE = %d,\n", GOV_MAY_PROD_AIR_DEFENSE);
    printf("    FAC_BROOD_PIT = %d,\n", FAC_BROOD_PIT);
    printf("    FAC_BIOLOGY_LAB = %d,\n", FAC_BIOLOGY_LAB);
    // FAC_CENTAURI_PRESERVE/FAC_TEMPLE_OF_PLANET already emitted above (tech pilot).
    printf("    FAC_SKUNKWORKS = %d,\n", FAC_SKUNKWORKS);
    // FAC_PUNISHMENT_SPHERE already emitted above (4.5, social engineering).
    printf("    TRFLAG_LAND = %d,\n", TRFLAG_LAND);
    printf("    TRFLAG_SEA = %d,\n", TRFLAG_SEA);
    printf("    TRFLAG_AIR = %d,\n", TRFLAG_AIR);
    printf("    WMODE_COMBAT = %d,\n", WMODE_COMBAT);
    printf("    WMODE_COLONY = %d,\n", WMODE_COLONY);
    printf("    WMODE_PROBE = %d,\n", WMODE_PROBE);
    printf("    WMODE_TERRAFORM = %d,\n", WMODE_TERRAFORM);
    printf("    WMODE_SUPPLY = %d,\n", WMODE_SUPPLY);
    printf("    WMODE_TRANSPORT = %d,\n", WMODE_TRANSPORT);
    printf("    PFLAG_EXT_STRAT_LOTS_MISSILES = %d,\n", PFLAG_EXT_STRAT_LOTS_MISSILES);
    printf("    PFLAG_EXT_STRAT_LOTS_ARTILLERY = %d,\n", PFLAG_EXT_STRAT_LOTS_ARTILLERY);
    printf("    ABL_AAA = %d,\n", ABL_AAA);
    printf("    ABL_AIR_SUPERIORITY = %d,\n", ABL_AIR_SUPERIORITY);
    printf("    ABL_ALGO_ENHANCEMENT = %d,\n", ABL_ALGO_ENHANCEMENT);
    printf("    ABL_AMPHIBIOUS = %d,\n", ABL_AMPHIBIOUS);
    printf("    ABL_DROP_POD = %d,\n", ABL_DROP_POD);
    printf("    ABL_EMPATH = %d,\n", ABL_EMPATH);
    printf("    ABL_TRANCE = %d,\n", ABL_TRANCE);
    printf("    ABL_SLOW = %d,\n", ABL_SLOW);
    printf("    ABL_TRAINED = %d,\n", ABL_TRAINED);
    printf("    ABL_COMM_JAMMER = %d,\n", ABL_COMM_JAMMER);
    printf("    ABL_ANTIGRAV_STRUTS = %d,\n", ABL_ANTIGRAV_STRUTS);
    printf("    ABL_BLINK_DISPLACER = %d,\n", ABL_BLINK_DISPLACER);
    printf("    ABL_DEEP_PRESSURE_HULL = %d,\n", ABL_DEEP_PRESSURE_HULL);
    printf("    ABL_SUPER_TERRAFORMER = %d,\n", ABL_SUPER_TERRAFORMER);
    printf("    ABL_ARTILLERY = %d,\n", ABL_ARTILLERY);
    printf("    ABL_POLICE_2X = %d,\n", ABL_POLICE_2X);
    printf("    ABL_CLEAN_REACTOR = %d,\n", ABL_CLEAN_REACTOR);
    printf("    UNIT_PROTOTYPED = %d,\n", UNIT_PROTOTYPED);
    printf("    REC_FISSION = %d,\n", REC_FISSION);
    printf("    SE_Pending = %d,\n", SE_Pending);
    printf("    TRIAD_SEA = %d,\n", TRIAD_SEA);
    printf("    TRIAD_AIR = %d,\n", TRIAD_AIR);
    printf("    TRIAD_LAND = %d,\n", TRIAD_LAND);
    printf("    PLAN_SUPPLY = %d,\n", PLAN_SUPPLY);
    printf("    PLAN_PROBE = %d,\n", PLAN_PROBE);
    printf("    PLAN_TERRAFORM = %d,\n", PLAN_TERRAFORM);
    printf("    DIFF_SPECIALIST = %d,\n", DIFF_SPECIALIST);
    printf("    PLAN_NAVAL_SUPERIORITY = %d,\n", PLAN_NAVAL_SUPERIORITY);
    printf("    PLAN_RECON = %d,\n", PLAN_RECON);
    printf("    FAC_STOCKPILE_ENERGY = %d,\n", FAC_STOCKPILE_ENERGY);
    // Production/plans port, second slice (item 3, IMPLEMENTATION_DETAILS.md 4.8).
    printf("    PFLAG_EXT_STRAT_LOTS_COLONY_PODS = %d,\n", PFLAG_EXT_STRAT_LOTS_COLONY_PODS);
    printf("    PFLAG_EXT_STRAT_LOTS_SEA_BASES = %d,\n", PFLAG_EXT_STRAT_LOTS_SEA_BASES);
    printf("    DIFF_CITIZEN = %d,\n", DIFF_CITIZEN);
    printf("    PFLAG_EMPHASIZE_AIR_POWER = %d,\n", PFLAG_EMPHASIZE_AIR_POWER);
    printf("    PFLAG_EMPHASIZE_SEA_POWER = %d,\n", PFLAG_EMPHASIZE_SEA_POWER);
    printf("    PFLAG_EMPHASIZE_LAND_POWER = %d,\n", PFLAG_EMPHASIZE_LAND_POWER);
    printf("    PFLAG_EXT_STRAT_LOTS_PROBE_TEAMS = %d,\n", PFLAG_EXT_STRAT_LOTS_PROBE_TEAMS);
    printf("    GOV_MAY_PROD_PROBES = %d,\n", GOV_MAY_PROD_PROBES);
    printf("    GOV_MAY_PROD_TRANSPORT = %d,\n", GOV_MAY_PROD_TRANSPORT);
    printf("    GOV_MAY_PROD_LAND_COMBAT = %d,\n", GOV_MAY_PROD_LAND_COMBAT);
    printf("    GOV_MAY_PROD_LAND_DEFENSE = %d,\n", GOV_MAY_PROD_LAND_DEFENSE);
    printf("    GOV_MAY_PROD_NAVAL_COMBAT = %d,\n", GOV_MAY_PROD_NAVAL_COMBAT);
    printf("    RFLAG_AQUATIC = %d,\n", RFLAG_AQUATIC);
    // Production/plans port, third slice (item 3, IMPLEMENTATION_DETAILS.md 4.9).
    printf("    GOV_PRIORITY_EXPLORE = %d,\n", GOV_PRIORITY_EXPLORE);
    printf("    GOV_PRIORITY_DISCOVER = %d,\n", GOV_PRIORITY_DISCOVER);
    printf("    GOV_PRIORITY_BUILD = %d,\n", GOV_PRIORITY_BUILD);
    printf("    GOV_PRIORITY_CONQUER = %d,\n", GOV_PRIORITY_CONQUER);
    // select_build itself (item 3, final piece, IMPLEMENTATION_DETAILS.md
    // 4.10.1/4.10.4), step 1 (VEH + the vehicle-count loop).
    printf("    PLAN_ARTIFACT = %d,\n", PLAN_ARTIFACT);
    printf("    BSC_FUNGAL_TOWER = %d,\n", BSC_FUNGAL_TOWER);
    printf("    ORDER_CONVOY = %d,\n", ORDER_CONVOY);
    printf("    GOV_MAY_PROD_TERRAFORMERS = %d,\n", GOV_MAY_PROD_TERRAFORMERS);
    // Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12): VEH::at_target().
    printf("    ORDER_NONE = %d,\n", ORDER_NONE);
    printf("    ORDER_HOLD = %d,\n", ORDER_HOLD);
    // Movement port, stage 2 (IMPLEMENTATION_DETAILS.md 4.12): crawler_move.
    printf("    ORDER_MOVE_TO = %d,\n", ORDER_MOVE_TO);
    printf("    RES_NONE = %d,\n", RES_NONE);
    printf("    RES_NUTRIENT = %d,\n", RES_NUTRIENT);
    printf("    RES_MINERAL = %d,\n", RES_MINERAL);
    printf("    RES_ENERGY = %d,\n", RES_ENERGY);
    // Movement port, stage 2 rework (IMPLEMENTATION_DETAILS.md 4.12):
    // want_convoy's own energy-choice gate.
    printf("    FAC_SUPERCOLLIDER = %d,\n", FAC_SUPERCOLLIDER);
    printf("    FAC_THEORY_OF_EVERYTHING = %d,\n", FAC_THEORY_OF_EVERYTHING);
    // select_build itself, step 2 (push_item + has_retool/skip_facility,
    // IMPLEMENTATION_DETAILS.md 4.10.5/4.10.9 resumed after the
    // Consolidation gate).
    printf("    FAC_ORBITAL_DEFENSE_POD = %d,\n", FAC_ORBITAL_DEFENSE_POD);
    printf("    SP_ID_First = %d,\n", SP_ID_First);
    printf("    SP_ID_Last = %d,\n", SP_ID_Last);
    printf("    Fac_ID_Last = %d,\n", Fac_ID_Last);
    // select_build itself, step 3 sub-step 2 (DefendUnit/CombatUnit,
    // IMPLEMENTATION_DETAILS.md 4.10.9/4.10.13, resumed after the
    // Consolidation gate). GOV_ALLOW_COMBAT is a computed constant in
    // base.h, not a raw bitfield -- mirrored here from its three
    // constituent flags rather than hardcoded, matching base.h:5-6 exactly.
    printf("    GOV_ALLOW_COMBAT = %d,\n",
        GOV_MAY_PROD_LAND_COMBAT | GOV_MAY_PROD_NAVAL_COMBAT | GOV_MAY_PROD_AIR_COMBAT);
    printf("    GOV_MAY_PROD_EXPLORE_VEH = %d,\n", GOV_MAY_PROD_EXPLORE_VEH);
    // select_build itself, step 3 sub-step 3 (the build_order loop's
    // per-item base score, IMPLEMENTATION_DETAILS.md 4.10.9/4.10.14,
    // resumed after the Consolidation gate). Batch addition -- every
    // FAC_* item_id referenced in build_order[] not already exposed;
    // per 4.10.4's discipline, not hand-verified one by one, the
    // compiler/generator catches a typo'd or missing name as a build
    // error.
    printf("    GOV_MAY_PROD_FACILITIES = %d,\n", GOV_MAY_PROD_FACILITIES);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.21): the shared gate before
    // FAC_PUNISHMENT_SPHERE/FAC_GENEJACK_FACTORY.
    printf("    GOV_MAY_FORCE_PSYCH = %d,\n", GOV_MAY_FORCE_PSYCH);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.23): FAC_TREE_FARM/FAC_HYBRID_
    // FOREST's shared branch, nearby_items' tile-flag argument.
    printf("    BIT_FOREST = %d,\n", BIT_FOREST);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.25): FAC_NETWORK_NODE's own branch.
    printf("    FAC_VIRTUAL_WORLD = %d,\n", FAC_VIRTUAL_WORLD);
    // select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
    // 4.10.27): ColonyUnit/SeaProbeUnit/FerryUnit/CrawlerUnit/Satellites.
    printf("    GOV_MAY_PROD_COLONY_POD = %d,\n", GOV_MAY_PROD_COLONY_POD);
    printf("    FAC_NESSUS_MINING_STATION = %d,\n", FAC_NESSUS_MINING_STATION);
    printf("    FAC_ORBITAL_POWER_TRANS = %d,\n", FAC_ORBITAL_POWER_TRANS);
    printf("    FAC_SKY_HYDRO_LAB = %d,\n", FAC_SKY_HYDRO_LAB);
    printf("    FAC_SPACE_ELEVATOR = %d,\n", FAC_SPACE_ELEVATOR);
    // select_build itself, unit-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.28): find_project/redundant_project
    // (SecretProject branch).
    printf("    GOV_MAY_PROD_SP = %d,\n", GOV_MAY_PROD_SP);
    // select_build itself, unit-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.29): FormerUnit's own branch.
    printf("    PFLAG_EXT_STRAT_LOTS_TERRAFORMERS = %d,\n", PFLAG_EXT_STRAT_LOTS_TERRAFORMERS);
    printf("    DIPLO_MAJOR_ATROCITY_VICTIM = %d,\n", DIPLO_MAJOR_ATROCITY_VICTIM);
    printf("    PFLAG_COMMIT_ATROCITIES_WANTONLY = %d,\n", PFLAG_COMMIT_ATROCITIES_WANTONLY);
    printf("    FAC_SUBSPACE_GENERATOR = %d,\n", FAC_SUBSPACE_GENERATOR);
    printf("    FAC_CITIZENS_DEFENSE_FORCE = %d,\n", FAC_CITIZENS_DEFENSE_FORCE);
    printf("    FAC_MARITIME_CONTROL_CENTER = %d,\n", FAC_MARITIME_CONTROL_CENTER);
    printf("    FAC_PLANETARY_DATALINKS = %d,\n", FAC_PLANETARY_DATALINKS);
    printf("    FAC_LIVING_REFINERY = %d,\n", FAC_LIVING_REFINERY);
    printf("    FAC_PRESSURE_DOME = %d,\n", FAC_PRESSURE_DOME);
    printf("    FAC_NETWORK_NODE = %d,\n", FAC_NETWORK_NODE);
    printf("    FAC_HOLOGRAM_THEATRE = %d,\n", FAC_HOLOGRAM_THEATRE);
    printf("    FAC_PERIMETER_DEFENSE = %d,\n", FAC_PERIMETER_DEFENSE);
    printf("    FAC_AEROSPACE_COMPLEX = %d,\n", FAC_AEROSPACE_COMPLEX);
    printf("    FAC_GENEJACK_FACTORY = %d,\n", FAC_GENEJACK_FACTORY);
    printf("    FAC_ROBOTIC_ASSEMBLY_PLANT = %d,\n", FAC_ROBOTIC_ASSEMBLY_PLANT);
    printf("    FAC_NANOREPLICATOR = %d,\n", FAC_NANOREPLICATOR);
    printf("    FAC_QUANTUM_CONVERTER = %d,\n", FAC_QUANTUM_CONVERTER);
    printf("    FAC_TACHYON_FIELD = %d,\n", FAC_TACHYON_FIELD);
    printf("    FAC_GEOSYNC_SURVEY_POD = %d,\n", FAC_GEOSYNC_SURVEY_POD);
    printf("    FAC_FLECHETTE_DEFENSE_SYS = %d,\n", FAC_FLECHETTE_DEFENSE_SYS);
    printf("    FAC_BIOENHANCEMENT_CENTER = %d,\n", FAC_BIOENHANCEMENT_CENTER);
    printf("    FAC_COMMAND_CENTER = %d,\n", FAC_COMMAND_CENTER);
    printf("    FAC_NAVAL_YARD = %d,\n", FAC_NAVAL_YARD);
    printf("    FAC_PSI_GATE = %d,\n", FAC_PSI_GATE);
    printf("    FAC_FUSION_LAB = %d,\n", FAC_FUSION_LAB);
    printf("    FAC_QUANTUM_LAB = %d,\n", FAC_QUANTUM_LAB);
    printf("    FAC_ENERGY_BANK = %d,\n", FAC_ENERGY_BANK);
    printf("    FAC_PARADISE_GARDEN = %d,\n", FAC_PARADISE_GARDEN);
    printf("    FAC_RESEARCH_HOSPITAL = %d,\n", FAC_RESEARCH_HOSPITAL);
    printf("    FAC_NANOHOSPITAL = %d,\n", FAC_NANOHOSPITAL);
    printf("    FAC_COVERT_OPS_CENTER = %d,\n", FAC_COVERT_OPS_CENTER);
    printf("    FAC_EMPTY_FACILITY_42 = %d,\n", FAC_EMPTY_FACILITY_42);
    printf("    FAC_EMPTY_FACILITY_43 = %d,\n", FAC_EMPTY_FACILITY_43);
    printf("    FAC_EMPTY_FACILITY_44 = %d,\n", FAC_EMPTY_FACILITY_44);
    printf("    FAC_EMPTY_FACILITY_45 = %d,\n", FAC_EMPTY_FACILITY_45);
    // Movement port, stage 0+1 (IMPLEMENTATION_DETAILS.md 4.12): the two
    // action codes every mover returns (veh_turn.h's EnemyVehMove) and
    // PM_SAFE (move.h, a plain `const int`). Hand-transcribed, not read
    // via #include, because veh_turn.h/move.h pull in main.h -> windows.h
    // transitively, which the natively-compiled (non-mingw) gen_ffi host
    // tool can't process -- same tier as this file's other hand-
    // transcribed globals (Rules/GameRules) predating the computed-
    // address technique (4.10.26). All three are small, stable literals
    // (0/1/-20) unlikely to change; cross-check against veh_turn.h/move.h
    // directly if this ever needs revisiting.
    printf("    VEH_SYNC = %d,\n", 0);
    printf("    VEH_SKIP = %d,\n", 1);
    printf("    PM_SAFE = %d,\n", -20);
    // Movement port, stage 3 (IMPLEMENTATION_DETAILS.md 4.12): path.h's
    // NodesetType enum (used by has_map_node/mark_map_node), same
    // hand-transcription reason as VEH_SYNC/VEH_SKIP/PM_SAFE above --
    // path.h also pulls in windows.h transitively. Default enum
    // numbering (path.h:63-78), cross-check there if this ever drifts.
    printf("    NODE_NEED_FERRY = %d,\n", 3);
    printf("    NODE_BASE_SITE = %d,\n", 4);
    printf("    NODE_PATROL = %d,\n", 12);
    // former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13):
    // can_borehole/can_sensor/can_bridge/can_road's own markers.
    printf("    NODE_BOREHOLE = %d,\n", 0);
    printf("    NODE_SENSOR_ARRAY = %d,\n", 2);
    printf("    NODE_GOAL_RAISE_LAND = %d,\n", 6);
    // former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
    // select_item's own bridge/raise-land branch marker.
    printf("    NODE_RAISE_LAND = %d,\n", 1);
    // Movement port, route_score sub-stage (IMPLEMENTATION_DETAILS.md
    // 4.12): route_score's artifact-linking special case (path.h:71).
    printf("    NODE_NAVAL_START = %d,\n", 7);
    // Movement port, route_score sub-stage B (IMPLEMENTATION_DETAILS.md
    // 4.12): the naval-pickup-point search's own marker (path.h:74).
    printf("    NODE_NAVAL_PICK = %d,\n", 10);
    // Movement port, route_score sub-stage B (IMPLEMENTATION_DETAILS.md
    // 4.12): add_goal's own goal-type constant (engine_enums.h, already
    // included above) -- compiler-read, not hand-typed.
    printf("    AI_GOAL_NAVAL_PICK = %d,\n", AI_GOAL_NAVAL_PICK);
    // Movement port, stage 3 (IMPLEMENTATION_DETAILS.md 4.12):
    // escape_score/base_tile_score/colony_move's own item/landmark/
    // altitude/order constants. All come straight from engine_enums.h/
    // engine_veh.h (both already included above), same "compiler-read,
    // not hand-typed" discipline as the TECH_/FAC_ batch.
    printf("    BIT_FUNGUS = %d,\n", BIT_FUNGUS);
    printf("    BIT_RIVER = %d,\n", BIT_RIVER);
    printf("    BIT_BUNKER = %d,\n", BIT_BUNKER);
    printf("    BIT_MONOLITH = %d,\n", BIT_MONOLITH);
    printf("    BIT_FARM = %d,\n", BIT_FARM);
    printf("    BIT_SENSOR = %u,\n", (unsigned)BIT_SENSOR);
    printf("    LM_JUNGLE = %d,\n", LM_JUNGLE);
    printf("    LM_SARGASSO = %d,\n", LM_SARGASSO);
    printf("    LM_DUNES = %d,\n", LM_DUNES);
    printf("    LM_UNITY = %d,\n", LM_UNITY);
    // former_move port, sub-stage 3 (IMPLEMENTATION_DETAILS.md 4.13):
    // former_tile_score's own landmark-bonus mask.
    printf("    LM_NEXUS = %d,\n", LM_NEXUS);
    printf("    ALT_OCEAN = %d,\n", ALT_OCEAN);
    printf("    ALT_OCEAN_SHELF = %d,\n", ALT_OCEAN_SHELF);
    printf("    ALT_SHORE_LINE = %d,\n", ALT_SHORE_LINE);
    printf("    ORDER_SENTRY_BOARD = %d,\n", ORDER_SENTRY_BOARD);
    printf("    VSTATE_UNK_40000 = %d,\n", VSTATE_UNK_40000);
    printf("    VSTATE_UNK_2000 = %d,\n", VSTATE_UNK_2000);
    // colony_move's own VehRemoveTurns (move.cpp:30, `static const int` file
    // -local to move.cpp -- gen_ffi can't #include a .cpp, so hand-
    // transcribed like PM_SAFE above; cross-check move.cpp:30 if this ever
    // needs revisiting).
    printf("    VEH_REMOVE_TURNS = %d,\n", 60);
    // former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13): the
    // 12 can_*/keep_fungus/plant_fungus tile-eligibility helpers -- item/
    // resource/landmark/altitude/preference-flag constants. All come
    // straight from engine_enums.h/engine_veh.h (both already included
    // above), same "compiler-read, not hand-typed" discipline as the
    // TECH_/FAC_ batch. can_bridge itself stays fully opaque (a single
    // host wrapper, no AI judgment ported), so its own
    // PREF_AUTO_FORMER_RAISE_LWR_TERRAIN flag is deliberately NOT exposed
    // here -- it's read natively inside that wrapper's C++ body.
    printf("    BIT_BASE_IN_TILE = %d,\n", BIT_BASE_IN_TILE);
    printf("    BIT_ROAD = %d,\n", BIT_ROAD);
    printf("    BIT_MAGTUBE = %d,\n", BIT_MAGTUBE);
    printf("    BIT_MINE = %d,\n", BIT_MINE);
    printf("    BIT_SOLAR = %d,\n", BIT_SOLAR);
    printf("    BIT_CONDENSER = %d,\n", BIT_CONDENSER);
    printf("    BIT_THERMAL_BORE = %d,\n", BIT_THERMAL_BORE);
    printf("    RES_NONE = %d,\n", RES_NONE);
    printf("    RES_NUTRIENT = %d,\n", RES_NUTRIENT);
    printf("    RES_MINERAL = %d,\n", RES_MINERAL);
    printf("    RES_ENERGY = %d,\n", RES_ENERGY);
    printf("    LM_VOLCANO = %d,\n", LM_VOLCANO);
    printf("    ALT_TWO_ABOVE_SEA = %d,\n", ALT_TWO_ABOVE_SEA);
    printf("    PREF_AUTO_FORMER_BUILD_ADV = %d,\n", PREF_AUTO_FORMER_BUILD_ADV);
    printf("    PREF_AUTO_FORMER_PLANT_FORESTS = %d,\n", PREF_AUTO_FORMER_PLANT_FORESTS);
    printf("    MPREF_AUTO_FORMER_BUILD_SENSORS = %d,\n", MPREF_AUTO_FORMER_BUILD_SENSORS);
    printf("    MPREF_AUTO_FORMER_CANT_BUILD_ROADS = %d,\n", MPREF_AUTO_FORMER_CANT_BUILD_ROADS);
    printf("    FAC_XENOEMPATHY_DOME = %d,\n", FAC_XENOEMPATHY_DOME);
    printf("    FORMER_FARM = %d,\n", FORMER_FARM);
    printf("    FORMER_MINE = %d,\n", FORMER_MINE);
    printf("    FORMER_SOLAR = %d,\n", FORMER_SOLAR);
    printf("    FORMER_FOREST = %d,\n", FORMER_FOREST);
    printf("    FORMER_ROAD = %d,\n", FORMER_ROAD);
    printf("    FORMER_MAGTUBE = %d,\n", FORMER_MAGTUBE);
    printf("    FORMER_SENSOR = %d,\n", FORMER_SENSOR);
    printf("    FORMER_PLANT_FUNGUS = %d,\n", FORMER_PLANT_FUNGUS);
    printf("    FORMER_THERMAL_BORE = %d,\n", FORMER_THERMAL_BORE);
    printf("    FORMER_AQUIFER = %d,\n", FORMER_AQUIFER);
    printf("    FORMER_LEVEL_TERRAIN = %d,\n", FORMER_LEVEL_TERRAIN);
    // former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
    // select_item's own dependencies, same "compiler-read" discipline.
    printf("    TECH_EcoEng2 = %d,\n", TECH_EcoEng2);
    printf("    MPREF_AUTO_FORMER_REMOVE_FUNGUS = %d,\n", MPREF_AUTO_FORMER_REMOVE_FUNGUS);
    printf("    FORMER_REMOVE_FUNGUS = %d,\n", FORMER_REMOVE_FUNGUS);
    printf("    FORMER_CONDENSER = %d,\n", FORMER_CONDENSER);
    printf("    FORMER_SOIL_ENR = %d,\n", FORMER_SOIL_ENR);
    printf("    BIT_SOIL_ENRICHER = %d,\n", BIT_SOIL_ENRICHER);
    printf("    ALT_ONE_ABOVE_SEA = %d,\n", ALT_ONE_ABOVE_SEA);
    // former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
    // former_move's own dispatch. FormerMode (move.h) is hand-
    // transcribed, same reason as VEH_SYNC/PM_SAFE (move.h pulls in
    // windows.h transitively) -- default enum numbering (move.h:7-8),
    // cross-check there if this ever drifts. Everything else here comes
    // straight from engine_veh.h (already included above), compiler-read.
    printf("    FM_Auto_Full = %d,\n", 0);
    printf("    FM_Auto_Roads = %d,\n", 1);
    printf("    FM_Auto_Tubes = %d,\n", 2);
    printf("    FM_Auto_Sensors = %d,\n", 3);
    printf("    FM_Remove_Fungus = %d,\n", 4);
    printf("    FM_Farm_Road = %d,\n", 5);
    printf("    FM_Mine_Road = %d,\n", 6);
    printf("    ORDER_FARM = %d,\n", ORDER_FARM);
    printf("    ORDER_DRILL_AQUIFER = %d,\n", ORDER_DRILL_AQUIFER);
    printf("    ORDERA_TERRA_AUTO_MAGTUBE = %d,\n", ORDERA_TERRA_AUTO_MAGTUBE);
    printf("    ORDERA_TERRA_AUTO_ROAD = %d,\n", ORDERA_TERRA_AUTO_ROAD);
    printf("    ORDERA_TERRA_AUTO_SENSOR = %d,\n", ORDERA_TERRA_AUTO_SENSOR);
    printf("    ORDERA_TERRA_AUTO_FUNGUS_REM = %d,\n", ORDERA_TERRA_AUTO_FUNGUS_REM);
    printf("    ORDERA_TERRA_FARM_SOLAR_ROAD = %d,\n", ORDERA_TERRA_FARM_SOLAR_ROAD);
    printf("    ORDERA_TERRA_FARM_MINE_ROAD = %d,\n", ORDERA_TERRA_FARM_MINE_ROAD);
    printf("    ORDERA_TERRA_AUTOIMPROVE_BASE = %d,\n", ORDERA_TERRA_AUTOIMPROVE_BASE);
    printf("    VSTATE_ON_ALERT = %d,\n", VSTATE_ON_ALERT);
    printf("  },\n");
    printf("  validation = {\n");
    for (const std::string& row : validation_rows) {
        printf("%s\n", row.c_str());
    }
    printf("  },\n");
    printf("}\n");

    return 0;
}
