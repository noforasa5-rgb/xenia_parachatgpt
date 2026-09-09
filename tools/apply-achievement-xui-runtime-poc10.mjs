import fs from 'node:fs';
import path from 'node:path';

if (!process.argv[2]) {
  throw new Error('Usage: node apply-achievement-xui-runtime-poc10.mjs XENIA_PATH');
}

const root = path.resolve(process.argv[2]);
const ui = path.join(root, 'src/xenia/ui');
const headerFile = path.join(ui, 'imgui_guest_notification.h');
const guestFile = path.join(ui, 'imgui_guest_notification.cc');
let header = fs.readFileSync(headerFile, 'utf8').replaceAll('\r\n', '\n');
let guest = fs.readFileSync(guestFile, 'utf8').replaceAll('\r\n', '\n');

if (!guest.includes(
        'XUI-POC9: original gradient renderer activated (SizeMode16 native-center/clipped)')) {
  throw new Error('Expected the validated PoC 9 renderer');
}
if (guest.includes('XUI-POC10:') || header.includes('xui_poc10_sound_attempted_')) {
  throw new Error('PoC 10 appears to be applied already');
}

const includeMarker = '#include <cmath>\n';
if (!guest.includes(includeMarker)) {
  throw new Error('Guest notification include marker is missing');
}
guest = guest.replace(includeMarker, '#include <cmath>\n#include <filesystem>\n');

const startMarker = `    if (xui_poc7_start_time_ == 0) {
      xui_poc7_start_time_ = now;
      SetCreationTime(now);
    }`;
if (!guest.includes(startMarker)) {
  throw new Error('PoC 9 notification start marker is missing or changed');
}
guest = guest.replace(startMarker, `    if (xui_poc7_start_time_ == 0) {
      xui_poc7_start_time_ = now;
      SetCreationTime(now);
#if XE_PLATFORM_WIN32
      // skin.xur references NotifyPopup.xma. Keep the original user-provided
      // asset external and let the Windows waveform service decode its RIFF
      // XMA1 stream, exactly once at the start of each achievement popup.
      if (!xui_poc10_sound_attempted_) {
        xui_poc10_sound_attempted_ = true;
        const std::filesystem::path sound_path =
            xui_runtime.root_path() / "NotifyPopup.xma";
        if (!std::filesystem::exists(sound_path)) {
          XELOGW("XUI-POC10: original sound unavailable path='{}'",
                 sound_path.generic_string());
        } else if (PlaySoundW(
                       sound_path.c_str(), nullptr,
                       SND_FILENAME | SND_NODEFAULT | SND_ASYNC)) {
          XELOGI(
              "XUI-POC10: original NotifyPopup.xma playback started "
              "path='{}'",
              sound_path.generic_string());
        } else {
          XELOGW(
              "XUI-POC10: PlaySoundW rejected original XMA path='{}'",
              sound_path.generic_string());
        }
      }
#endif
    }`);

const memberMarker = '  bool xui_poc7_assets_failed_logged_ = false;\n';
if (!header.includes(memberMarker)) {
  throw new Error('Achievement notification state marker is missing');
}
header = header.replace(
    memberMarker,
    memberMarker + '  bool xui_poc10_sound_attempted_ = false;\n');

guest = guest.replace(
    'XUI-POC9: original gradient renderer activated (SizeMode16 native-center/clipped)',
    'XUI-POC10: original XMA sound + validated POC9 renderer activated');

fs.writeFileSync(headerFile, header);
fs.writeFileSync(guestFile, guest);
console.log('Applied PoC 10 original NotifyPopup.xma playback trigger.');
