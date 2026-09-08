param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  $ccPath = Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.cc"
  if (!(Test-Path $ccPath)) { throw "xbox360_xui_runtime.cc is missing; apply PoC 5 first." }

  $text = [IO.File]::ReadAllText($ccPath)
  if ($text.Contains("XUI-POC6: XAM17559 Ease evaluator ready")) {
    Write-Host "PoC 6 already applied."
    return
  }
  if (!$text.Contains("XUI-POC5: timeline evaluator ready")) {
    throw "PoC 5 evaluator marker is missing; apply PoC 5 first."
  }

  if (!$text.Contains("#include <cmath>")) {
    $includeAnchor = "#include <cstdint>"
    if (!$text.Contains($includeAnchor)) { throw "cstdint include anchor not found." }
    $text = $text.Replace($includeAnchor, $includeAnchor + "`r`n#include <cmath>")
  }

  $helperAnchor = "struct EvaluatedProperty {"
  $helperIndex = $text.IndexOf($helperAnchor)
  if ($helperIndex -lt 0) { throw "EvaluatedProperty anchor not found." }

  $helpers = @'
struct XuiEaseBezier {
  float x1 = 0.0f;
  float y1 = 0.0f;
  float x2 = 1.0f;
  float y2 = 1.0f;
};

int32_t SignedEaseByte(uint8_t value) {
  return value < 0x80u ? int32_t(value) : int32_t(value) - 256;
}

XuiEaseBezier BuildXbox360EaseBezier(const Xbox360XuiKeyframe& keyframe) {
  // Reconstructed from the user's original 17559 xam.xex routine at
  // 0x817BF208. The three XUR bytes are sign-extended, scaled by 0.01f,
  // converted to two angles around pi/4, and used to rotate two handle
  // vectors of length EaseScale. The second handle is translated by (1, 1).
  constexpr float kHundredth = 0.01f;
  constexpr float kPiOver4 = 0.78539816339744830962f;

  const float ease_in = float(SignedEaseByte(keyframe.ease_in));
  const float ease_out = float(SignedEaseByte(keyframe.ease_out));
  const float ease_scale = float(SignedEaseByte(keyframe.ease_scale));

  const float scale = ease_scale * kHundredth;
  const float angle_in = (1.0f - ease_in * kHundredth) * kPiOver4;
  const float angle_out = (1.0f - ease_out * kHundredth) * kPiOver4;

  XuiEaseBezier curve;
  curve.x1 = scale * std::cos(angle_in);
  curve.y1 = scale * std::sin(angle_in);
  curve.x2 = 1.0f - scale * std::cos(angle_out);
  curve.y2 = 1.0f - scale * std::sin(angle_out);
  return curve;
}

float CubicBezierAxis(float u, float p1, float p2) {
  const float one_minus_u = 1.0f - u;
  return 3.0f * one_minus_u * one_minus_u * u * p1 +
         3.0f * one_minus_u * u * u * p2 + u * u * u;
}

float CubicBezierAxisDerivative(float u, float p1, float p2) {
  const float one_minus_u = 1.0f - u;
  return 3.0f * one_minus_u * one_minus_u * p1 +
         6.0f * one_minus_u * u * (p2 - p1) +
         3.0f * u * u * (1.0f - p2);
}

float EvaluateXbox360EaseProgress(float progress,
                                  const Xbox360XuiKeyframe& keyframe) {
  if (progress <= 0.0f) return 0.0f;
  if (progress >= 1.0f) return 1.0f;

  const XuiEaseBezier curve = BuildXbox360EaseBezier(keyframe);

  // XUI uses the Bezier X axis as time, so solve x(u) = progress and then
  // return y(u). Start with Newton-Raphson and keep a bracketed bisection
  // fallback for the notification curves. This reproduces the XAM 17559
  // curve semantics without hardcoding any notification keyframe values.
  float low = 0.0f;
  float high = 1.0f;
  float u = progress;
  for (int i = 0; i < 12; ++i) {
    const float x = CubicBezierAxis(u, curve.x1, curve.x2);
    const float error = x - progress;
    if (std::fabs(error) <= 0.000001f) break;

    if (error < 0.0f) {
      low = u;
    } else {
      high = u;
    }

    const float derivative =
        CubicBezierAxisDerivative(u, curve.x1, curve.x2);
    float candidate = u;
    if (std::fabs(derivative) > 0.000001f) {
      candidate = u - error / derivative;
    }
    if (!(candidate > low && candidate < high)) {
      candidate = (low + high) * 0.5f;
    }
    u = candidate;
  }

  // Finish with a few deterministic bisection iterations. The notification
  // Ease curves are monotonic in X, and this keeps the result stable across
  // host math-library differences.
  for (int i = 0; i < 10; ++i) {
    const float x = CubicBezierAxis(u, curve.x1, curve.x2);
    if (std::fabs(x - progress) <= 0.0000005f) break;
    if (x < progress) {
      low = u;
    } else {
      high = u;
    }
    u = (low + high) * 0.5f;
  }

  return CubicBezierAxis(u, curve.y1, curve.y2);
}

'@
  $text = $text.Insert($helperIndex, $helpers)

  $evalStartMarker = "  const PropertyKind kind = timeline.properties[property_index].kind;"
  $evalStart = $text.IndexOf($evalStartMarker)
  if ($evalStart -lt 0) { throw "PoC 5 evaluator body start not found." }
  $evalEndMarker = "const TimelineDetails* FindTimeline"
  $evalEnd = $text.IndexOf($evalEndMarker, $evalStart)
  if ($evalEnd -lt 0) { throw "PoC 5 evaluator body end not found." }

  $newEvaluatorTail = @'
  const PropertyKind kind = timeline.properties[property_index].kind;
  if (kind == PropertyKind::kBool || kind == PropertyKind::kUnsigned ||
      kind == PropertyKind::kString) {
    out.value = std::move(left_value);
    out.valid = true;
    out.mode = left_key.flags == 2 ? "Hold(discrete/Ease)"
                                   : "Hold(discrete)";
    return true;
  }

  if (left_key.flags != 0 && left_key.flags != 2 && left_key.flags != 3) {
    out.mode = "UnsupportedInterpolation";
    return false;
  }

  EvaluatedValue right_value;
  if (!ResolveTypedValue(summary, details, right_key, property_index,
                         timeline.properties[property_index], right_value)) {
    return false;
  }
  const float denom = float(right_key.frame - left_key.frame);
  if (denom <= 0.0f) return false;
  const float linear_t = float(frame - left_key.frame) / denom;
  const float t = left_key.flags == 2
                      ? EvaluateXbox360EaseProgress(linear_t, left_key)
                      : linear_t;

  out.value = left_value;
  if (kind == PropertyKind::kFloat) {
    out.value.float_value =
        left_value.float_value +
        (right_value.float_value - left_value.float_value) * t;
  } else if (kind == PropertyKind::kVector) {
    out.value.vector_value.x =
        left_value.vector_value.x +
        (right_value.vector_value.x - left_value.vector_value.x) * t;
    out.value.vector_value.y =
        left_value.vector_value.y +
        (right_value.vector_value.y - left_value.vector_value.y) * t;
    out.value.vector_value.z =
        left_value.vector_value.z +
        (right_value.vector_value.z - left_value.vector_value.z) * t;
  } else {
    return false;
  }
  out.value.valid = true;
  out.valid = true;
  out.mode = left_key.flags == 2 ? "Ease(XAM17559)" : "Linear";
  return true;
}

'@

  $text = $text.Substring(0, $evalStart) + $newEvaluatorTail +
          $text.Substring($evalEnd)

  $readyAnchor = @'
  const bool ready = control_flow_ok && playhead_ok && linear_midpoint_ok &&
                     failed_samples == 0;
'@
  if (!$text.Contains($readyAnchor)) { throw "PoC 5 diagnostic ready expression not found." }

  $easeSelfCheck = @'
  bool ease_selfcheck_ok = false;
  if (const auto* logo = FindTimeline(details, "xenonLogo1")) {
    const size_t base = logo->probe.keyframe_base_index;
    if (logo->probe.keyframe_count > 1 && base + 1 < summary.keyframes.size()) {
      const auto& key = summary.keyframes[base + 1];
      const XuiEaseBezier curve = BuildXbox360EaseBezier(key);
      const float eased = EvaluateXbox360EaseProgress(0.5625f, key);
      const bool raw_ok = key.frame == 5 && key.flags == 2 &&
                          key.ease_in == 0 && key.ease_out == 100 &&
                          key.ease_scale == 50;
      const bool controls_ok =
          std::fabs(curve.x1 - 0.35355339f) < 0.00001f &&
          std::fabs(curve.y1 - 0.35355339f) < 0.00001f &&
          std::fabs(curve.x2 - 0.5f) < 0.00001f &&
          std::fabs(curve.y2 - 1.0f) < 0.00001f;
      const bool progress_ok = std::fabs(eased - 0.78285515f) < 0.00002f;
      ease_selfcheck_ok = raw_ok && controls_ok && progress_ok;
      XELOGI(
          "XUI-POC6: ease-check object='xenonLogo1' key=5 raw={}/{}/{} controls=({},{})({},{}) frame23_progress={} ok={}",
          SignedEaseByte(key.ease_in), SignedEaseByte(key.ease_out),
          SignedEaseByte(key.ease_scale), FormatFloat(curve.x1),
          FormatFloat(curve.y1), FormatFloat(curve.x2),
          FormatFloat(curve.y2), FormatFloat(eased), ease_selfcheck_ok);
    }
  }

  if (const auto* bg_curve = FindTimeline(details, "bgCurve1")) {
    const size_t base = bg_curve->probe.keyframe_base_index;
    for (size_t i = 0; i < bg_curve->probe.keyframe_count; ++i) {
      const auto& key = summary.keyframes[base + i];
      if (key.frame != 27 || key.flags != 2) continue;
      const float linear_t = 11.0f / 17.0f;
      const float eased = EvaluateXbox360EaseProgress(linear_t, key);
      const bool identity_ok = std::fabs(eased - linear_t) < 0.00002f;
      XELOGI(
          "XUI-POC6: ease-identity-check object='bgCurve1' key=27 raw={}/{}/{} t={} eased={} ok={}",
          SignedEaseByte(key.ease_in), SignedEaseByte(key.ease_out),
          SignedEaseByte(key.ease_scale), FormatFloat(linear_t),
          FormatFloat(eased), identity_ok);
      ease_selfcheck_ok = ease_selfcheck_ok && identity_ok;
      break;
    }
  }

  const bool ready = control_flow_ok && playhead_ok && linear_midpoint_ok &&
                     ease_selfcheck_ok && failed_samples == 0;
'@
  $text = $text.Replace($readyAnchor, $easeSelfCheck)

  $oldFinalLog = @'
  XELOGI(
      "XUI-POC5: timeline evaluator ready={} playhead_ok={} samples_failed={} ease_interpolations_deferred={} exact_modes=None/Linear",
      ready, playhead_ok, failed_samples, ease_deferred_count);
  return ready;
'@
  if (!$text.Contains($oldFinalLog)) { throw "PoC 5 final diagnostic log not found." }
  $newFinalLog = @'
  XELOGI(
      "XUI-POC6: timeline evaluator ready={} playhead_ok={} samples_failed={} ease_interpolations_deferred={} ease_selfcheck={} exact_modes=None/Linear/Ease(XAM17559)",
      ready, playhead_ok, failed_samples, ease_deferred_count,
      ease_selfcheck_ok);
  XELOGI("XUI-POC6: XAM17559 Ease evaluator ready={}", ready);
  return ready;
'@
  $text = $text.Replace($oldFinalLog, $newFinalLog)

  # Promote the existing PoC 5 diagnostic prefixes so a PoC 6 test log can be
  # filtered with one marker while preserving the same playhead diagnostics.
  $text = $text.Replace("XUI-POC5:", "XUI-POC6:")
  $text = $text.Replace("exact_modes=None/Linear/Ease(XAM17559)",
                        "exact_modes=None/Linear/Ease(XAM17559)")

  [IO.File]::WriteAllText($ccPath, $text, [Text.UTF8Encoding]::new($false))
  Write-Host "Applied Xbox 360 XUI runtime PoC 6 XAM-derived Ease evaluator."
} finally {
  Pop-Location
}
