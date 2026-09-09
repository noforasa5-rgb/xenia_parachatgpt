import fs from 'node:fs';
import path from 'node:path';

if (!process.argv[2]) {
  throw new Error('Usage: node verify-achievement-xui-runtime-poc11.mjs XENIA_PATH');
}
const root = path.resolve(process.argv[2]);
const read = (name) => fs.readFileSync(
    path.join(root, 'src/xenia/ui', name), 'utf8').replaceAll('\r\n', '\n');
const guest = read('imgui_guest_notification.cc');
const header = read('imgui_guest_notification.h');
const runtime = read('xbox360_xui_runtime.cc');
const drawer = read('imgui_drawer.cc');

const required = [
  'XUI-POC11: source-layout animation renderer activated (460x87 scene, 370x61 visual)',
  'const ImVec2 canvas_size(460.0f * window_scale',
  'window_pos.x + 45.0f * window_scale',
  'window_pos.y + 13.0f * window_scale',
  'auto draw_radial_ellipse =',
  'curve, 32.0f, -7.824420f',
  'curve, 337.0f, 47.963880f',
  'draw_curve_glow(-2.0f)',
  'draw_curve_glow(33.0f)',
  'right_cap_center',
  'round, 30.5f, 30.65f, 28.034500f, 26.962799f',
  'const float radius = 32.5f * window_scale',
  'const float title_size = 11.0f * window_scale',
  'rgba(0.921568f, 0.921568f, 0.921568f, text_state.opacity)',
  'XUI-POC10: original NotifyPopup.xma playback started',
  'draw_original_image_size_mode_16',
  'EvaluateNotificationSnapshot(xui_frame, snapshot)',
];
for (const marker of required) {
  if (!guest.includes(marker)) throw new Error(`PoC 11 marker missing: ${marker}`);
}
if (guest.includes('const ImVec2 canvas_size(430.0f') ||
    guest.includes('auto draw_radial_gradient =') ||
    guest.includes('draw_radial_gradient(logo_center, 30.65f') ||
    guest.includes('const float radius = 37.5f * window_scale') ||
    guest.includes('const float title_size = 15.0f')) {
  throw new Error('A known PoC 9 geometry approximation remains');
}
if (!header.includes('bool xui_poc10_sound_attempted_ = false;')) {
  throw new Error('PoC 10 sound guard was lost');
}
if (!runtime.includes('XUI-POC6: timeline evaluator ready={}') ||
    !runtime.includes('XUI-POC7: snapshot evaluator ready={}')) {
  throw new Error('PoC 6 evaluator or PoC 7 snapshot integration was lost');
}
if (!drawer.includes('XUI-POC8: original texture loaded')) {
  throw new Error('PoC 8 original texture loader was lost');
}

console.log('PoC 11 source integration verified: scene margins, nested bar bounds, end caps, orb layer order, indicator radius and TextPresenter metrics replace the PoC 9 approximations; PoC 6-10 remain.');
