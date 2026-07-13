cmake_minimum_required(VERSION 3.31)

# Fail on missing -B to not add build files in source root
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR "You need to specify -B where build files are saved")
endif()

# Enable static linking by default on develop/release versions
option(MOD_STATIC_LINK "Enable static linking on develop/release thinkerlib" ON)

project(thinker C CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CXX_COMPILER i686-w64-mingw32-g++)
set(CMAKE_C_COMPILER i686-w64-mingw32-gcc)
set(CMAKE_RC_COMPILER i686-w64-mingw32-windres)
enable_language(RC)

# Use GNU windres style for RC compile rule
set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> -O coff <DEFINES> <INCLUDES> <FLAGS> -i <SOURCE> -o <OBJECT>")

# ---------- Common compiler flags ----------
set(COMMON_CXX_FLAGS "-pedantic -Wall -Wextra -Wshadow -Wundef -Wuseless-cast -Wpointer-arith -Wfloat-conversion")

# Add custom 'Develop' configuration
if(CMAKE_CONFIGURATION_TYPES)
    list(APPEND CMAKE_CONFIGURATION_TYPES Develop)
    list(REMOVE_DUPLICATES CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_CONFIGURATION_TYPES "${CMAKE_CONFIGURATION_TYPES}" CACHE STRING "" FORCE)
else()
    # Set possible values for single-config generators
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Release" "Develop")
endif()

# ---------- Output directories (place artifacts under source-root build/<config>) ----------
set(THINKER_OUTPUT_BASE "${CMAKE_SOURCE_DIR}/build")

# ---------- Debug ----------
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} ${COMMON_CXX_FLAGS} -g -Og -DBUILD_DEBUG")

# ---------- Develop ----------
set(CMAKE_CXX_FLAGS_DEVELOP "${CMAKE_CXX_FLAGS_DEVELOP} ${COMMON_CXX_FLAGS} -O2 -fno-common -fno-strict-overflow -fno-strict-aliasing -fno-delete-null-pointer-checks -fno-optimize-sibling-calls")

# ---------- Release ----------
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_DEVELOP} -DBUILD_REL")

# ---------- Thinker lib ----------
file(GLOB THINKER_LIB_SOURCES
    "src/*.cpp"
    "src/lib/*.c"
)
set_source_files_properties(src/lib/ini.c PROPERTIES LANGUAGE C)

# Remove thinker launcher files
list(REMOVE_ITEM THINKER_LIB_SOURCES
        "${CMAKE_CURRENT_SOURCE_DIR}/src/launch.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/src/launch.h"
)
add_library(thinkerlib SHARED ${THINKER_LIB_SOURCES})
target_compile_options(thinkerlib PRIVATE
    -march=pentium4
    -mtune=generic
)
target_link_options(thinkerlib PRIVATE
    $<$<OR:$<CONFIG:Release>,$<CONFIG:Develop>>:-s>
    $<$<AND:$<BOOL:${MOD_STATIC_LINK}>,$<OR:$<CONFIG:Release>,$<CONFIG:Develop>>>:-static>
)
target_compile_definitions(thinkerlib PRIVATE BUILD_DLL)
set_target_properties(thinkerlib PROPERTIES PREFIX "" OUTPUT_NAME "thinker" SUFFIX ".dll")
target_link_libraries(thinkerlib PRIVATE user32 gdi32 winmm psapi)

# ---------- LuaJIT (vendored submodule, cross-compiled static) ----------
# Single libluajit.a shared by all configs: LuaJIT is always built optimized,
# and its makefile is not parallel-safe across configs in the same source dir.
# Host tools (minilua/buildvm) need the target pointer size => HOST_CC gcc -m32.
set(LUAJIT_DIR ${CMAKE_SOURCE_DIR}/third_party/luajit/src)
add_custom_command(OUTPUT ${LUAJIT_DIR}/libluajit.a
    COMMAND make -C ${LUAJIT_DIR} "HOST_CC=gcc -m32"
            CROSS=i686-w64-mingw32- TARGET_SYS=Windows BUILDMODE=static libluajit.a
    COMMENT "Cross-compiling LuaJIT (static, i686)"
    VERBATIM)
add_custom_target(luajit DEPENDS ${LUAJIT_DIR}/libluajit.a)
add_dependencies(thinkerlib luajit)
target_include_directories(thinkerlib PRIVATE ${LUAJIT_DIR})
target_link_libraries(thinkerlib PRIVATE ${LUAJIT_DIR}/libluajit.a)

# ---------- gen_ffi (cdef generator, native host tool) ----------
# Produces lua/ffi/types.lua from the engine struct headers. Compiled with
# the *native* host compiler (not the project-wide i686-w64-mingw32-g++ set
# above) at -m32: sizeof/alignof/offsetof are pure compiler-frontend values
# that don't require running on the real target OS, and the real safety net
# is the startup validation inside thinker.dll itself (src/luaai.cpp), which
# re-checks every value emitted here against the actual mingw-compiled
# LuaJIT at game launch (IMPLEMENTATION_PLAN.md Phase 3.1). Invoked as a raw
# shell command rather than add_executable(), since CMAKE_CXX_COMPILER is
# overridden project-wide and an add_executable() target would inherit it.
find_program(HOST_CXX NAMES g++ c++)
if(NOT HOST_CXX)
    message(FATAL_ERROR "gen_ffi needs a native host C++ compiler (g++/c++) to build; none found on PATH")
endif()

add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/gen_ffi
    COMMAND ${HOST_CXX} -m32 -std=gnu++11 -I${CMAKE_SOURCE_DIR}/src
            -o ${CMAKE_BINARY_DIR}/gen_ffi ${CMAKE_SOURCE_DIR}/tools/gen_ffi.cpp
    DEPENDS ${CMAKE_SOURCE_DIR}/tools/gen_ffi.cpp
    COMMENT "Building gen_ffi (native host tool, -m32)"
    VERBATIM)
add_custom_command(OUTPUT ${CMAKE_SOURCE_DIR}/lua/ffi/types.lua
    COMMAND ${CMAKE_BINARY_DIR}/gen_ffi > ${CMAKE_SOURCE_DIR}/lua/ffi/types.lua
    DEPENDS ${CMAKE_BINARY_DIR}/gen_ffi
    COMMENT "Generating lua/ffi/types.lua from engine struct layout"
    VERBATIM)
add_custom_target(gen_ffi_types DEPENDS ${CMAKE_SOURCE_DIR}/lua/ffi/types.lua)
add_dependencies(thinkerlib gen_ffi_types)

# ---------- Launch executable ----------
file(GLOB THINKER_LAUNCH_SOURCES
    "src/launch.*"
)
# Ensure resource file is compiled as RC
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/src/launch.rc PROPERTIES LANGUAGE RC)

add_executable(thinker ${THINKER_LAUNCH_SOURCES})
target_compile_options(thinker PRIVATE
    $<$<CONFIG:Release>:-DBUILD_REL>
)
target_link_options(thinker PRIVATE
    $<$<OR:$<CONFIG:Release>,$<CONFIG:Develop>>:-s -static>
)
set_target_properties(thinker PROPERTIES PREFIX "" SUFFIX ".exe")
target_link_libraries(thinker PRIVATE thinkerlib user32)
