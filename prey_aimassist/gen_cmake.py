from pathlib import Path
import xml.etree.ElementTree as ET

root = Path("prey-sdk/src")


def project_sources(project_file: Path):
    tree = ET.parse(project_file)
    result = []
    for node in tree.getroot().iter("File"):
        rel = node.attrib.get("RelativePath")
        if not rel:
            continue
        rel = rel.replace("\\", "/").replace("./", "", 1)
        if not rel.lower().endswith((".cpp", ".c")):
            continue
        excluded = False
        for cfg in node.findall("FileConfiguration"):
            if cfg.attrib.get("Name") == "Release|Win32" and cfg.attrib.get("ExcludedFromBuild", "false").lower() == "true":
                excluded = True
                break
        if not excluded:
            result.append(rel)
    return result


idlib = project_sources(root / "2005idlib.vcproj")
game = project_sources(root / "2005game.vcproj")

if not idlib or not game:
    raise SystemExit(f"Source extraction failed: idlib={len(idlib)} game={len(game)}")


def cmake_list(items):
    return "\n".join(f'    "${{CMAKE_CURRENT_SOURCE_DIR}}/{x}"' for x in items)

cmake = f'''cmake_minimum_required(VERSION 3.20)
project(Prey2006RetailGameDLL LANGUAGES C CXX)

if(NOT MSVC)
    message(FATAL_ERROR "This compatibility build targets 32-bit MSVC/retail PREY.exe")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 4)
    message(FATAL_ERROR "Configure with -A Win32")
endif()

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
set(CMAKE_CXX_STANDARD 98)
set(CMAKE_CXX_STANDARD_REQUIRED OFF)

add_library(idLib STATIC
{cmake_list(idlib)}
)
target_compile_definitions(idLib PRIVATE
    _D3SDK __DOOM__ __IDLIB__ WIN32 NDEBUG _WINDOWS HUMANHEAD _DOTNET_2005
    _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE
)
target_compile_options(idLib PRIVATE
    /O2 /Ob2 /Oi /Ot /Oy /Gy /GR /W3 /MP /Zc:twoPhase-
    /wd4018 /wd4244 /wd4267 /wd4305 /wd4311 /wd4312 /wd4996
)
target_include_directories(idLib PRIVATE "${{CMAKE_CURRENT_SOURCE_DIR}}")

add_library(gamex86 SHARED
{cmake_list(game)}
)
target_compile_definitions(gamex86 PRIVATE
    _D3SDK __DOOM__ GAME_DLL WIN32 NDEBUG _WINDOWS HUMANHEAD _DOTNET_2005
    _CRT_SECURE_NO_WARNINGS _CRT_NONSTDC_NO_DEPRECATE _ALLOW_KEYWORD_MACROS
)
target_compile_options(gamex86 PRIVATE
    /O2 /Ob2 /Oi /Ot /Oy /Gy /GR /W3 /MP /Zc:twoPhase-
    /wd4018 /wd4244 /wd4267 /wd4305 /wd4311 /wd4312 /wd4996
)
target_include_directories(gamex86 PRIVATE "${{CMAKE_CURRENT_SOURCE_DIR}}")
target_link_libraries(gamex86 PRIVATE idLib odbc32 odbccp32)
set_target_properties(gamex86 PROPERTIES
    OUTPUT_NAME "gamex86"
    PREFIX ""
)
target_link_options(gamex86 PRIVATE
    "/DEF:${{CMAKE_CURRENT_SOURCE_DIR}}/game/game.def"
    /MACHINE:X86
    /FIXED:NO
    /STACK:4194304
    /LARGEADDRESSAWARE
    /OPT:REF
    /OPT:ICF
)
'''

(root / "CMakeLists.txt").write_text(cmake, encoding="utf-8")
print(f"Generated CMakeLists.txt with {len(idlib)} idLib and {len(game)} game source files")
