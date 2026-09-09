import fs from 'node:fs';
import path from 'node:path';

if (!process.argv[2]) {
  throw new Error('Usage: node apply-achievement-xui-runtime-poc11.mjs XENIA_PATH');
}

const file = path.join(
    path.resolve(process.argv[2]),
    'src/xenia/ui/imgui_guest_notification.cc');
let data = fs.readFileSync(file, 'utf8').replaceAll('\r\n', '\n');
if (!data.includes(
        'XUI-POC10: original XMA sound + validated POC9 renderer activated')) {
  throw new Error('Expected the PoC 10 sound build on top of PoC 9');
}
if (data.includes('XUI-POC11:')) {
  throw new Error('PoC 11 appears to be applied already');
}

data = data.replace(
    `      const ImVec2 canvas_size(430.0f * window_scale,
                               82.0f * window_scale);`,
    `      // notify.xui declares a 460x87 scene. scr_Notification is a
      // centered 370x61 visual inside it, leaving 45x13 scene margins.
      const ImVec2 canvas_size(460.0f * window_scale,
                               87.0f * window_scale);`);
data = data.replace(
    `        const ImVec2 origin(window_pos.x + 30.0f * window_scale,
                            window_pos.y + 10.0f * window_scale);`,
    `        const ImVec2 origin(window_pos.x + 45.0f * window_scale,
                            window_pos.y + 13.0f * window_scale);`);

const radialMarker = `        static constexpr float kCurveStops[] = {`;
const radialIndex = data.indexOf(radialMarker);
const oldRadialIndex = data.indexOf(`        auto draw_radial_gradient =`);
if (radialIndex < 0 || oldRadialIndex < 0 || oldRadialIndex >= radialIndex) {
  throw new Error('PoC 9 radial helper/constants markers missing');
}
const radialHelper = `        // XUI radial figures may have different X/Y scales. POC9 used a
        // single radius, which turned the four-piece orb into oversized
        // circles. Emit an ellipse and shade it in normalized local space.
        auto draw_radial_ellipse = [&](const ImVec2& center, float radius_x,
                                       float radius_y,
                                       const float* stop_positions,
                                       const uint32_t* stop_colors,
                                       uint32_t stop_count, float opacity) {
          radius_x = float(std::fabs(radius_x));
          radius_y = float(std::fabs(radius_y));
          if (radius_x <= 0.001f || radius_y <= 0.001f ||
              opacity <= 0.001f) {
            return;
          }
          const int first_vertex = draw->VtxBuffer.Size;
          draw->AddCircleFilled(center, radius_y, IM_COL32_WHITE, 64);
          for (int i = first_vertex; i < draw->VtxBuffer.Size; ++i) {
            ImDrawVert& vertex = draw->VtxBuffer[i];
            vertex.pos.x = center.x +
                           (vertex.pos.x - center.x) * radius_x / radius_y;
            const float nx = (vertex.pos.x - center.x) / radius_x;
            const float ny = (vertex.pos.y - center.y) / radius_y;
            const float coverage =
                float((vertex.col >> IM_COL32_A_SHIFT) & 0xFF) / 255.0f;
            vertex.col = sample_xui_gradient(
                stop_positions, stop_colors, stop_count,
                float(std::sqrt(nx * nx + ny * ny)), opacity, coverage);
          }
        };

`;
data = data.slice(0, oldRadialIndex) + radialHelper + data.slice(radialIndex);

const geometryBeginMarker = `        const auto& curve = snapshot.bg_curve;`;
const geometryEndMarker = `        // Both supplied image elements use SizeMode=16.`;
const geometryBegin = data.indexOf(geometryBeginMarker);
const geometryEnd = data.indexOf(geometryEndMarker, geometryBegin);
if (geometryBegin < 0 || geometryEnd < 0) {
  throw new Error('PoC 9 geometry replacement markers are missing');
}
const geometry = `        // Recreate the nested geometry declared by bgCurve1 rather than
        // treating its 356x39 group bounds as the visible pill. The body is
        // XuiFigure 2 (305x55.7883 at 32,-7.82442) and its right cap is the
        // 61x61.5 figure centered at local X=337. The group timeline still
        // supplies the scale, position, opacity and overshoot.
        const auto& curve = snapshot.bg_curve;
        if (curve.show && curve.opacity > 0.001f) {
          const ImVec2 raw_body_0 = transformed_point(
              curve, 32.0f, -7.824420f, 32.559700f, 19.259399f);
          const ImVec2 raw_body_1 = transformed_point(
              curve, 337.0f, 47.963880f, 32.559700f, 19.259399f);
          const ImVec2 body_0(std::fminf(raw_body_0.x, raw_body_1.x),
                              std::fminf(raw_body_0.y, raw_body_1.y));
          const ImVec2 body_1(std::fmaxf(raw_body_0.x, raw_body_1.x),
                              std::fmaxf(raw_body_0.y, raw_body_1.y));
          const int first_vertex = draw->VtxBuffer.Size;
          draw->AddRectFilled(body_0, body_1, IM_COL32_WHITE);
          shade_vertical_gradient(first_vertex, body_0, body_1, kCurveStops,
                                  kCurveColors, 8, curve.opacity);

          // These are the two 350x8 radial strips present above and below
          // the original body. Split each strip at its center so the dark
          // highlight fades toward both horizontal ends like the XUI fill.
          const auto draw_curve_glow = [&](float local_y) {
            const ImVec2 glow_left_0 = transformed_point(
                curve, 7.0f, local_y, 32.559700f, 19.259399f);
            const ImVec2 glow_left_1 = transformed_point(
                curve, 182.0f, local_y + 8.0f, 32.559700f, 19.259399f);
            const ImVec2 glow_right_0 = transformed_point(
                curve, 182.0f, local_y, 32.559700f, 19.259399f);
            const ImVec2 glow_right_1 = transformed_point(
                curve, 357.0f, local_y + 8.0f, 32.559700f, 19.259399f);
            const ImU32 edge = rgba(0.058824f, 0.058824f, 0.058824f, 0.0f);
            const ImU32 center = rgba(0.058824f, 0.058824f, 0.058824f,
                                      0.392157f * curve.opacity);
            draw->AddRectFilledMultiColor(glow_left_0, glow_left_1, edge,
                                          center, center, edge);
            draw->AddRectFilledMultiColor(glow_right_0, glow_right_1, center,
                                          edge, edge, center);
          };
          draw_curve_glow(-2.0f);
          draw_curve_glow(33.0f);

          const ImVec2 right_cap_center = transformed_point(
              curve, 337.0f, 19.75f, 32.559700f, 19.259399f);
          draw_radial_ellipse(
              right_cap_center,
              30.5f * curve.scale_x * window_scale,
              30.75f * curve.scale_y * window_scale, kRoundStops,
              kRoundColors, 4, curve.opacity);
        }

        // 'round' is the left end of the bar. Its negative X scale places
        // the visible half from local X=-29 to X=32, ending underneath the
        // orb. POC9 incorrectly centered a complete copy on the Xbox logo.
        const auto& round = snapshot.round;
        if (round.show && round.opacity > 0.001f) {
          const ImVec2 left_cap_center = transformed_point(
              round, 30.5f, 30.65f, 28.034500f, 26.962799f);
          draw_radial_ellipse(
              left_cap_center, 30.5f * round.scale_x * window_scale,
              30.65f * round.scale_y * window_scale, kRoundStops,
              kRoundColors, 4, round.opacity);
        }

        const ImVec2 logo_center = pos(32.768760f, 29.204125f);

        // Preserve the source child order: logoback, the four-quadrant bg
        // group, explosion, indicators, then the two original images.
        const auto& back = snapshot.logo_back;
        if (back.show && back.opacity > 0.001f) {
          draw_radial_ellipse(
              transformed_point(back, 23.0f, 23.0f, 23.0f, 23.0f),
              23.0f * back.scale_x * window_scale,
              23.0f * back.scale_y * window_scale, kLogoBackStops,
              kLogoBackColors, 2, back.opacity);
        }
        const auto& bg = snapshot.bg;
        if (bg.show && bg.opacity > 0.001f) {
          draw_radial_ellipse(
              transformed_point(bg, 38.222198f, 39.111099f, 38.222198f,
                                39.111099f),
              38.0f * bg.scale_x * window_scale,
              39.5f * bg.scale_y * window_scale, kBgStops, kBgColors, 4,
              bg.opacity);
        }
        const auto& explosion = snapshot.explosion;
        if (explosion.show && explosion.opacity > 0.001f) {
          draw_radial_ellipse(
              transformed_point(explosion, 22.5f, 22.5f,
                                 22.444500f, 23.629700f),
              22.5f * explosion.scale_x * window_scale,
              22.5f * explosion.scale_y * window_scale, kExplosionStops,
              kExplosionColors, 4, explosion.opacity);
        }

        const auto draw_indicator = [&](const Xbox360XuiVisualState& state,
                                        float angle_min, float angle_max) {
          if (!state.show || state.opacity <= 0.001f) return;
          // Each original Indicator group clips one mirrored 36x36 radial
          // figure into a quadrant. Equivalent ring segments share the logo
          // center; they must not move around four independent centers.
          const float radius = 32.5f * window_scale;
          draw->PathArcTo(logo_center, radius, angle_min, angle_max, 18);
          draw->PathStroke(rgba(0.55f, 0.91f, 0.12f,
                                0.42f * state.opacity),
                           0, 7.0f * window_scale);
          draw->PathArcTo(logo_center, radius, angle_min, angle_max, 18);
          draw->PathStroke(rgba(0.78f, 0.92f, 0.39f,
                                0.95f * state.opacity),
                           0, 3.0f * window_scale);
        };

        constexpr float kPi = 3.14159265358979323846f;
        draw_indicator(snapshot.indicator1, -0.94f * kPi, -0.56f * kPi);
        draw_indicator(snapshot.indicator2, -0.44f * kPi, -0.06f * kPi);
        draw_indicator(snapshot.indicator3, 0.56f * kPi, 0.94f * kPi);
        draw_indicator(snapshot.indicator4, 0.06f * kPi, 0.44f * kPi);

`;
data = data.slice(0, geometryBegin) + geometry + data.slice(geometryEnd);

data = data.replace(
    `          const float title_size = 15.0f * window_scale;
          const float body_size = 13.0f * window_scale;`,
    `          // TextPresenter has PointSize=11 and color 0xffebebeb. Both
          // lines belong to the same presenter and therefore share size.
          const float title_size = 11.0f * window_scale;
          const float body_size = 11.0f * window_scale;`);
data = data.replace(
    `          const ImU32 text_color = rgba(1, 1, 1, text_state.opacity);`,
    `          const ImU32 text_color =
              rgba(0.921568f, 0.921568f, 0.921568f, text_state.opacity);`);
data = data.replace(
    `                        pos(text_state.position_x, text_state.position_y + 15.0f), text_color,`,
    `                        pos(text_state.position_x, text_state.position_y + 14.0f), text_color,`);
data = data.replace(
    `                        pos(text_state.position_x, text_state.position_y + 34.0f), text_color,`,
    `                        pos(text_state.position_x, text_state.position_y + 31.0f), text_color,`);

data = data.replace(
    'XUI-POC10: original XMA sound + validated POC9 renderer activated',
    'XUI-POC11: source-layout animation renderer activated (460x87 scene, 370x61 visual)');
data = data.replaceAll('XUI-POC9:', 'XUI-POC11:');

const required = [
  'const ImVec2 canvas_size(460.0f * window_scale',
  'window_pos.x + 45.0f * window_scale',
  'auto draw_radial_ellipse =',
  'curve, 32.0f, -7.824420f',
  'draw_curve_glow(-2.0f)',
  'draw_curve_glow(33.0f)',
  'right_cap_center',
  'left_cap_center',
  'const float radius = 32.5f * window_scale',
  'const float title_size = 11.0f * window_scale',
];
for (const marker of required) {
  if (!data.includes(marker)) throw new Error(`PoC 11 insertion failed: ${marker}`);
}

fs.writeFileSync(file, data);
console.log('Applied PoC 11 source-layout geometry and animation correction.');
