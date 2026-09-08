param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  # ---------------------------------------------------------------------------
  # External original Xbox 360 achievement assets
  # ---------------------------------------------------------------------------
  $h = "src/xenia/ui/imgui_drawer.h"
  $hc = Get-Content $h -Raw

  $needle = @'
  ImmediateTexture* GetLockedAchievementIcon() {
    return locked_achievement_icon_.get();
  }
'@
  $insert = @'
  ImmediateTexture* GetXbox360AchievementLogo() {
    return xbox360_achievement_logo_.get();
  }

  ImmediateTexture* GetXbox360AchievementTrophy() {
    return xbox360_achievement_trophy_.get();
  }

  ImmediateTexture* GetLockedAchievementIcon() {
    return locked_achievement_icon_.get();
  }
'@
  if (!$hc.Contains($needle)) { throw "imgui_drawer.h getter anchor not found" }
  $hc = $hc.Replace($needle, $insert)

  $memberNeedle = @'
  std::unique_ptr<ImmediateTexture> locked_achievement_icon_;

  std::vector<std::unique_ptr<ImmediateTexture>> notification_icon_textures_;
'@
  $memberInsert = @'
  std::unique_ptr<ImmediateTexture> locked_achievement_icon_;
  std::unique_ptr<ImmediateTexture> xbox360_achievement_logo_;
  std::unique_ptr<ImmediateTexture> xbox360_achievement_trophy_;

  std::vector<std::unique_ptr<ImmediateTexture>> notification_icon_textures_;
'@
  if (!$hc.Contains($memberNeedle)) { throw "imgui_drawer.h member anchor not found" }
  $hc = $hc.Replace($memberNeedle, $memberInsert)
  [IO.File]::WriteAllText((Resolve-Path $h), $hc, [Text.UTF8Encoding]::new($false))

  $cc = "src/xenia/ui/imgui_drawer.cc"
  $ccc = Get-Content $cc -Raw
  if (!$ccc.Contains('#include <cstring>')) { throw "imgui_drawer.cc include anchor not found" }
  $ccc = $ccc.Replace('#include <cstring>', "#include <cstring>`n#include <fstream>")

  $cvarNeedle = @'
DEFINE_path(
    custom_font_path, "",
    "Allows user to load custom font and use it instead of default one.", "UI");
'@
  $cvarInsert = @'
DEFINE_path(
    custom_font_path, "",
    "Allows user to load custom font and use it instead of default one.", "UI");

DEFINE_path(
    xbox360_achievement_assets_path, "xbox360_ui",
    "Folder containing xenonLogo.png and Achievement.png extracted from the user's own Xbox 360 dashboard.",
    "UI");
'@
  if (!$ccc.Contains($cvarNeedle)) { throw "imgui_drawer.cc cvar anchor not found" }
  $ccc = $ccc.Replace($cvarNeedle, $cvarInsert)

  $resetNeedle = @'
    locked_achievement_icon_.reset();
    notification_icon_textures_.clear();
'@
  $resetInsert = @'
    locked_achievement_icon_.reset();
    xbox360_achievement_logo_.reset();
    xbox360_achievement_trophy_.reset();
    notification_icon_textures_.clear();
'@
  if (!$ccc.Contains($resetNeedle)) { throw "imgui_drawer.cc reset anchor not found" }
  $ccc = $ccc.Replace($resetNeedle, $resetInsert)

  $loadNeedle = @'
    SetupFontTexture();
    SetupNotificationTextures();

    // Load locked achievement icon.
'@
  $loadInsert = @'
    SetupFontTexture();
    SetupNotificationTextures();

    const std::filesystem::path xbox360_asset_root =
        cvars::xbox360_achievement_assets_path;
    const auto load_external_png =
        [this](const std::filesystem::path& path)
        -> std::unique_ptr<ImmediateTexture> {
      std::ifstream file(path, std::ios::binary | std::ios::ate);
      if (!file) {
        return {};
      }
      const std::streampos end = file.tellg();
      if (end <= 0) {
        return {};
      }
      std::vector<uint8_t> bytes(static_cast<size_t>(end));
      file.seekg(0, std::ios::beg);
      file.read(reinterpret_cast<char*>(bytes.data()),
                static_cast<std::streamsize>(bytes.size()));
      if (!file) {
        return {};
      }
      return LoadImGuiIcon(bytes);
    };

    xbox360_achievement_logo_ = load_external_png(
        xbox360_asset_root / "xenonLogo.png");
    xbox360_achievement_trophy_ = load_external_png(
        xbox360_asset_root / "Achievement.png");

    if (!xbox360_achievement_logo_ || !xbox360_achievement_trophy_) {
      XELOGW(
          "Xbox 360 achievement V5 assets not fully loaded from '{}'. "
          "Expected xenonLogo.png and Achievement.png.",
          xe::path_to_utf8(xbox360_asset_root));
    } else {
      XELOGI("Xbox 360 achievement V5 original assets loaded from '{}'",
             xe::path_to_utf8(xbox360_asset_root));
    }

    // Load locked achievement icon.
'@
  if (!$ccc.Contains($loadNeedle)) { throw "imgui_drawer.cc load anchor not found" }
  $ccc = $ccc.Replace($loadNeedle, $loadInsert)
  [IO.File]::WriteAllText((Resolve-Path $cc), $ccc, [Text.UTF8Encoding]::new($false))

  # ---------------------------------------------------------------------------
  # Achievement popup V5: dashboard 17559 XUR-derived geometry and 30 Hz timeline
  # ---------------------------------------------------------------------------
  $path = "src/xenia/ui/imgui_guest_notification.cc"
  $content = Get-Content $path -Raw
  $pattern = '(?ms)^void AchievementNotificationWindow::OnDraw\(ImGuiIO& io\) \{.*?^void XNotifyWindow::OnDraw\(ImGuiIO& io\) \{'
  $found = [regex]::Matches($content, $pattern)
  if ($found.Count -ne 1) {
    throw "Expected exactly one AchievementNotificationWindow::OnDraw block, found $($found.Count)."
  }

  $replacement = @'
void AchievementNotificationWindow::OnDraw(ImGuiIO& io) {
  // XBOX360_ORIGINAL_ACHIEVEMENT_V5
  // Reconstructed from the user's own Xbox 360 dashboard 2.0.17559.0:
  // notify.xur + huduiskin skin.xur / scr_Notification.
  // Unlike V4, this version follows the original XUI 30 Hz keyframe timeline
  // (frames 0..240) and uses the original child geometry relationships.
  const uint64_t now = Clock::QueryHostUptimeMillis();
  if (GetCreationTime() == 0) {
    SetCreationTime(now);
#if XE_PLATFORM_WIN32
    if (!cvars::notification_sound_path.empty()) {
      auto notification_sound_path = cvars::notification_sound_path;
      if (std::filesystem::exists(notification_sound_path)) {
        PlaySound(std::wstring(notification_sound_path.begin(),
                               notification_sound_path.end())
                      .c_str(),
                  NULL, SND_FILENAME | SND_NODEFAULT | SND_NOSTOP | SND_ASYNC);
      }
    }
#endif
  }

  const float elapsed =
      static_cast<float>(now - GetCreationTime()) / 1000.0f;
  const float frame = elapsed * 30.0f;
  if (frame >= 241.0f) {
    delete this;
    return;
  }

  const auto clamp01 = [](float v) {
    return std::fmaxf(0.0f, std::fminf(1.0f, v));
  };
  const auto smooth = [&clamp01](float v) {
    const float t = clamp01(v);
    return t * t * (3.0f - 2.0f * t);
  };
  const auto tween = [&smooth](float f, float f0, float v0,
                               float f1, float v1) {
    if (f <= f0) return v0;
    if (f >= f1) return v1;
    const float t = smooth((f - f0) / (f1 - f0));
    return v0 + (v1 - v0) * t;
  };
  const auto alpha_u8 = [&clamp01](float a) {
    return static_cast<int>(255.0f * clamp01(a));
  };
  const auto col = [&clamp01](int r, int g, int b, int a, float opacity) {
    const int aa = static_cast<int>(
        std::fminf(255.0f, static_cast<float>(a) * clamp01(opacity)));
    return IM_COL32(r, g, b, aa);
  };

  const ImVec2 screen_size = io.DisplaySize;
  const float scale =
      std::fminf(screen_size.x / default_drawing_resolution.x,
                 screen_size.y / default_drawing_resolution.y);
  if (scale <= 0.0f || io.Fonts->Fonts.empty()) {
    return;
  }

  // scr_Notification is 370x61, but its XUI children intentionally overflow
  // this canvas while ClipChildren is disabled. V4 clipped that overflow.
  constexpr float kLogicalW = 370.0f;
  constexpr float kLogicalH = 61.0f;
  constexpr float kMarginL = 20.0f;
  constexpr float kMarginR = 120.0f;
  constexpr float kMarginT = 20.0f;
  constexpr float kMarginB = 20.0f;
  const ImVec2 root_size(kLogicalW * scale, kLogicalH * scale);
  const ImVec2 root_pos = CalculateNotificationScreenPosition(
      screen_size, root_size, GetPositionId());
  if (std::isnan(root_pos.x) || std::isnan(root_pos.y)) {
    return;
  }

  const ImVec2 window_size((kLogicalW + kMarginL + kMarginR) * scale,
                           (kLogicalH + kMarginT + kMarginB) * scale);
  const ImVec2 window_pos(root_pos.x - kMarginL * scale,
                          root_pos.y - kMarginT * scale);
  ImGui::SetNextWindowSize(window_size);
  ImGui::SetNextWindowPos(window_pos);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));
  ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));

  ImGui::Begin("Achievement Notification Window", nullptr, NOTIFY_TOAST_FLAGS);
  {
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const ImVec2 wp = ImGui::GetWindowPos();
    const ImVec2 o(wp.x + kMarginL * scale,
                   wp.y + kMarginT * scale);

    // -----------------------------------------------------------------------
    // bgCurve1: the actual body group. XUR static geometry:
    //   Width 356, Height 39, Position (0,10), Pivot (32.5597,19.2594)
    // Its children extend from local x ~= 7 through x ~= 398 and y ~= -8..50.
    // The XUI Scale.X animation therefore collapses the body behind the orb.
    // -----------------------------------------------------------------------
    const bool body_show = frame >= 23.0f && frame < 240.0f;
    float body_opacity = 0.0f;
    if (frame < 23.0f) {
      body_opacity = 0.0f;
    } else if (frame < 27.0f) {
      body_opacity = tween(frame, 23.0f, 0.0f, 27.0f, 0.95f);
    } else if (frame < 228.0f) {
      body_opacity = 0.95f;
    } else {
      body_opacity = tween(frame, 228.0f, 0.95f, 240.0f, 0.0f);
    }

    float body_sx = 1.0f;
    if (frame < 23.0f) {
      body_sx = 0.10f;
    } else if (frame < 27.0f) {
      body_sx = 0.10f;
    } else if (frame < 44.0f) {
      body_sx = tween(frame, 27.0f, 0.10f, 44.0f, 1.19367f);
    } else if (frame < 51.0f) {
      body_sx = tween(frame, 44.0f, 1.19367f, 51.0f, 1.0f);
    } else if (frame < 228.0f) {
      body_sx = 1.0f;
    } else {
      body_sx = tween(frame, 228.0f, 1.0f, 240.0f, 0.075798f);
    }

    float body_px = -0.24f;
    if (frame < 27.0f) {
      body_px = tween(frame, 23.0f, -0.24f, 27.0f, -0.23f);
    } else if (frame < 44.0f) {
      body_px = tween(frame, 27.0f, -0.23f, 44.0f, 0.37766f);
    } else if (frame < 51.0f) {
      body_px = tween(frame, 44.0f, 0.37766f, 51.0f, 0.262148f);
    } else if (frame < 228.0f) {
      body_px = tween(frame, 51.0f, 0.262148f, 228.0f, 0.286749f);
    } else {
      body_px = tween(frame, 228.0f, 0.286749f, 240.0f, -0.24f);
    }

    constexpr float kBodyPivotX = 32.5597f;
    const auto body_x = [&](float local_x) {
      return o.x +
          (body_px + kBodyPivotX + (local_x - kBodyPivotX) * body_sx) * scale;
    };

    if (body_show && body_opacity > 0.001f) {
      // Stable XUR children span roughly x=7..398 and y=-8..50 inside the
      // group at Position.Y=10, producing an actual ~56-61 px tall body.
      // This is why V4's 39 px pill was visibly too thin.
      const float bx0 = body_x(7.0f);
      const float bx1 = body_x(398.0f);
      const float by0 = o.y + 1.5f * scale;
      const float by1 = o.y + 59.5f * scale;
      const float bh = by1 - by0;
      const float bw = std::fmaxf(1.0f, bx1 - bx0);
      const float radius = std::fminf(bh * 0.5f, bw * 0.5f);

      // Shadow from the XUR's soft dark top/bottom figures.
      dl->AddRectFilled(ImVec2(bx0 - 2.2f * scale, by0 - 2.0f * scale),
                        ImVec2(bx1 + 2.5f * scale, by1 + 3.0f * scale),
                        col(0, 0, 0, 105, body_opacity),
                        radius + 2.5f * scale);

      // Metallic outer lip, dark separator, then graphite translucent core.
      dl->AddRectFilled(ImVec2(bx0, by0), ImVec2(bx1, by1),
                        col(148, 148, 148, 215, body_opacity), radius);
      const float rim1 = 1.45f * scale;
      dl->AddRectFilled(ImVec2(bx0 + rim1, by0 + rim1),
                        ImVec2(bx1 - rim1, by1 - rim1),
                        col(29, 29, 29, 245, body_opacity),
                        std::fmaxf(0.0f, radius - rim1));
      const float rim2 = 3.1f * scale;
      dl->AddRectFilled(ImVec2(bx0 + rim2, by0 + rim2),
                        ImVec2(bx1 - rim2, by1 - rim2),
                        col(55, 55, 55, 235, body_opacity),
                        std::fmaxf(0.0f, radius - rim2));

      // Original bgCurve1 uses two 8 px dark radial strips at top/bottom.
      const float sheen_x0 = bx0 + std::fminf(28.0f * scale, bw * 0.18f);
      const float sheen_x1 = bx1 - std::fminf(28.0f * scale, bw * 0.18f);
      if (sheen_x1 > sheen_x0) {
        dl->AddLine(ImVec2(sheen_x0, by0 + 2.2f * scale),
                    ImVec2(sheen_x1, by0 + 2.2f * scale),
                    col(235, 235, 235, 100, body_opacity), 1.0f * scale);
        dl->AddLine(ImVec2(sheen_x0, by1 - 2.2f * scale),
                    ImVec2(sheen_x1, by1 - 2.2f * scale),
                    col(5, 5, 5, 130, body_opacity), 1.0f * scale);
      }
    }

    // -----------------------------------------------------------------------
    // Shared left-center origin from the original XUI.
    // bg group center = Position + Pivot = (32.81286, 29.32377)
    // xenonLogo center = (32.76876, 29.204125)
    // -----------------------------------------------------------------------
    const ImVec2 ring_c(o.x + 32.81286f * scale,
                        o.y + 29.32377f * scale);
    const ImVec2 logo_c(o.x + 32.76876f * scale,
                        o.y + 29.204125f * scale);

    // round: left radial connector/backing that makes the orb part of the body.
    const bool round_show = frame >= 23.0f && frame < 240.0f;
    float round_alpha = 0.0f;
    if (frame >= 23.0f && frame < 27.0f) {
      round_alpha = tween(frame, 23.0f, 0.0f, 27.0f, 0.95f);
    } else if (frame >= 27.0f && frame < 228.0f) {
      round_alpha = 0.95f;
    } else if (frame >= 228.0f && frame < 240.0f) {
      round_alpha = tween(frame, 228.0f, 0.95f, 240.0f, 0.0f);
    }
    if (round_show && round_alpha > 0.001f) {
      dl->AddCircleFilled(ring_c, 29.3f * scale,
                          col(42, 42, 42, 232, round_alpha), 72);
      dl->AddCircle(ring_c, 29.0f * scale,
                    col(185, 185, 185, 165, round_alpha), 72,
                    1.05f * scale);
    }

    // logoback: 46x46 radial black backing, animated independently.
    float logoback_scale = 0.10f;
    if (frame < 28.0f) {
      logoback_scale = tween(frame, 0.0f, 0.10f, 28.0f, 1.45f);
    } else if (frame < 39.0f) {
      logoback_scale = tween(frame, 28.0f, 1.45f, 39.0f, 1.0f);
    } else if (frame < 196.0f) {
      logoback_scale = 1.0f;
    } else if (frame < 210.0f) {
      logoback_scale = tween(frame, 196.0f, 1.0f, 210.0f, 1.40f);
    } else if (frame < 215.0f) {
      logoback_scale = 1.40f;
    } else if (frame < 233.0f) {
      logoback_scale = tween(frame, 215.0f, 1.40f, 233.0f, 0.20f);
    } else {
      logoback_scale = 0.20f;
    }
    float logoback_alpha = 0.0f;
    if (frame < 28.0f) {
      logoback_alpha = tween(frame, 0.0f, 0.0f, 28.0f, 1.0f);
    } else if (frame < 196.0f) {
      logoback_alpha = 1.0f;
    } else if (frame < 210.0f) {
      logoback_alpha = tween(frame, 196.0f, 1.0f, 210.0f, 0.681818f);
    } else if (frame < 215.0f) {
      logoback_alpha = 0.681818f;
    } else if (frame < 233.0f) {
      logoback_alpha = tween(frame, 215.0f, 0.681818f, 233.0f, 0.0f);
    }
    if (logoback_alpha > 0.001f && frame < 233.0f) {
      const float lr = 23.0f * logoback_scale * scale;
      dl->AddCircleFilled(ring_c, lr, col(5, 5, 5, 35, logoback_alpha), 72);
      dl->AddCircleFilled(ring_c, lr * 0.90f,
                          col(5, 5, 5, 95, logoback_alpha), 72);
      dl->AddCircleFilled(ring_c, lr * 0.78f,
                          col(8, 8, 8, 220, logoback_alpha), 72);
    }

    // explosion: original green radial flash during intro and exit.
    bool explosion_show = false;
    float explosion_scale = 0.10f;
    float explosion_alpha = 0.0f;
    if (frame >= 5.0f && frame < 48.0f) {
      explosion_show = true;
      if (frame < 37.0f) {
        explosion_scale = tween(frame, 5.0f, 0.09f, 37.0f, 1.12f);
        explosion_alpha = tween(frame, 5.0f, 0.50f, 37.0f, 1.0f);
      } else if (frame < 43.0f) {
        explosion_scale = tween(frame, 37.0f, 1.12f, 43.0f, 0.90f);
        explosion_alpha = tween(frame, 37.0f, 1.0f, 43.0f, 0.30f);
      } else {
        explosion_scale = tween(frame, 43.0f, 0.90f, 48.0f, 0.717647f);
        explosion_alpha = tween(frame, 43.0f, 0.30f, 48.0f, 0.058824f);
      }
    } else if (frame >= 186.0f && frame < 210.0f) {
      explosion_show = true;
      if (frame < 205.0f) {
        explosion_scale = tween(frame, 186.0f, 0.717647f, 205.0f, 1.0f);
        explosion_alpha = tween(frame, 186.0f, 0.0f, 205.0f, 0.50f);
      } else {
        explosion_scale = tween(frame, 205.0f, 1.0f, 210.0f, 1.0f);
        explosion_alpha = tween(frame, 205.0f, 0.50f, 210.0f, 0.0f);
      }
    }
    if (explosion_show && explosion_alpha > 0.001f) {
      const float er = 22.5f * explosion_scale * scale;
      dl->AddCircleFilled(ring_c, er,
                          col(172, 231, 30, 30, explosion_alpha), 72);
      dl->AddCircleFilled(ring_c, er * 0.72f,
                          col(140, 231, 30, 70, explosion_alpha), 72);
      dl->AddCircleFilled(ring_c, er * 0.44f,
                          col(200, 235, 100, 80, explosion_alpha), 72);
    }

    // -----------------------------------------------------------------------
    // bg1..bg4 metallic quadrants. The real XUR uses four transformed radial
    // figures with stops:
    //   alpha0 @ .67451, gray100 @ .756863, gray130 @ .913726,
    //   alpha0 @ .94902.
    // V5 approximates those radial stops with concentric annular bands, while
    // keeping the original group scale overshoot and four quadrant cuts.
    // -----------------------------------------------------------------------
    float ring_scale = 0.153571f;
    if (frame < 28.0f) {
      ring_scale = tween(frame, 0.0f, 0.153571f, 28.0f, 1.60f);
    } else if (frame < 39.0f) {
      ring_scale = tween(frame, 28.0f, 1.60f, 39.0f, 1.0f);
    } else if (frame < 196.0f) {
      ring_scale = 1.0f;
    } else if (frame < 210.0f) {
      ring_scale = tween(frame, 196.0f, 1.0f, 210.0f, 1.45f);
    } else if (frame < 215.0f) {
      ring_scale = 1.45f;
    } else if (frame < 233.0f) {
      ring_scale = tween(frame, 215.0f, 1.45f, 233.0f, 0.20f);
    } else {
      ring_scale = 0.20f;
    }
    float ring_alpha = 0.0f;
    if (frame < 28.0f) {
      ring_alpha = tween(frame, 0.0f, 0.0f, 28.0f, 1.0f);
    } else if (frame < 215.0f) {
      ring_alpha = 1.0f;
    } else if (frame < 233.0f) {
      ring_alpha = tween(frame, 215.0f, 1.0f, 233.0f, 0.0f);
    }

    const auto draw_sector =
        [dl, scale, &ring_c](float a0, float a1, float r0, float r1,
                             ImU32 color) {
      constexpr float kPi = 3.14159265358979323846f;
      constexpr int kSteps = 18;
      for (int i = 0; i < kSteps; ++i) {
        const float t0 = static_cast<float>(i) / kSteps;
        const float t1 = static_cast<float>(i + 1) / kSteps;
        const float aa0 = (a0 + (a1 - a0) * t0) * kPi / 180.0f;
        const float aa1 = (a0 + (a1 - a0) * t1) * kPi / 180.0f;
        const ImVec2 p00(ring_c.x + std::cos(aa0) * r0 * scale,
                         ring_c.y + std::sin(aa0) * r0 * scale);
        const ImVec2 p01(ring_c.x + std::cos(aa1) * r0 * scale,
                         ring_c.y + std::sin(aa1) * r0 * scale);
        const ImVec2 p10(ring_c.x + std::cos(aa0) * r1 * scale,
                         ring_c.y + std::sin(aa0) * r1 * scale);
        const ImVec2 p11(ring_c.x + std::cos(aa1) * r1 * scale,
                         ring_c.y + std::sin(aa1) * r1 * scale);
        dl->AddTriangleFilled(p00, p01, p11, color);
        dl->AddTriangleFilled(p00, p11, p10, color);
      }
    };

    if (ring_alpha > 0.001f && frame < 233.0f) {
      const float rr = ring_scale;
      constexpr float angles[4][2] = {
          {-174.0f, -96.0f}, {-84.0f, -6.0f},
          {6.0f, 84.0f}, {96.0f, 174.0f}};
      for (int q = 0; q < 4; ++q) {
        draw_sector(angles[q][0], angles[q][1], 18.6f * rr, 20.8f * rr,
                    col(100, 100, 100, 125, ring_alpha));
        draw_sector(angles[q][0], angles[q][1], 20.8f * rr, 25.7f * rr,
                    col(122, 122, 122, 245, ring_alpha));
        draw_sector(angles[q][0], angles[q][1], 25.7f * rr, 27.1f * rr,
                    col(150, 150, 150, 90, ring_alpha));
      }

      // Dark cardinal gaps / dividers are left uncovered by the 12-degree
      // spaces between quadrants, as in the original four transformed figures.
      dl->AddCircle(ring_c, 27.1f * rr * scale,
                    col(205, 205, 205, 70, ring_alpha), 72,
                    0.70f * scale);
    }

    // Indicator1..4 are shown by the XUI only for frames 44..192. The console
    // capture shows the top-left quadrant as the dominant green status segment.
    float indicator_alpha = 0.0f;
    if (frame >= 44.0f && frame < 192.0f) {
      indicator_alpha = 1.0f;
    }
    if (indicator_alpha > 0.001f && ring_alpha > 0.001f) {
      const float rr = ring_scale;
      draw_sector(-174.0f, -96.0f, 18.5f * rr, 20.7f * rr,
                  col(172, 231, 30, 85, indicator_alpha * ring_alpha));
      draw_sector(-174.0f, -96.0f, 20.7f * rr, 25.8f * rr,
                  col(140, 231, 30, 250, indicator_alpha * ring_alpha));
      draw_sector(-174.0f, -96.0f, 25.8f * rr, 27.2f * rr,
                  col(200, 235, 100, 105, indicator_alpha * ring_alpha));
    }

    // -----------------------------------------------------------------------
    // xenonLogo1 - original xam://xenonLogo.png, 58x58 at 3.76876,0.204125.
    // The PNG itself is 108x108 with transparent padding; keeping the whole
    // 58x58 image rect reproduces the dashboard's intentionally smaller sphere.
    // -----------------------------------------------------------------------
    bool logo_show = false;
    float logo_scale = 1.0f;
    float logo_alpha = 0.0f;
    if (frame >= 5.0f && frame < 185.0f) {
      logo_show = true;
      if (frame < 37.0f) {
        logo_scale = tween(frame, 5.0f, 0.10f, 37.0f, 1.50f);
        logo_alpha = tween(frame, 5.0f, 0.50f, 37.0f, 1.0f);
      } else if (frame < 43.0f) {
        logo_scale = tween(frame, 37.0f, 1.50f, 43.0f, 0.95f);
        logo_alpha = 1.0f;
      } else if (frame < 60.0f) {
        logo_scale = 0.95f;
        logo_alpha = 1.0f;
      } else if (frame < 65.0f) {
        logo_scale = 0.95f;
        logo_alpha = tween(frame, 60.0f, 1.0f, 65.0f, 0.0f);
      } else if (frame < 125.0f) {
        logo_scale = 0.95f;
        logo_alpha = 0.0f;
      } else if (frame < 130.0f) {
        logo_scale = 0.95f;
        logo_alpha = tween(frame, 125.0f, 0.0f, 130.0f, 1.0f);
      } else {
        logo_scale = 0.95f;
        logo_alpha = 1.0f;
      }
    } else if (frame >= 195.0f && frame < 233.0f) {
      logo_show = true;
      logo_scale = frame < 222.0f
          ? 0.95f
          : tween(frame, 222.0f, 0.95f, 233.0f, 0.20f);
      logo_alpha = frame < 210.0f
          ? tween(frame, 195.0f, 0.0f, 210.0f, 1.0f)
          : 1.0f;
    }

    ImmediateTexture* xbox_logo = GetDrawer()->GetXbox360AchievementLogo();
    if (logo_show && xbox_logo && logo_alpha > 0.001f) {
      const float half = 29.0f * logo_scale * scale;
      const ImVec2 p0(logo_c.x - half, logo_c.y - half);
      const ImVec2 p1(logo_c.x + half, logo_c.y + half);
      dl->AddImage(reinterpret_cast<ImTextureID>(xbox_logo), p0, p1,
                   ImVec2(0.0f, 0.0f), ImVec2(1.0f, 1.0f),
                   IM_COL32(255, 255, 255, alpha_u8(logo_alpha)));
    }

    // Image presenter - original Achievement.png, 24x24 at (21,18).
    bool trophy_show = frame >= 65.0f && frame < 192.0f;
    float trophy_alpha = 0.0f;
    if (trophy_show) {
      if (frame < 70.0f) {
        trophy_alpha = tween(frame, 65.0f, 0.0f, 70.0f, 1.0f);
      } else if (frame < 120.0f) {
        trophy_alpha = 1.0f;
      } else if (frame < 125.0f) {
        trophy_alpha = tween(frame, 120.0f, 1.0f, 125.0f, 0.0f);
      } else if (frame < 185.0f) {
        trophy_alpha = 0.0f;
      } else if (frame < 186.0f) {
        trophy_alpha = tween(frame, 185.0f, 0.0f, 186.0f, 1.0f);
      } else {
        trophy_alpha = tween(frame, 186.0f, 1.0f, 192.0f, 0.0f);
      }
    }

    ImmediateTexture* trophy = GetDrawer()->GetXbox360AchievementTrophy();
    if (trophy_show && trophy && trophy_alpha > 0.001f) {
      const ImVec2 tp0(o.x + 21.0f * scale, o.y + 18.0f * scale);
      const ImVec2 tp1(tp0.x + 24.0f * scale, tp0.y + 24.0f * scale);
      dl->AddImage(reinterpret_cast<ImTextureID>(trophy), tp0, tp1,
                   ImVec2(0.0f, 0.0f), ImVec2(1.0f, 1.0f),
                   IM_COL32(255, 255, 255, alpha_u8(trophy_alpha)));
    }

    // TextPresenter: 283x60 at (59,0), PointSize 11, color #EBEBEB,
    // LineSpacingAdjust=-2. XUI frames: hidden to 38, fade 38..44,
    // hold through 217, fade 217..223, hidden by 223.
    float text_alpha = 0.0f;
    if (frame >= 38.0f && frame < 44.0f) {
      text_alpha = tween(frame, 38.0f, 0.0f, 44.0f, 1.0f);
    } else if (frame >= 44.0f && frame < 217.0f) {
      text_alpha = 1.0f;
    } else if (frame >= 217.0f && frame < 223.0f) {
      text_alpha = tween(frame, 217.0f, 1.0f, 223.0f, 0.0f);
    }
    if (text_alpha > 0.001f) {
      ImFont* font = io.Fonts->Fonts[0];
      // 11 XUI points map closely to ~16.5 px at Xenia's 1280x720 base.
      const float font_px = 16.5f * scale;
      const ImU32 text_col = IM_COL32(235, 235, 235, alpha_u8(text_alpha));
      dl->AddText(font, font_px,
                  ImVec2(o.x + 59.0f * scale, o.y + 6.0f * scale),
                  text_col, GetTitle().data(),
                  GetTitle().data() + GetTitle().size());
      dl->AddText(font, font_px,
                  ImVec2(o.x + 59.0f * scale, o.y + 29.0f * scale),
                  text_col, GetDescription().data(),
                  GetDescription().data() + GetDescription().size());
    }
  }
  ImGui::End();

  ImGui::PopStyleColor();
  ImGui::PopStyleVar(3);
}

void XNotifyWindow::OnDraw(ImGuiIO& io) {
'@

  $modified = [regex]::Replace($content, $pattern, $replacement, 1)
  if ($modified -eq $content) {
    throw "Achievement popup source was not modified."
  }
  [IO.File]::WriteAllText((Resolve-Path $path), $modified,
                          [Text.UTF8Encoding]::new($false))

  $marker = Select-String -Path $path -Pattern 'XBOX360_ORIGINAL_ACHIEVEMENT_V5'
  if ($marker.Count -ne 1) {
    throw "V5 marker was not inserted exactly once."
  }

  Write-Host "Xbox 360 dashboard-derived achievement popup V5 inserted."
}
finally {
  Pop-Location
}
