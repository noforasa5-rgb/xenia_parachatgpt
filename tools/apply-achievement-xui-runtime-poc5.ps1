param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  $ccPath = Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.cc"
  if (!(Test-Path $ccPath)) { throw "xbox360_xui_runtime.cc is missing; apply PoC 4 first." }
  $text = [IO.File]::ReadAllText($ccPath)
  if ($text.Contains("XUI-POC5: timeline evaluator ready")) {
    Write-Host "PoC 5 already applied."
    return
  }

  $insert = @'
struct EvaluatedValue {
  PropertyKind kind = PropertyKind::kUnknown;
  bool valid = false;
  bool bool_value = false;
  uint32_t unsigned_value = 0;
  float float_value = 0.0f;
  Vec3 vector_value{};
  std::string string_value;
};

bool ResolveTypedValue(const Xbox360XuiFileSummary& summary,
                       const ParsedDetails& details,
                       const Xbox360XuiKeyframe& keyframe,
                       size_t animated_property_index,
                       const PropertyDescriptor& property,
                       EvaluatedValue& out) {
  out = {};
  out.kind = property.kind;
  const size_t keyp_offset =
      size_t(keyframe.property_index) + animated_property_index;
  if (keyp_offset >= summary.keyp_indexes.size()) return false;
  const uint32_t value_index = summary.keyp_indexes[keyp_offset];

  switch (property.kind) {
    case PropertyKind::kBool:
      out.bool_value = value_index != 0;
      out.valid = true;
      return true;
    case PropertyKind::kUnsigned:
      out.unsigned_value = value_index;
      out.valid = true;
      return true;
    case PropertyKind::kFloat:
      if (value_index >= details.floats.size()) return false;
      out.float_value = details.floats[value_index];
      out.valid = true;
      return true;
    case PropertyKind::kVector:
      if (value_index >= details.vectors.size()) return false;
      out.vector_value = details.vectors[value_index];
      out.valid = true;
      return true;
    case PropertyKind::kString:
      if (value_index >= summary.strings.size()) return false;
      out.string_value = summary.strings[value_index];
      out.valid = true;
      return true;
    default:
      return false;
  }
}

std::string FormatEvaluatedValue(const EvaluatedValue& value) {
  if (!value.valid) return "<unresolved>";
  switch (value.kind) {
    case PropertyKind::kBool:
      return value.bool_value ? "true" : "false";
    case PropertyKind::kUnsigned:
      return std::to_string(value.unsigned_value);
    case PropertyKind::kFloat:
      return FormatFloat(value.float_value);
    case PropertyKind::kVector: {
      std::ostringstream stream;
      stream << "(" << FormatFloat(value.vector_value.x) << ","
             << FormatFloat(value.vector_value.y) << ","
             << FormatFloat(value.vector_value.z) << ")";
      return stream.str();
    }
    case PropertyKind::kString:
      return "\"" + value.string_value + "\"";
    default:
      return "<unknown>";
  }
}

struct EvaluatedProperty {
  EvaluatedValue value;
  bool valid = false;
  bool exact_key = false;
  bool ease_deferred = false;
  const char* mode = "unresolved";
  uint32_t left_frame = 0;
  uint32_t right_frame = 0;
};

bool EvaluatePropertyAtFrame(const Xbox360XuiFileSummary& summary,
                             const ParsedDetails& details,
                             const TimelineDetails& timeline,
                             size_t property_index, uint32_t frame,
                             EvaluatedProperty& out) {
  out = {};
  if (property_index >= timeline.properties.size() ||
      timeline.probe.keyframe_count == 0) {
    return false;
  }
  const size_t base = timeline.probe.keyframe_base_index;
  const size_t count = timeline.probe.keyframe_count;
  if (base >= summary.keyframes.size() ||
      count > summary.keyframes.size() - base) {
    return false;
  }

  size_t left = 0;
  size_t right = 0;
  if (frame <= summary.keyframes[base].frame) {
    left = right = 0;
  } else if (frame >= summary.keyframes[base + count - 1].frame) {
    left = right = count - 1;
  } else {
    for (size_t i = 0; i + 1 < count; ++i) {
      const uint32_t a = summary.keyframes[base + i].frame;
      const uint32_t b = summary.keyframes[base + i + 1].frame;
      if (frame == a) {
        left = right = i;
        break;
      }
      if (frame > a && frame < b) {
        left = i;
        right = i + 1;
        break;
      }
      if (frame == b) {
        left = right = i + 1;
        break;
      }
    }
  }

  const auto& left_key = summary.keyframes[base + left];
  const auto& right_key = summary.keyframes[base + right];
  out.left_frame = left_key.frame;
  out.right_frame = right_key.frame;

  EvaluatedValue left_value;
  if (!ResolveTypedValue(summary, details, left_key, property_index,
                         timeline.properties[property_index], left_value)) {
    return false;
  }

  if (left == right || frame == left_key.frame) {
    out.value = std::move(left_value);
    out.valid = true;
    out.exact_key = true;
    out.mode = "Exact";
    return true;
  }

  // XUI keyframe interpolation is carried by the left keyframe. None is a
  // discrete hold. Linear is exact for numeric/vector values. Boolean,
  // unsigned and string properties are discrete even if a key is marked
  // Linear. Ease is intentionally preserved/deferred until its Xbox 360 XUI
  // easing equation is independently verified; we do not invent a curve.
  if (left_key.flags == 1) {
    out.value = std::move(left_value);
    out.valid = true;
    out.mode = "Hold(None)";
    return true;
  }

  const PropertyKind kind = timeline.properties[property_index].kind;
  if (kind == PropertyKind::kBool || kind == PropertyKind::kUnsigned ||
      kind == PropertyKind::kString) {
    out.value = std::move(left_value);
    out.valid = true;
    out.mode = left_key.flags == 2 ? "Hold(discrete/Ease)"
                                   : "Hold(discrete)";
    if (left_key.flags == 2) out.ease_deferred = true;
    return true;
  }

  if (left_key.flags == 2) {
    out.ease_deferred = true;
    out.mode = "Ease(deferred)";
    return true;
  }
  if (left_key.flags != 0) {
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
  const float t = float(frame - left_key.frame) / denom;
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
  out.mode = "Linear";
  return true;
}

const TimelineDetails* FindTimeline(const ParsedDetails& details,
                                    const std::string& object_name) {
  for (const auto& timeline : details.notification_timelines) {
    if (timeline.probe.object_name == object_name) return &timeline;
  }
  return nullptr;
}

const Xbox360XuiNamedFrame* FindNamedFrame(
    const Xbox360XuiFileSummary& summary, const std::string& name,
    uint32_t preferred_frame) {
  const Xbox360XuiNamedFrame* fallback = nullptr;
  for (const auto& named : summary.named_frames) {
    if (named.name != name) continue;
    if (!fallback) fallback = &named;
    if (named.frame == preferred_frame) return &named;
  }
  return fallback;
}

bool LogEvaluatorSnapshot(const Xbox360XuiFileSummary& summary,
                          const ParsedDetails& details,
                          const std::string& object_name, uint32_t frame,
                          size_t& ease_deferred_count) {
  const TimelineDetails* timeline = FindTimeline(details, object_name);
  if (!timeline) return false;
  std::ostringstream values;
  bool ok = true;
  for (size_t p = 0; p < timeline->properties.size(); ++p) {
    if (p) values << "; ";
    EvaluatedProperty evaluated;
    const bool resolved = EvaluatePropertyAtFrame(summary, details, *timeline,
                                                  p, frame, evaluated);
    if (!resolved || !evaluated.valid) ok = false;
    if (evaluated.ease_deferred) ++ease_deferred_count;
    values << timeline->properties[p].name << "=";
    if (evaluated.ease_deferred && !evaluated.valid) {
      values << "<ease-deferred " << evaluated.left_frame << ".."
             << evaluated.right_frame << ">";
    } else {
      values << FormatEvaluatedValue(evaluated.value);
    }
    values << "{" << evaluated.mode << "}";
  }
  XELOGI("XUI-POC5: sample object='{}' frame={} values=[{}]", object_name,
         frame, values.str());
  return ok;
}

bool RunTimelineEvaluatorDiagnostics(const Xbox360XuiFileSummary& summary,
                                     const ParsedDetails& details) {
  const auto* trans_to = FindNamedFrame(summary, "TransTo", 0);
  const auto* loop = FindNamedFrame(summary, "loop", 65);
  const auto* end_trans_to = FindNamedFrame(summary, "EndTransTo", 185);
  const auto* trans_from = FindNamedFrame(summary, "TransFrom", 186);
  const auto* end_trans_from = FindNamedFrame(summary, "EndTransFrom", 240);

  const bool control_flow_ok =
      trans_to && trans_to->frame == 0 && loop && loop->frame == 65 &&
      end_trans_to && end_trans_to->frame == 185 &&
      end_trans_to->command == 3 && end_trans_to->target == "loop" &&
      trans_from && trans_from->frame == 186 && end_trans_from &&
      end_trans_from->frame == 240 && end_trans_from->command == 1;
  XELOGI(
      "XUI-POC5: control-flow verified={} TransTo={} loop={} EndTransTo={} command={} target='{}' TransFrom={} EndTransFrom={} command={}",
      control_flow_ok, trans_to ? trans_to->frame : 0,
      loop ? loop->frame : 0, end_trans_to ? end_trans_to->frame : 0,
      end_trans_to ? end_trans_to->command : 0,
      end_trans_to ? end_trans_to->target : "",
      trans_from ? trans_from->frame : 0,
      end_trans_from ? end_trans_from->frame : 0,
      end_trans_from ? end_trans_from->command : 0);

  // 60 ticks/s is a PoC timing assumption based on the original 60-frame
  // logo/trophy intervals. This build logs the assumption rather than treating
  // it as a proven format constant.
  constexpr uint32_t kTickRateAssumption = 60;
  XELOGI(
      "XUI-POC5: playhead tick-rate assumption={} Hz (diagnostic, not yet claimed as XUR format constant)",
      kTickRateAssumption);

  // Simulate two natural 65..185 loops, then an external notification close
  // request that starts TransFrom at 186. The original NAME command at 185 is
  // respected while the notification remains open.
  uint32_t frame = 0;
  uint32_t loops = 0;
  bool closing = false;
  bool stopped = false;
  for (uint32_t tick = 0; tick < 1000 && !stopped; ++tick) {
    if (!closing && frame == 185) {
      ++loops;
      if (loops < 3) {
        XELOGI("XUI-POC5: playhead GoToAndPlay frame=185 -> 65 target='loop' pass={}",
               loops);
        frame = 65;
        continue;
      }
      closing = true;
      frame = 186;
      XELOGI(
          "XUI-POC5: diagnostic external-close after loop pass={} -> TransFrom frame=186",
          loops);
      continue;
    }
    if (closing && frame == 240) {
      XELOGI("XUI-POC5: playhead Stop at EndTransFrom frame=240");
      stopped = true;
      break;
    }
    ++frame;
  }
  const bool playhead_ok = stopped && loops == 3;

  static const std::array<uint32_t, 15> kSampleFrames = {
      0, 5, 23, 38, 44, 60, 65, 70, 120, 125, 130, 180, 185, 186, 240};
  static const std::array<const char*, 4> kSampleObjects = {
      "bgCurve1", "Image", "xenonLogo1", "TextPresenter"};
  size_t ease_deferred_count = 0;
  size_t failed_samples = 0;
  for (uint32_t sample_frame : kSampleFrames) {
    for (const char* object_name : kSampleObjects) {
      if (!LogEvaluatorSnapshot(summary, details, object_name, sample_frame,
                                ease_deferred_count)) {
        ++failed_samples;
      }
    }
  }

  // Exercise one known pure-linear midpoint numerically. Image opacity from
  // frame 65 (0) to frame 70 (1) is Linear, so frame 67 must resolve to 0.4.
  bool linear_midpoint_ok = false;
  if (const auto* image = FindTimeline(details, "Image")) {
    EvaluatedProperty evaluated;
    for (size_t p = 0; p < image->properties.size(); ++p) {
      if (image->properties[p].name != "Opacity") continue;
      if (EvaluatePropertyAtFrame(summary, details, *image, p, 67,
                                  evaluated) &&
          evaluated.valid && evaluated.value.kind == PropertyKind::kFloat) {
        const float delta = evaluated.value.float_value - 0.4f;
        linear_midpoint_ok = delta > -0.0001f && delta < 0.0001f;
        XELOGI(
            "XUI-POC5: linear-check Image.Opacity frame=67 value={} expected=0.400000 ok={}",
            FormatFloat(evaluated.value.float_value), linear_midpoint_ok);
      }
    }
  }

  const bool ready = control_flow_ok && playhead_ok && linear_midpoint_ok &&
                     failed_samples == 0;
  XELOGI(
      "XUI-POC5: timeline evaluator ready={} playhead_ok={} samples_failed={} ease_interpolations_deferred={} exact_modes=None/Linear",
      ready, playhead_ok, failed_samples, ease_deferred_count);
  return ready;
}

'@

  $getAnchor = "Xbox360XuiRuntime& Xbox360XuiRuntime::Get()"
  $getIndex = $text.IndexOf($getAnchor)
  if ($getIndex -lt 0) { throw "Runtime Get() anchor not found." }
  $namespaceIndex = $text.LastIndexOf("}  // namespace", $getIndex)
  if ($namespaceIndex -lt 0) { throw "Anonymous namespace closing anchor not found." }
  $text = $text.Insert($namespaceIndex, $insert)

  $callAnchor = "LogResolvedNotificationTimelines(skin_summary_, skin_details);"
  $callIndex = $text.IndexOf($callAnchor)
  if ($callIndex -lt 0) { throw "PoC 4 property logging call not found." }
  $callEnd = $callIndex + $callAnchor.Length
  $text = $text.Insert($callEnd,
      "`r`n`r`n  const bool timeline_evaluator_ok =`r`n      RunTimelineEvaluatorDiagnostics(skin_summary_, skin_details);")

  $oldReady = "all_known_flags && property_values_ok;"
  if (!$text.Contains($oldReady)) { throw "PoC 4 ready expression not found." }
  $text = $text.Replace($oldReady,
      "all_known_flags && property_values_ok && timeline_evaluator_ok;")

  $oldLog = '  XELOGI("XUI-POC4: runtime property binding ready={}", ready_);'
  if (!$text.Contains($oldLog)) { throw "PoC 4 final ready log not found." }
  $newLog = $oldLog + "`r`n" +
      '  XELOGI("XUI-POC5: runtime timeline evaluator ready={}", ready_);'
  $text = $text.Replace($oldLog, $newLog)

  [IO.File]::WriteAllText($ccPath, $text, [Text.UTF8Encoding]::new($false))
  Write-Host "Applied XUI runtime PoC 5 playhead and None/Linear evaluator diagnostics."
} finally {
  Pop-Location
}
