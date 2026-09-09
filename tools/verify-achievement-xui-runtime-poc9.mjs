import fs from 'node:fs';
import path from 'node:path';

if (!process.argv[2]) {
  throw new Error('Usage: node verify-achievement-xui-runtime-poc9.mjs XENIA_PATH');
}
const root = path.resolve(process.argv[2]);
const read = (name) => fs.readFileSync(
    path.join(root, 'src/xenia/ui', name), 'utf8').replaceAll('\r\n', '\n');
const guest = read('imgui_guest_notification.cc');
const runtime = read('xbox360_xui_runtime.cc');
const drawer = read('imgui_drawer.cc');

const requiredGuestMarkers = [
  'XUI-POC9: original gradient renderer activated (SizeMode16 native-center/clipped)',
  'static constexpr float kCurveStops[]',
  '0x00EBEBEB, 0x32EBEBEB, 0xFF323232, 0xFF3C3C3C',
  'static constexpr float kRoundStops[]',
  'static constexpr float kBgStops[]',
  'static constexpr float kExplosionStops[]',
  'draw_radial_gradient(',
  'draw_original_image_size_mode_16',
  'float(texture->width)',
  'draw->PushClipRect(clip_min, clip_max, true)',
  'draw->PathArcTo(center, radius',
  'EvaluateNotificationSnapshot(xui_frame, snapshot)',
];
for (const marker of requiredGuestMarkers) {
  if (!guest.includes(marker)) throw new Error(`PoC 9 marker missing: ${marker}`);
}
if (guest.includes('XUI-POC8:')) {
  throw new Error('Stale PoC 8 renderer log remains in guest notification source');
}
if (guest.includes('skin geometry still provisional') ||
    guest.includes('draw->AddRect(a, b, rgba(0.72f')) {
  throw new Error('Validated PoC 8 provisional border/geometry remains');
}
if (!runtime.includes('XUI-POC6: timeline evaluator ready={}') ||
    !runtime.includes('XUI-POC7: snapshot evaluator ready={}')) {
  throw new Error('PoC 6 evaluator or PoC 7 snapshot integration was lost');
}
if (!drawer.includes('Xbox360XuiRuntime::Get().Initialize("xbox360_ui")') ||
    !drawer.includes('XUI-POC8: original texture loaded')) {
  throw new Error('Runtime startup or validated original-PNG loader was lost');
}

console.log('PoC 9 source integration verified: original gradients, radial figures, arc indicators and native/clipped PNG layout are present; PoC 6/7/8 foundations remain.');
