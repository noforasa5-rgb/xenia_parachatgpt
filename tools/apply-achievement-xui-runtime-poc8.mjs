import fs from 'node:fs';
import path from 'node:path';
if (!process.argv[2]) throw new Error('Usage: node apply-achievement-xui-runtime-poc8.mjs XENIA_PATH');
const destination=path.join(path.resolve(process.argv[2]),'src/xenia/ui');
const files={};
for(const name of ['imgui_guest_notification.cc','xbox360_xui_runtime.cc','xbox360_xui_runtime.h','imgui_guest_notification.h','imgui_drawer.h','imgui_drawer.cc']) files[name]=fs.readFileSync(path.join(destination,name),'utf8').replaceAll('\r\n','\n');
if (!files['imgui_guest_notification.cc'].includes('XUI-POC7: visible XUI alpha renderer activated')) throw new Error('Expected the existing PoC 7 alpha renderer');
if (!files['imgui_drawer.cc'].includes('Xbox360XuiRuntime::Get().Initialize("xbox360_ui")')) throw new Error('Expected the existing runtime startup hook');
const evaluatorMarker='bool EvaluateVisualStateForPoc7(';
const originalEvaluator=files['xbox360_xui_runtime.cc'].split(evaluatorMarker)[0];
function replace(file,from,to){if(files[file].split(from).length!==2)throw new Error(`Expected one anchor: ${file}: ${from}`);files[file]=files[file].replace(from,to);}
replace('xbox360_xui_runtime.h','  float position_z = 0.0f;','  float position_z = 0.0f;\n  uint32_t anchor = 0;');
replace('xbox360_xui_runtime.h','  bool ready() const { return ready_; }','  bool ready() const { return ready_; }\n  const std::filesystem::path& root_path() const { return root_path_; }');
replace('xbox360_xui_runtime.cc','      state.position_z = evaluated.value.vector_value.z;','      state.position_z = evaluated.value.vector_value.z;\n    } else if (property.name == "Anchor" &&\n               evaluated.value.kind == PropertyKind::kUnsigned) {\n      state.anchor = evaluated.value.unsigned_value;');
// Static presenter properties are absent from these objects\' Position timelines.
replace('xbox360_xui_runtime.cc','  out.frame = frame;','  out.frame = frame;\n  // Static properties from the supplied 17559 scr_Notification.\n  // A general scene loader must replace these defaults in the geometry pass.\n  out.image.position_x = 21.0f;\n  out.image.position_y = 18.0f;\n  out.image.anchor = 1;\n  out.text.position_x = 59.0f;\n  out.text.anchor = 5;');
replace('imgui_guest_notification.h','#include "third_party/imgui/imgui.h"','#include <cstdint>\n\n#include "third_party/imgui/imgui.h"');
replace('imgui_guest_notification.h','  bool xui_poc7_logged_ = false;','  bool xui_poc7_logged_ = false;\n  bool xui_poc7_assets_failed_logged_ = false;');
replace('imgui_drawer.h','#include <cstdint>','#include <cstdint>\n#include <filesystem>\n#include <map>');
replace('imgui_drawer.h','  ImmediateTexture* GetLockedAchievementIcon() {','  // Cached per graphics drawer; reset with the other device textures.\n  ImmediateTexture* GetXbox360NotificationTexture(\n      const std::filesystem::path& path);\n\n  ImmediateTexture* GetLockedAchievementIcon() {');
replace('imgui_drawer.h','  std::unique_ptr<ImmediateTexture> font_texture_;','  std::map<std::filesystem::path, std::unique_ptr<ImmediateTexture>>\n      xbox360_notification_textures_;\n  std::unique_ptr<ImmediateTexture> font_texture_;');
replace('imgui_drawer.cc','#include "xenia/ui/imgui_drawer.h"','#include "xenia/ui/imgui_drawer.h"\n\n#include <fstream>');
replace('imgui_drawer.cc','std::map<uint32_t, std::unique_ptr<ImmediateTexture>> ImGuiDrawer::LoadIcons(',`ImmediateTexture* ImGuiDrawer::GetXbox360NotificationTexture(
    const std::filesystem::path& path) {
  if (!immediate_drawer_) return nullptr;
  const auto existing = xbox360_notification_textures_.find(path);
  if (existing != xbox360_notification_textures_.end()) {
    return existing->second.get();
  }
  // Cache failures too, so a missing asset does not trigger disk I/O each frame.
  auto& texture = xbox360_notification_textures_[path];
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) {
    XELOGW("XUI-POC7: cannot open texture '{}'", path.generic_string());
    return nullptr;
  }
  const std::streamoff length = file.tellg();
  if (length <= 0 || length > 16 * 1024 * 1024) {
    XELOGW("XUI-POC7: invalid texture size '{}'", path.generic_string());
    return nullptr;
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  file.seekg(0);
  if (!file.read(reinterpret_cast<char*>(bytes.data()),
                 static_cast<std::streamsize>(bytes.size()))) {
    XELOGW("XUI-POC7: cannot read texture '{}'", path.generic_string());
    return nullptr;
  }
  texture = LoadImGuiIcon(std::span<const uint8_t>(bytes.data(), bytes.size()));
  if (!texture) {
    XELOGW("XUI-POC7: cannot decode/upload texture '{}'", path.generic_string());
    return nullptr;
  }
  XELOGI("XUI-POC7: original texture loaded '{}' ({}x{})",
         path.generic_string(), texture->width, texture->height);
  return texture.get();
}

std::map<uint32_t, std::unique_ptr<ImmediateTexture>> ImGuiDrawer::LoadIcons(`);
replace('imgui_drawer.cc','    font_texture_.reset();','    xbox360_notification_textures_.clear();\n    font_texture_.reset();');
replace('imgui_guest_notification.cc','  if (xui_runtime.ready()) {',`  ImmediateTexture* original_logo = nullptr;
  ImmediateTexture* original_achievement = nullptr;
  if (xui_runtime.ready()) {
    original_logo = GetDrawer()->GetXbox360NotificationTexture(
        xui_runtime.root_path() / "xenonLogo.png");
    original_achievement = GetDrawer()->GetXbox360NotificationTexture(
        xui_runtime.root_path() / "Achievement.png");
    if ((!original_logo || !original_achievement) &&
        !xui_poc7_assets_failed_logged_) {
      XELOGW("XUI-POC7: original textures unavailable; using stock notification");
      xui_poc7_assets_failed_logged_ = true;
    }
  }
  if (xui_runtime.ready() && original_logo && original_achievement) {`);
replace('imgui_guest_notification.cc','visible XUI alpha renderer activated','original PNG renderer activated (skin geometry still provisional)');
replace('imgui_guest_notification.cc','ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoResize;','ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoResize |\n            ImGuiWindowFlags_NoSavedSettings;');
replace('imgui_guest_notification.cc','        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));','        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0.0f, 0.0f));\n        ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);');
replace('imgui_guest_notification.cc','        ImGui::PopStyleVar();','        ImGui::PopStyleVar(2);');
replace('imgui_guest_notification.cc','        ImGui::Begin("Xbox 360 XUI Notification PoC 7", nullptr,','        const std::string window_name = "Xbox 360 XUI Notification###XuiPopup" +\n            std::to_string(reinterpret_cast<uintptr_t>(this));\n        ImGui::Begin(window_name.c_str(), nullptr,');
const file='imgui_guest_notification.cc';
const begin=files[file].indexOf('        const auto& logo = snapshot.xenon_logo;');
const end=files[file].indexOf('        const auto& text_state = snapshot.text;',begin);
if(begin<0||end<0) throw new Error('Texture replacement markers missing');
files[file]=files[file].slice(0,begin)+`        // Texture pass: full UVs retain the original transparent margins.
        // SizeMode/Anchor layout still needs the general scene layout pass.
        auto draw_original_image = [&](const Xbox360XuiVisualState& state,
                                       ImmediateTexture* texture,
                                       float width, float height,
                                       float pivot_x, float pivot_y) {
          if (!state.show || state.opacity <= 0.001f) return;
          const float left = state.position_x + pivot_x * (1.0f - state.scale_x);
          const float top = state.position_y + pivot_y * (1.0f - state.scale_y);
          draw->AddImage(reinterpret_cast<ImTextureID>(texture),
                         pos(left, top),
                         pos(left + width * state.scale_x,
                             top + height * state.scale_y),
                         ImVec2(0, 0), ImVec2(1, 1),
                         rgba(1, 1, 1, state.opacity));
        };
        draw_original_image(snapshot.xenon_logo, original_logo,
                            58.0f, 58.0f, 29.0f, 29.0f);
        draw_original_image(snapshot.image, original_achievement,
                            24.0f, 24.0f, 12.0f, 12.0f);

`+files[file].slice(end);
// Apply the skin's pivots to the alpha geometry. These circles remain
// approximations until the CUST figure/gradient renderer is implemented.
replace(file,'        // Alpha geometry: the first visible proof that the original XUR\n        // timeline is driving drawing. The exact CUST figures/gradients are a\n        // separate PoC 8 milestone.',`        auto transformed_point = [&](const Xbox360XuiVisualState& state,
                                     float x, float y,
                                     float pivot_x, float pivot_y) {
          return pos(state.position_x + pivot_x + (x - pivot_x) * state.scale_x,
                     state.position_y + pivot_y + (y - pivot_y) * state.scale_y);
        };
        // Skin geometry/gradients remain provisional. Centers and pivots
        // below come from the supplied 17559 scr_Notification layout.`);
replace(file,'          const ImVec2 a = pos(curve.position_x, curve.position_y);','          const ImVec2 a = transformed_point(curve, 0.0f, 0.0f,\n                                              32.559700f, 19.259399f);');
replace(file,'              ImVec2(ring_center.x + bg.position_x * window_scale,\n                     ring_center.y + bg.position_y * window_scale),','              transformed_point(bg, 38.0f, 39.5f, 38.222198f, 39.111099f),');
replace(file,'              ImVec2(ring_center.x + back.position_x * window_scale,\n                     ring_center.y + back.position_y * window_scale),','              transformed_point(back, 23.0f, 23.0f, 23.0f, 23.0f),');
replace(file,'              pos(30.5f + explosion.position_x * 0.15f,\n                  30.5f + explosion.position_y * 0.15f),','              transformed_point(explosion, 22.5f, 22.5f,\n                                22.444500f, 23.629700f),');
replace(file,'        const ImVec2 ring_center = pos(30.5f, 30.5f);\n','');
// Use the original presenter's horizontal origin, keeping two temporary
// ImGui lines and clipping long descriptions to its 283x60 layout box.
replace(file,'          draw->AddText(font, title_size, pos(76.0f, 15.0f), text_color,','          draw->PushClipRect(pos(text_state.position_x, text_state.position_y),\n                             pos(text_state.position_x + 283.0f,\n                                 text_state.position_y + 60.0f), true);\n          draw->AddText(font, title_size,\n                        pos(text_state.position_x, text_state.position_y + 15.0f), text_color,');
replace(file,'          draw->AddText(font, body_size, pos(76.0f, 34.0f), text_color,','          draw->AddText(font, body_size,\n                        pos(text_state.position_x, text_state.position_y + 34.0f), text_color,');
replace(file,'                        description.c_str());\n        }','                        description.c_str());\n          draw->PopClipRect();\n        }');
files[file]=files[file].replaceAll('XUI-POC7:', 'XUI-POC8:');
files['imgui_drawer.cc']=files['imgui_drawer.cc'].replaceAll('XUI-POC7:', 'XUI-POC8:');
if(files['xbox360_xui_runtime.cc'].split(evaluatorMarker)[0]!==originalEvaluator) throw new Error('PoC 6 evaluator changed unexpectedly');
if(!files['imgui_drawer.cc'].includes('Xbox360XuiRuntime::Get().Initialize("xbox360_ui")')) throw new Error('Runtime startup hook was lost');
for(const [name,data] of Object.entries(files)) fs.writeFileSync(path.join(destination,name),data);
console.log(`Applied PoC 8 original PNGs, pivot placement and border cleanup to ${Object.keys(files).length} files. PoC 6 evaluator preserved.`);
