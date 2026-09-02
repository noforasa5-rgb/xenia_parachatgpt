from pathlib import Path
import re

src = Path("prey-sdk/src/Prey/prey_weaponfirecontroller.cpp")
text = src.read_text(encoding="latin-1")

include_needle = '#include "prey_local.h"\n'
if include_needle not in text:
    include_needle = '#include "prey_local.h"\r\n'
if include_needle not in text:
    raise SystemExit("Could not locate prey_local.h include")

block = r'''

// -----------------------------------------------------------------------------
// Xbox 360 Aim Assist diagnostic port
// Reconstructed from the retail Xbox 360 default.xex supplied for comparison.
// The original console variables/defaults are preserved here so they can be
// tuned from the Prey console while testing.
// -----------------------------------------------------------------------------
idCVar ui_aimAssist( "ui_aimAssist", "1", CVAR_GAME | CVAR_ARCHIVE | CVAR_BOOL, "Xbox 360 style projectile aim assist" );
idCVar AA_MinDist( "AA_MinDist", "90", CVAR_GAME | CVAR_FLOAT, "Aim Assist Min Distance" );
idCVar AA_MaxDist( "AA_MaxDist", "680", CVAR_GAME | CVAR_FLOAT, "Aim Assist Max Distance" );
idCVar AA_MinDot( "AA_MinDot", "0.98", CVAR_GAME | CVAR_FLOAT, "Aim Assist Min Dot" );
idCVar AA_Width( "AA_Width", "75", CVAR_GAME | CVAR_FLOAT, "Aim Assist Corridor Width" );
idCVar AA_Debug( "AA_Debug", "1", CVAR_GAME | CVAR_BOOL, "Print Xbox 360 aim-assist target selection when firing" );

static idEntity *HH_FindXbox360AimAssistTarget( const idVec3 &muzzlePos, const idMat3 &weaponAxis,
                                                hhPlayer *player, float &outDot,
                                                float &outDistance, float &outWidth ) {
    idEntity *bestTarget = NULL;
    float bestDot = -1.0f;
    float bestDistance = 0.0f;
    float bestWidth = 0.0f;

    const float minDist = AA_MinDist.GetFloat();
    const float maxDist = AA_MaxDist.GetFloat();
    const float minDot = AA_MinDot.GetFloat();
    const float corridorWidth = AA_Width.GetFloat();

    for ( idEntity *ent = gameLocal.spawnedEntities.Next(); ent != NULL; ent = ent->spawnNode.Next() ) {
        if ( ent == player ) {
            continue;
        }
        if ( !ent->IsType( idActor::Type ) ) {
            continue;
        }
        // The retail 360 routine explicitly rejects the crawler class.
        if ( ent->IsType( hhCrawler::Type ) ) {
            continue;
        }
        if ( ent->health <= 0 || ent->fl.hidden || !ent->fl.takedamage ) {
            continue;
        }

        const idVec3 aimPos = ent->GetAimPosition();
        idVec3 toTarget = aimPos - muzzlePos;
        const float distance = toTarget.Normalize();

        if ( distance <= minDist || distance >= maxDist ) {
            continue;
        }

        const float dot = toTarget * weaponAxis[0];
        if ( dot <= minDot || dot <= bestDot ) {
            continue;
        }

        // Xbox 360 computes the lateral corridor from sin(acos(dot))*distance.
        const float clampedDot = idMath::ClampFloat( -1.0f, 1.0f, dot );
        const float lateralWidth = idMath::Sin( idMath::ACos( clampedDot ) ) * distance;
        if ( lateralWidth >= corridorWidth ) {
            continue;
        }

        bestTarget = ent;
        bestDot = dot;
        bestDistance = distance;
        bestWidth = lateralWidth;
    }

    outDot = bestDot;
    outDistance = bestDistance;
    outWidth = bestWidth;
    return bestTarget;
}
'''

if "HH_FindXbox360AimAssistTarget" not in text:
    text = text.replace(include_needle, include_needle + block, 1)

needle = "\tidVec3\t\taimVector( aimTrace.endpos - muzzlePos );"
if needle not in text:
    needle = "\tidVec3\t\taimVector( aimTrace.endpos - muzzlePos );\r"
if needle not in text:
    raise SystemExit("Could not locate DetermineAimAxis aimVector line")

inject = r'''
	// Xbox 360 projectile magnetism. This is intentionally inserted at the
	// same stage as the console routine: after the eye trace/portal handling,
	// but before the final aim vector is built and blended toward weaponAxis.
	if ( ui_aimAssist.GetBool() && !gameLocal.isMultiplayer ) {
		float assistDot = -1.0f;
		float assistDistance = 0.0f;
		float assistWidth = 0.0f;
		idEntity *assistTarget = HH_FindXbox360AimAssistTarget( muzzlePos, weaponAxis, owner.GetEntity(),
			assistDot, assistDistance, assistWidth );
		if ( assistTarget ) {
			aimTrace.endpos = assistTarget->GetAimPosition();
			aimTraceDist = ( aimTrace.endpos - muzzlePos ).Length();
			if ( AA_Debug.GetBool() ) {
				gameLocal.Printf( "[360 AimAssist] target='%s' dist=%.2f dot=%.5f width=%.2f\n",
					assistTarget->GetName(), assistDistance, assistDot, assistWidth );
			}
		}
	}

'''

if "[360 AimAssist]" not in text:
    text = text.replace(needle, inject + needle, 1)

src.write_text(text, encoding="latin-1")
print("Aim-assist patched:", src)

# -----------------------------------------------------------------------------
# Compatibility fixes for the untouched 2006 SDK when compiled by MSVC 2022.
# These do not alter gameplay; they only resolve syntax/name issues tolerated
# by the original Visual C++ 2005 toolchain.
# -----------------------------------------------------------------------------
interp = Path("prey-sdk/src/idLib/math/Interpolate.h")
interp_text = interp.read_text(encoding="latin-1")
old_midpoint = "return idMath::Sin( DEG2RAD(idMath::MidPointLerp(0.0f, 60.0f, 90.0f, frac)) );"
new_midpoint = "return idMath::Sin( DEG2RAD( ( frac <= 0.0f ) ? 0.0f : ( ( frac >= 1.0f ) ? 90.0f : ( ( frac < 0.5f ) ? ( 120.0f * frac ) : ( 60.0f + 60.0f * ( frac - 0.5f ) ) ) ) ) );"
if old_midpoint in interp_text:
    interp_text = interp_text.replace(old_midpoint, new_midpoint, 1)
interp.write_text(interp_text, encoding="latin-1")
print("MSVC compatibility patched:", interp)

# VC2005 accepted constructs such as S_COLOR_WHITE"text" and
# "text"S_COLOR_RED"X". Modern C++ interprets those as user-defined literal
# suffixes. Normalize every source/header occurrence in the official SDK.
source_root = Path("prey-sdk/src")
patched_color_files = 0
for path in source_root.rglob("*"):
    if path.suffix.lower() not in {".cpp", ".c", ".h", ".hpp"}:
        continue
    try:
        source_text = path.read_text(encoding="latin-1")
    except OSError:
        continue
    fixed_text = re.sub(r'(?<=")(S_COLOR_[A-Z]+)', r' \1', source_text)
    fixed_text = re.sub(r'(S_COLOR_[A-Z]+)(?=")', r'\1 ', fixed_text)
    if fixed_text != source_text:
        path.write_text(fixed_text, encoding="latin-1")
        patched_color_files += 1
        print("MSVC color-macro compatibility patched:", path)
print("Color-macro files patched:", patched_color_files)
