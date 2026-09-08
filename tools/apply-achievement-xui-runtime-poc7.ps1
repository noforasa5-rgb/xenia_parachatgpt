param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  $headerPath = Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.h"
  $ccPath = Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.cc"
  $guestHeaderPath = Join-Path (Get-Location) "src/xenia/ui/imgui_guest_notification.h"
  $guestCcPath = Join-Path (Get-Location) "src/xenia/ui/imgui_guest_notification.cc"

  foreach ($p in @($headerPath, $ccPath, $guestHeaderPath, $guestCcPath)) {
    if (!(Test-Path $p)) { throw "Required file missing: $p" }
  }

  # --------------------------------------------------------------------------
  # Runtime public snapshot API. Values are still evaluated from the user's
  # original skin.xur through the PoC 4/5/6 DATA -> KEYD -> KEYP path.
  # --------------------------------------------------------------------------
  $header = [IO.File]::ReadAllText($headerPath)
  if (!$header.Contains("Xbox360XuiNotificationSnapshot")) {
    $classAnchor = "class Xbox360XuiRuntime {"
    $idx = $header.IndexOf($classAnchor)
    if ($idx -lt 0) { throw "Runtime class anchor not found." }
    $snapshotTypes = @'
struct Xbox360XuiVisualState {
  bool show = true;
  float opacity = 1.0f;
  float scale_x = 1.0f;
  float scale_y = 1.0f;
  float scale_z = 1.0f;
  float position_x = 0.0f;
  float position_y = 0.0f;
  float position_z = 0.0f;
};

struct Xbox360XuiNotificationSnapshot {
  bool valid = false;
  uint32_t frame = 0;
  Xbox360XuiVisualState bg_curve;
  Xbox360XuiVisualState round;
  Xbox360XuiVisualState logo_back;
  Xbox360XuiVisualState bg;
  Xbox360XuiVisualState explosion;
  Xbox360XuiVisualState indicator1;
  Xbox360XuiVisualState indicator2;
  Xbox360XuiVisualState indicator3;
  Xbox360XuiVisualState indicator4;
  Xbox360XuiVisualState xenon_logo;
  Xbox360XuiVisualState image;
  Xbox360XuiVisualState text;
};

'@
    $header = $header.Insert($idx, $snapshotTypes)

    $readyAnchor = "  bool ready() const { return ready_; }"
    if (!$header.Contains($readyAnchor)) { throw "Runtime ready() declaration not found." }
    $header = $header.Replace(
        $readyAnchor,
        $readyAnchor + "`r`n  bool EvaluateNotificationSnapshot(`r`n      uint32_t frame, Xbox360XuiNotificationSnapshot& out) const;")
    [IO.File]::WriteAllText($headerPath, $header, [Text.UTF8Encoding]::new($false))
  }

  # --------------------------------------------------------------------------
  # Keep the parsed 17559 notification details alive after Initialize and expose
  # a frame snapshot for the renderer. No notification keyframe values are
  # hardcoded here.
  # --------------------------------------------------------------------------
  $cc = [IO.File]::ReadAllText($ccPath)
  if (!$cc.Contains("XUI-POC7: snapshot evaluator ready")) {
    $parsedAnchor = @'
struct ParsedDetails {
  std::vector<float> floats;
  std::vector<Vec3> vectors;
  std::vector<std::array<float, 4>> quaternions;
  std::vector<uint32_t> colours;
  std::vector<TimelineDetails> notification_timelines;
};
'@
    if (!$cc.Contains($parsedAnchor)) { throw "ParsedDetails definition not found." }
    $parsedReplacement = $parsedAnchor + @'

ParsedDetails g_xui_poc7_skin_details;
bool g_xui_poc7_skin_details_ready = false;
'@
    $cc = $cc.Replace($parsedAnchor, $parsedReplacement)

    $parseAnchor = @'
  const bool skin_ok =
      ParseXur8(root_path_ / "skin.xur", skin_summary_, skin_details);
'@
    if (!$cc.Contains($parseAnchor)) { throw "skin.xur ParseXur8 call not found." }
    $cc = $cc.Replace($parseAnchor, $parseAnchor + @'
  g_xui_poc7_skin_details = skin_details;
  g_xui_poc7_skin_details_ready = skin_ok;
'@)

    $namespaceEndAnchor = "}  // namespace`r`n`r`nXbox360XuiRuntime& Xbox360XuiRuntime::Get()"
    $namespaceEnd = $cc.IndexOf($namespaceEndAnchor)
    if ($namespaceEnd -lt 0) {
      $namespaceEndAnchor = "}  // namespace`n`nXbox360XuiRuntime& Xbox360XuiRuntime::Get()"
      $namespaceEnd = $cc.IndexOf($namespaceEndAnchor)
    }
    if ($namespaceEnd -lt 0) { throw "Anonymous namespace end anchor not found." }

    $snapshotHelper = @'
bool EvaluateVisualStateForPoc7(const Xbox360XuiFileSummary& summary,
                                const ParsedDetails& details,
                                const char* object_name, uint32_t frame,
                                Xbox360XuiVisualState& state) {
  const TimelineDetails* timeline = FindTimeline(details, object_name);
  if (!timeline) return false;

  for (size_t p = 0; p < timeline->properties.size(); ++p) {
    const auto& property = timeline->properties[p];
    EvaluatedProperty evaluated;
    if (!EvaluatePropertyAtFrame(summary, details, *timeline, p, frame,
                                 evaluated) ||
        !evaluated.valid || !evaluated.value.valid) {
      return false;
    }

    if (property.name == "Show" &&
        evaluated.value.kind == PropertyKind::kBool) {
      state.show = evaluated.value.bool_value;
    } else if (property.name == "Opacity" &&
               evaluated.value.kind == PropertyKind::kFloat) {
      state.opacity = evaluated.value.float_value;
    } else if (property.name == "Scale" &&
               evaluated.value.kind == PropertyKind::kVector) {
      state.scale_x = evaluated.value.vector_value.x;
      state.scale_y = evaluated.value.vector_value.y;
      state.scale_z = evaluated.value.vector_value.z;
    } else if (property.name == "Position" &&
               evaluated.value.kind == PropertyKind::kVector) {
      state.position_x = evaluated.value.vector_value.x;
      state.position_y = evaluated.value.vector_value.y;
      state.position_z = evaluated.value.vector_value.z;
    }
  }
  return true;
}

'@
    $cc = $cc.Insert($namespaceEnd, $snapshotHelper)

    $initializeAnchor = "bool Xbox360XuiRuntime::Initialize(const std::filesystem::path& root_path)"
    $initializeIndex = $cc.IndexOf($initializeAnchor)
    if ($initializeIndex -lt 0) { throw "Initialize method anchor not found." }

    $snapshotMethod = @'
bool Xbox360XuiRuntime::EvaluateNotificationSnapshot(
    uint32_t frame, Xbox360XuiNotificationSnapshot& out) const {
  out = {};
  out.frame = frame;
  if (!ready_ || !g_xui_poc7_skin_details_ready) return false;

  const ParsedDetails& details = g_xui_poc7_skin_details;
  bool ok = true;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "bgCurve1", frame,
                                  out.bg_curve) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "round", frame,
                                  out.round) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "logoback", frame,
                                  out.logo_back) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "bg", frame,
                                  out.bg) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "explosion", frame,
                                  out.explosion) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "Indicator1", frame,
                                  out.indicator1) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "Indicator2", frame,
                                  out.indicator2) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "Indicator3", frame,
                                  out.indicator3) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "Indicator4", frame,
                                  out.indicator4) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "xenonLogo1", frame,
                                  out.xenon_logo) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "Image", frame,
                                  out.image) && ok;
  ok = EvaluateVisualStateForPoc7(skin_summary_, details, "TextPresenter", frame,
                                  out.text) && ok;

  out.valid = ok;
  return ok;
}

'@
    $cc = $cc.Insert($initializeIndex, $snapshotMethod)

    $readyLogAnchor = '  XELOGI("XUI-POC6: runtime timeline evaluator ready={}", ready_);'
    if (!$cc.Contains($readyLogAnchor)) { throw "PoC 6 runtime ready log not found." }
    $cc = $cc.Replace(
        $readyLogAnchor,
        $readyLogAnchor + "`r`n" +
        '  XELOGI("XUI-POC7: snapshot evaluator ready={}", ready_ && g_xui_poc7_skin_details_ready);')

    [IO.File]::WriteAllText($ccPath, $cc, [Text.UTF8Encoding]::new($false))
  }

  # --------------------------------------------------------------------------
  # Achievement notification class state for the XUI playhead.
  # --------------------------------------------------------------------------
  $guestHeader = [IO.File]::ReadAllText($guestHeaderPath)
  if (!$guestHeader.Contains("xui_poc7_start_time_")) {
    if (!$guestHeader.Contains("#include <cstdint>")) {
      $includeAnchor = '#include "third_party/imgui/imgui.h"'
      if (!$guestHeader.Contains($includeAnchor)) { throw "Guest header include anchor missing." }
      $guestHeader = $guestHeader.Replace($includeAnchor, "#include <cstdint>`r`n`r`n" + $includeAnchor)
    }

    $classClose = @'
  void OnDraw(ImGuiIO& io) override;
};

class XNotifyWindow final
'@
    if (!$guestHeader.Contains($classClose)) { throw "AchievementNotificationWindow class close anchor missing." }
    $classReplacement = @'
  void OnDraw(ImGuiIO& io) override;

 private:
  uint64_t xui_poc7_start_time_ = 0;
  uint64_t xui_poc7_close_time_ = 0;
  bool xui_poc7_closing_ = false;
  bool xui_poc7_logged_ = false;
};

class XNotifyWindow final
'@
    $guestHeader = $guestHeader.Replace($classClose, $classReplacement)
    [IO.File]::WriteAllText($guestHeaderPath, $guestHeader, [Text.UTF8Encoding]::new($false))
  }

  # --------------------------------------------------------------------------
  # First visible renderer. Geometry/materials are deliberately alpha-quality;
  # all animation transforms and visibility come from the original XUR runtime.
  # PoC 8 will replace the placeholder primitives with original XUI figures and
  # the user's external original PNG resources.
  # --------------------------------------------------------------------------
  $guestCc = [IO.File]::ReadAllText($guestCcPath)
  if (!$guestCc.Contains("XUI-POC7: visible XUI alpha renderer activated")) {
    $includeAnchor = '#include "xenia/ui/imgui_notification.h"'
    if (!$guestCc.Contains($includeAnchor)) { throw "Guest source include anchor missing." }
    $guestCc = $guestCc.Replace(
        $includeAnchor,
        $includeAnchor + "`r`n" + '#include "xenia/ui/xbox360_xui_runtime.h"')

    $onDrawAnchor = "void AchievementNotificationWindow::OnDraw(ImGuiIO& io) {`r`n"
    $onDrawIndex = $guestCc.IndexOf($onDrawAnchor)
    if ($onDrawIndex -lt 0) {
      $onDrawAnchor = "void AchievementNotificationWindow::OnDraw(ImGuiIO& io) {`n"
      $onDrawIndex = $guestCc.IndexOf($onDrawAnchor)
    }
    if ($onDrawIndex -lt 0) { throw "Achievement OnDraw anchor not found." }
    $insertIndex = $onDrawIndex + $onDrawAnchor.Length

    $renderer = @'
  auto& xui_runtime = Xbox360XuiRuntime::Get();
  if (xui_runtime.ready()) {
    const uint64_t now = Clock::QueryHostUptimeMillis();
    if (xui_poc7_start_time_ == 0) {
      xui_poc7_start_time_ = now;
      SetCreationTime(now);
    }

    if (!xui_poc7_logged_) {
      XELOGI(
          "XUI-POC7: visible XUI alpha renderer activated title='{}' description='{}'",
          GetTitle(), GetDescription());
      xui_poc7_logged_ = true;
    }

    constexpr uint64_t kHoldBeforeCloseMs = 4500;
    constexpr uint32_t kTimelineHz = 60;
    const uint64_t age_ms = now - xui_poc7_start_time_;
    if (!xui_poc7_closing_ && age_ms >= kHoldBeforeCloseMs) {
      xui_poc7_closing_ = true;
      xui_poc7_close_time_ = now;
      XELOGI("XUI-POC7: external-close -> TransFrom frame=186");
    }

    uint32_t xui_frame = 0;
    if (xui_poc7_closing_) {
      const uint64_t close_age_ms = now - xui_poc7_close_time_;
      const uint32_t close_ticks =
          static_cast<uint32_t>((close_age_ms * kTimelineHz) / 1000);
      if (close_ticks > 54) {
        XELOGI("XUI-POC7: renderer Stop at EndTransFrom frame=240");
        delete this;
        return;
      }
      xui_frame = 186 + close_ticks;
    } else {
      const uint32_t ticks =
          static_cast<uint32_t>((age_ms * kTimelineHz) / 1000);
      if (ticks <= 185) {
        xui_frame = ticks;
      } else {
        // Original EndTransTo frame 185 is GoToAndPlay("loop"), frame 65.
        xui_frame = 65 + ((ticks - 186) % 121);
      }
    }

    Xbox360XuiNotificationSnapshot snapshot;
    if (xui_runtime.EvaluateNotificationSnapshot(xui_frame, snapshot) &&
        snapshot.valid) {
      const ImVec2 screen_size = io.DisplaySize;
      const float window_scale =
          std::fminf(screen_size.x / default_drawing_resolution.x,
                     screen_size.y / default_drawing_resolution.y);
      const ImVec2 canvas_size(430.0f * window_scale,
                               82.0f * window_scale);
      const ImVec2 notification_position = CalculateNotificationScreenPosition(
          screen_size, canvas_size, GetPositionId());
      if (!std::isnan(notification_position.x) &&
          !std::isnan(notification_position.y)) {
        ImGui::SetNextWindowSize(canvas_size);
        ImGui::SetNextWindowPos(notification_position);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));
        ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
        constexpr ImGuiWindowFlags kXuiPoc7Flags =
            ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
            ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoBringToFrontOnFocus |
            ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoResize;

        ImGui::Begin("Xbox 360 XUI Notification PoC 7", nullptr,
                     kXuiPoc7Flags);
        ImDrawList* draw = ImGui::GetWindowDrawList();
        const ImVec2 window_pos = ImGui::GetWindowPos();
        const ImVec2 origin(window_pos.x + 30.0f * window_scale,
                            window_pos.y + 10.0f * window_scale);

        auto clamp01 = [](float v) {
          return std::fmaxf(0.0f, std::fminf(1.0f, v));
        };
        auto rgba = [&](float r, float g, float b, float a) {
          return ImGui::GetColorU32(ImVec4(r, g, b, clamp01(a)));
        };
        auto pos = [&](float x, float y) {
          return ImVec2(origin.x + x * window_scale,
                        origin.y + y * window_scale);
        };

        // Alpha geometry: the first visible proof that the original XUR
        // timeline is driving drawing. The exact CUST figures/gradients are a
        // separate PoC 8 milestone.
        const auto& curve = snapshot.bg_curve;
        if (curve.show && curve.opacity > 0.001f) {
          const float width = 356.0f * std::fmaxf(0.02f, curve.scale_x);
          const float height = 39.0f * std::fmaxf(0.02f, curve.scale_y);
          const ImVec2 a = pos(curve.position_x, curve.position_y);
          const ImVec2 b(a.x + width * window_scale,
                         a.y + height * window_scale);
          draw->AddRectFilled(a, b, rgba(0.10f, 0.10f, 0.10f,
                                         0.94f * curve.opacity),
                              19.0f * window_scale);
          draw->AddRect(a, b, rgba(0.72f, 0.72f, 0.72f,
                                   0.55f * curve.opacity),
                        19.0f * window_scale, 0, 1.0f * window_scale);
        }

        const ImVec2 ring_center = pos(30.5f, 30.5f);
        const auto& bg = snapshot.bg;
        if (bg.show && bg.opacity > 0.001f) {
          draw->AddCircleFilled(
              ImVec2(ring_center.x + bg.position_x * window_scale,
                     ring_center.y + bg.position_y * window_scale),
              25.0f * std::fmaxf(0.05f, bg.scale_x) * window_scale,
              rgba(0.08f, 0.08f, 0.08f, 0.75f * bg.opacity), 48);
        }
        const auto& back = snapshot.logo_back;
        if (back.show && back.opacity > 0.001f) {
          draw->AddCircle(
              ImVec2(ring_center.x + back.position_x * window_scale,
                     ring_center.y + back.position_y * window_scale),
              27.0f * std::fmaxf(0.05f, back.scale_x) * window_scale,
              rgba(0.55f, 0.75f, 0.18f, back.opacity), 48,
              3.0f * window_scale);
        }

        const auto draw_indicator = [&](const Xbox360XuiVisualState& state) {
          if (!state.show || state.opacity <= 0.001f) return;
          const ImVec2 p = pos(30.5f + state.position_x * 0.18f,
                               30.5f + state.position_y * 0.18f);
          draw->AddCircleFilled(p, 2.3f * window_scale,
                                rgba(0.55f, 0.85f, 0.15f, state.opacity), 12);
        };
        draw_indicator(snapshot.indicator1);
        draw_indicator(snapshot.indicator2);
        draw_indicator(snapshot.indicator3);
        draw_indicator(snapshot.indicator4);

        const auto& explosion = snapshot.explosion;
        if (explosion.show && explosion.opacity > 0.001f) {
          draw->AddCircle(
              pos(30.5f + explosion.position_x * 0.15f,
                  30.5f + explosion.position_y * 0.15f),
              31.0f * std::fmaxf(0.05f, explosion.scale_x) * window_scale,
              rgba(0.65f, 0.90f, 0.20f, 0.55f * explosion.opacity), 48,
              2.0f * window_scale);
        }

        const auto& logo = snapshot.xenon_logo;
        if (logo.show && logo.opacity > 0.001f) {
          const float logo_radius =
              26.0f * std::fmaxf(0.05f, logo.scale_x) * window_scale;
          const ImVec2 c = pos(32.0f + logo.position_x,
                               29.0f + logo.position_y);
          draw->AddCircleFilled(c, logo_radius,
                                rgba(0.35f, 0.65f, 0.08f, logo.opacity), 48);
          const float d = logo_radius * 0.42f;
          draw->AddLine(ImVec2(c.x - d, c.y - d), ImVec2(c.x + d, c.y + d),
                        rgba(1, 1, 1, logo.opacity),
                        2.0f * window_scale);
          draw->AddLine(ImVec2(c.x + d, c.y - d), ImVec2(c.x - d, c.y + d),
                        rgba(1, 1, 1, logo.opacity),
                        2.0f * window_scale);
        }

        // Achievement image presenter. PoC 7 draws a small trophy primitive;
        // PoC 8 will load the user's external original Achievement.png.
        const auto& image = snapshot.image;
        if (image.show && image.opacity > 0.001f) {
          const ImVec2 cup_a = pos(23.0f, 19.0f);
          const ImVec2 cup_b = pos(41.0f, 31.0f);
          const ImU32 cup_color = rgba(1, 1, 1, image.opacity);
          draw->AddRect(cup_a, cup_b, cup_color, 3.0f * window_scale, 0,
                        2.0f * window_scale);
          draw->AddLine(pos(32.0f, 31.0f), pos(32.0f, 38.0f), cup_color,
                        2.0f * window_scale);
          draw->AddLine(pos(27.0f, 38.0f), pos(37.0f, 38.0f), cup_color,
                        2.0f * window_scale);
        }

        const auto& text_state = snapshot.text;
        if (text_state.show && text_state.opacity > 0.001f) {
          ImFont* font = io.Fonts->Fonts[0];
          const float title_size = 15.0f * window_scale;
          const float body_size = 13.0f * window_scale;
          const ImU32 text_color = rgba(1, 1, 1, text_state.opacity);
          const std::string title(GetTitle());
          const std::string description(GetDescription());
          draw->AddText(font, title_size, pos(76.0f, 15.0f), text_color,
                        title.c_str());
          draw->AddText(font, body_size, pos(76.0f, 34.0f), text_color,
                        description.c_str());
        }

        ImGui::End();
        ImGui::PopStyleColor();
        ImGui::PopStyleVar();
        return;
      }
    }

    XELOGW("XUI-POC7: snapshot evaluation failed at frame={}; falling back to default notification renderer",
           xui_frame);
  }

'@
    $guestCc = $guestCc.Insert($insertIndex, $renderer)
    [IO.File]::WriteAllText($guestCcPath, $guestCc, [Text.UTF8Encoding]::new($false))
  }

  Write-Host "Applied Xbox 360 XUI runtime PoC 7 visible alpha renderer."
} finally {
  Pop-Location
}
