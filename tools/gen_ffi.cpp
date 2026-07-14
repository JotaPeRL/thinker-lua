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
    }});

    emit_struct(stdout, {"CChassis", sizeof(CChassis), alignof(CChassis), {
        FIELD(CChassis, preq_tech),
        FIELD(CChassis, speed),
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
    }});

    emit_struct(stdout, {"Continent", sizeof(Continent), alignof(Continent), {
        FIELD(Continent, tile_count),
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
    }});

    emit_struct(stdout, {"CRules", sizeof(CRules), alignof(CRules), {
        FIELD(CRules, tech_preq_allow_3_nutrients_sq),
        FIELD(CRules, tech_preq_allow_3_minerals_sq),
        FIELD(CRules, tech_preq_allow_3_energy_sq),
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
    printf("    MaxRegionNum = %d,\n", 128);       // main.h:106
    printf("    MaxRegionLandNum = %d,\n", 64);    // main.h:107
    printf("    MaxSocialCatNum = %d,\n", 4);      // main.h:146
    printf("    MaxSocialModelNum = %d,\n", 4);    // main.h:147
    printf("    MaxSocialEffectNum = %d,\n", 11);  // main.h:148
    printf("    GrowthPopBoom = %d,\n", 6);        // main.h:158
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
    printf("  },\n");
    printf("  validation = {\n");
    for (const std::string& row : validation_rows) {
        printf("%s\n", row.c_str());
    }
    printf("  },\n");
    printf("}\n");

    return 0;
}
