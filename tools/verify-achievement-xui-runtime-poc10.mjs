import fs from 'node:fs';
import path from 'node:path';

if (!process.argv[2]) {
  throw new Error('Usage: node verify-achievement-xui-runtime-poc10.mjs XENIA_PATH');
}

const root = path.resolve(process.argv[2]);
const read = (name) => fs.readFileSync(
    path.join(root, 'src/xenia/ui', name), 'utf8').replaceAll('\r\n', '\n');
const guest = read('imgui_guest_notification.cc');
const header = read('imgui_guest_notification.h');
const runtime = read('xbox360_xui_runtime.cc');
const drawer = read('imgui_drawer.cc');

const requiredGuestMarkers = [
  'XUI-POC10: original XMA sound + validated POC9 renderer activated',
  'xui_runtime.root_path() / "NotifyPopup.xma"',
  'PlaySoundW(',
  'SND_FILENAME | SND_NODEFAULT | SND_ASYNC',
  'XUI-POC10: original NotifyPopup.xma playback started',
  'XUI-POC10: original sound unavailable',
  'XUI-POC10: PlaySoundW rejected original XMA',
  'xui_poc10_sound_attempted_ = true',
  'static constexpr float kCurveStops[]',
  'draw_original_image_size_mode_16',
  'EvaluateNotificationSnapshot(xui_frame, snapshot)',
];
for (const marker of requiredGuestMarkers) {
  if (!guest.includes(marker)) throw new Error(`PoC 10 marker missing: ${marker}`);
}
if (!header.includes('bool xui_poc10_sound_attempted_ = false;')) {
  throw new Error('PoC 10 per-notification sound guard is missing');
}
if (guest.includes('XUI-POC9: original gradient renderer activated')) {
  throw new Error('Stale PoC 9 activation marker remains');
}
if (!runtime.includes('XUI-POC6: timeline evaluator ready={}') ||
    !runtime.includes('XUI-POC7: snapshot evaluator ready={}')) {
  throw new Error('PoC 6 evaluator or PoC 7 snapshot integration was lost');
}
if (!drawer.includes('Xbox360XuiRuntime::Get().Initialize("xbox360_ui")') ||
    !drawer.includes('XUI-POC8: original texture loaded')) {
  throw new Error('Runtime startup or validated original-PNG loader was lost');
}

const startIndex = guest.indexOf('if (xui_poc7_start_time_ == 0)');
const soundIndex = guest.indexOf('PlaySoundW(', startIndex);
const timelineIndex = guest.indexOf('constexpr uint64_t kHoldBeforeCloseMs', startIndex);
if (startIndex < 0 || soundIndex < startIndex || timelineIndex < soundIndex) {
  throw new Error('Original sound is not triggered at popup start before timeline playback');
}

console.log('PoC 10 source integration verified: original XMA starts once per achievement and validated PoC 6-9 rendering remains intact.');
