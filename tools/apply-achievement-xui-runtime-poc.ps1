param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  $header = @'
/**
 ******************************************************************************
 * Xbox 360 XUI runtime proof-of-concept for Xenia Canary.
 * Loads original XUR8 resources from the user's own Xbox 360 dashboard.
 ******************************************************************************
 */
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace xe {
namespace ui {

struct Xbox360XuiNamedFrame {
  std::string name;
  uint32_t frame = 0;
  uint8_t command = 0;
  std::string target;
};

struct Xbox360XuiFileSummary {
  bool valid = false;
  uint32_t version = 0;
  uint16_t tool_version = 0;
  uint16_t section_count = 0;
  size_t string_count = 0;
  size_t keyframe_count = 0;
  std::vector<std::string> strings;
  std::vector<Xbox360XuiNamedFrame> named_frames;
};

class Xbox360XuiRuntime {
 public:
  static Xbox360XuiRuntime& Get();

  bool Initialize(const std::filesystem::path& root_path);
  bool ready() const { return ready_; }

  const Xbox360XuiFileSummary& notify_summary() const {
    return notify_summary_;
  }
  const Xbox360XuiFileSummary& skin_summary() const { return skin_summary_; }

 private:
  Xbox360XuiRuntime() = default;

  bool ready_ = false;
  std::filesystem::path root_path_;
  Xbox360XuiFileSummary notify_summary_;
  Xbox360XuiFileSummary skin_summary_;
};

}  // namespace ui
}  // namespace xe
'@

  $source = @'
/**
 ******************************************************************************
 * Xbox 360 XUI runtime proof-of-concept for Xenia Canary.
 * This is intentionally a parser/runtime foundation, not an ImGui recreation.
 ******************************************************************************
 */

#include "xenia/ui/xbox360_xui_runtime.h"

#include <algorithm>
#include <array>
#include <fstream>
#include <optional>
#include <unordered_map>
#include <utility>
#include <vector>

#include "xenia/base/logging.h"

namespace xe {
namespace ui {
namespace {

constexpr uint32_t MakeMagic(char a, char b, char c, char d) {
  return (uint32_t(uint8_t(a)) << 24) | (uint32_t(uint8_t(b)) << 16) |
         (uint32_t(uint8_t(c)) << 8) | uint32_t(uint8_t(d));
}

constexpr uint32_t kMagicXUIB = MakeMagic('X', 'U', 'I', 'B');
constexpr uint32_t kMagicSTRN = MakeMagic('S', 'T', 'R', 'N');
constexpr uint32_t kMagicKEYD = MakeMagic('K', 'E', 'Y', 'D');
constexpr uint32_t kMagicNAME = MakeMagic('N', 'A', 'M', 'E');

struct SectionEntry {
  uint32_t magic = 0;
  uint32_t offset = 0;
  uint32_t length = 0;
};

struct Cursor {
  const std::vector<uint8_t>* bytes = nullptr;
  size_t pos = 0;

  bool CanRead(size_t count) const {
    return bytes && pos <= bytes->size() && count <= bytes->size() - pos;
  }

  bool ReadU8(uint8_t& out) {
    if (!CanRead(1)) return false;
    out = (*bytes)[pos++];
    return true;
  }

  bool ReadBE16(uint16_t& out) {
    if (!CanRead(2)) return false;
    out = (uint16_t((*bytes)[pos]) << 8) | uint16_t((*bytes)[pos + 1]);
    pos += 2;
    return true;
  }

  bool ReadBE32(uint32_t& out) {
    if (!CanRead(4)) return false;
    out = (uint32_t((*bytes)[pos]) << 24) |
          (uint32_t((*bytes)[pos + 1]) << 16) |
          (uint32_t((*bytes)[pos + 2]) << 8) |
          uint32_t((*bytes)[pos + 3]);
    pos += 4;
    return true;
  }

  bool ReadPackedUInt(uint32_t& out) {
    uint8_t first = 0;
    if (!ReadU8(first)) return false;
    if (first != 0xFF) {
      if (first < 0xF0) {
        out = first;
        return true;
      }
      uint8_t second = 0;
      if (!ReadU8(second)) return false;
      out = ((uint32_t(first) << 8) & 0xF00u) | uint32_t(second);
      return true;
    }
    return ReadBE32(out);
  }
};

std::optional<std::vector<uint8_t>> ReadWholeFile(
    const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) return std::nullopt;
  const auto end = file.tellg();
  if (end <= 0) return std::nullopt;
  std::vector<uint8_t> data(static_cast<size_t>(end));
  file.seekg(0, std::ios::beg);
  file.read(reinterpret_cast<char*>(data.data()),
            static_cast<std::streamsize>(data.size()));
  if (!file) return std::nullopt;
  return data;
}

const SectionEntry* FindSection(const std::vector<SectionEntry>& sections,
                                uint32_t magic) {
  for (const auto& section : sections) {
    if (section.magic == magic) return &section;
  }
  return nullptr;
}

bool HasString(const Xbox360XuiFileSummary& summary,
               const std::string& needle) {
  return std::find(summary.strings.begin(), summary.strings.end(), needle) !=
         summary.strings.end();
}

bool ParseXur8(const std::filesystem::path& path,
               Xbox360XuiFileSummary& summary) {
  summary = {};
  auto file_data = ReadWholeFile(path);
  if (!file_data) {
    XELOGW("XUI-POC: unable to open '{}'", path.generic_string());
    return false;
  }

  Cursor c{&*file_data, 0};
  uint32_t magic = 0, version = 0, flags = 0, file_size = 0;
  uint16_t tool_version = 0, section_count = 0;
  if (!c.ReadBE32(magic) || !c.ReadBE32(version) || !c.ReadBE32(flags) ||
      !c.ReadBE16(tool_version) || !c.ReadBE32(file_size) ||
      !c.ReadBE16(section_count)) {
    XELOGE("XUI-POC: truncated XUR header in '{}'", path.generic_string());
    return false;
  }
  if (magic != kMagicXUIB || version != 8 || file_size != file_data->size()) {
    XELOGE(
        "XUI-POC: invalid XUR8 '{}': magic={:08X} version={} size={} actual={}",
        path.generic_string(), magic, version, file_size, file_data->size());
    return false;
  }

  // XUR8 always carries a 12-field packed count header before the section
  // table. Keeping this parser faithful to XUIHelper's reversed format is the
  // first step toward executing the original scene rather than guessing it.
  std::array<uint32_t, 12> counts{};
  for (auto& value : counts) {
    if (!c.ReadPackedUInt(value)) {
      XELOGE("XUI-POC: truncated count header in '{}'", path.generic_string());
      return false;
    }
  }

  std::vector<SectionEntry> sections;
  sections.reserve(section_count);
  for (uint16_t i = 0; i < section_count; ++i) {
    SectionEntry entry;
    if (!c.ReadBE32(entry.magic) || !c.ReadBE32(entry.offset) ||
        !c.ReadBE32(entry.length)) {
      XELOGE("XUI-POC: truncated section table in '{}'", path.generic_string());
      return false;
    }
    if (entry.offset > file_data->size() ||
        entry.length > file_data->size() - entry.offset) {
      XELOGE("XUI-POC: section outside file in '{}'", path.generic_string());
      return false;
    }
    sections.push_back(entry);
  }

  // STRN8 - system string pool used by DATA/NAME/timelines.
  if (const SectionEntry* strn = FindSection(sections, kMagicSTRN)) {
    Cursor s{&*file_data, strn->offset};
    uint32_t total_string_bytes = 0;
    uint16_t strings_count = 0;
    if (!s.ReadBE32(total_string_bytes) || !s.ReadBE16(strings_count)) {
      return false;
    }
    summary.strings.emplace_back("");  // implicit index 0 in XUR8.
    for (uint16_t i = 0; i < strings_count; ++i) {
      std::string value;
      while (s.CanRead(1)) {
        uint8_t ch = 0;
        s.ReadU8(ch);
        if (ch == 0) break;
        value.push_back(static_cast<char>(ch));
      }
      summary.strings.push_back(std::move(value));
    }
  }

  // NAME8 - named frame commands (Play/Stop/GoTo/GoToAndPlay/GoToAndStop).
  if (const SectionEntry* name = FindSection(sections, kMagicNAME)) {
    Cursor n{&*file_data, name->offset};
    const size_t end = size_t(name->offset) + size_t(name->length);
    while (n.pos < end) {
      uint32_t string_index = 0, frame = 0;
      uint8_t command = 0;
      if (!n.ReadPackedUInt(string_index) || !n.ReadPackedUInt(frame) ||
          !n.ReadU8(command)) {
        return false;
      }
      Xbox360XuiNamedFrame nf;
      nf.frame = frame;
      nf.command = command;
      if (string_index < summary.strings.size()) {
        nf.name = summary.strings[string_index];
      }
      if (command == 2 || command == 3 || command == 4) {
        uint32_t target_index = 0;
        if (!n.ReadPackedUInt(target_index)) return false;
        if (target_index < summary.strings.size()) {
          nf.target = summary.strings[target_index];
        }
      }
      summary.named_frames.push_back(std::move(nf));
    }
  }

  // KEYD8 - validate and count real keyframe records. Full property/object
  // binding will be added in the next milestone with KEYP8 + DATA8.
  if (const SectionEntry* keyd = FindSection(sections, kMagicKEYD)) {
    Cursor k{&*file_data, keyd->offset};
    const size_t end = size_t(keyd->offset) + size_t(keyd->length);
    while (k.pos < end) {
      uint32_t frame = 0, property_index = 0;
      uint8_t flag_byte = 0;
      if (!k.ReadPackedUInt(frame) || !k.ReadU8(flag_byte)) return false;
      const uint8_t flags6 = flag_byte & 0x3F;
      if (flags6 == 0x02) {
        uint8_t a = 0, b = 0, d = 0;
        if (!k.ReadU8(a) || !k.ReadU8(b) || !k.ReadU8(d)) return false;
      } else if (flags6 == 0x0A) {
        uint32_t ignored = 0;
        if (!k.ReadPackedUInt(ignored)) return false;
      } else if (flags6 == 0x0B) {
        uint8_t ignored = 0;
        if (!k.ReadU8(ignored)) return false;
      }
      if (!k.ReadPackedUInt(property_index)) return false;
      ++summary.keyframe_count;
    }
  }

  summary.valid = true;
  summary.version = version;
  summary.tool_version = tool_version;
  summary.section_count = section_count;
  summary.string_count = summary.strings.size();

  XELOGI(
      "XUI-POC: loaded '{}' XUR8 tool={} sections={} strings={} keyframes={} named_frames={}",
      path.generic_string(), summary.tool_version, summary.section_count,
      summary.string_count, summary.keyframe_count,
      summary.named_frames.size());
  return true;
}

void LogNamedFrameMatches(const Xbox360XuiFileSummary& summary,
                          const std::string& name) {
  for (const auto& nf : summary.named_frames) {
    if (nf.name == name) {
      XELOGI("XUI-POC: named-frame '{}' frame={} command={} target='{}'",
             nf.name, nf.frame, nf.command, nf.target);
    }
  }
}

}  // namespace

Xbox360XuiRuntime& Xbox360XuiRuntime::Get() {
  static Xbox360XuiRuntime runtime;
  return runtime;
}

bool Xbox360XuiRuntime::Initialize(const std::filesystem::path& root_path) {
  root_path_ = root_path;
  ready_ = false;

  XELOGI("XUI-POC: initializing original Xbox 360 XUI runtime from '{}'",
         root_path_.generic_string());

  const bool notify_ok = ParseXur8(root_path_ / "notify.xur", notify_summary_);
  const bool skin_ok = ParseXur8(root_path_ / "skin.xur", skin_summary_);
  if (!notify_ok || !skin_ok) {
    XELOGW(
        "XUI-POC: not ready. Put notify.xur and skin.xur in xbox360_ui next to the existing original PNG assets.");
    return false;
  }

  const bool notify_scene = HasString(notify_summary_, "NotifyPopupScene");
  const bool scr_notification = HasString(notify_summary_, "scr_Notification") &&
                                HasString(skin_summary_, "scr_Notification");
  const bool xenon_logo = HasString(skin_summary_, "xam://xenonLogo.png");
  const bool popup_sound = HasString(skin_summary_, "NotifyPopup.xma");
  const bool indicators = HasString(skin_summary_, "Indicator1") &&
                          HasString(skin_summary_, "Indicator2") &&
                          HasString(skin_summary_, "Indicator3") &&
                          HasString(skin_summary_, "Indicator4");

  XELOGI(
      "XUI-POC: resource graph NotifyPopupScene={} scr_Notification={} xenonLogo={} NotifyPopupSound={} Indicators1-4={}",
      notify_scene, scr_notification, xenon_logo, popup_sound, indicators);

  LogNamedFrameMatches(skin_summary_, "TransTo");
  LogNamedFrameMatches(skin_summary_, "EndTransTo");
  LogNamedFrameMatches(skin_summary_, "loop");
  LogNamedFrameMatches(skin_summary_, "TransFrom");
  LogNamedFrameMatches(skin_summary_, "EndTransFrom");

  ready_ = notify_scene && scr_notification && xenon_logo && popup_sound &&
           indicators;
  XELOGI("XUI-POC: runtime foundation ready={}", ready_);
  return ready_;
}

}  // namespace ui
}  // namespace xe
'@

  New-Item -ItemType Directory -Force -Path "src/xenia/ui" | Out-Null
  [IO.File]::WriteAllText(
      (Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.h"),
      $header, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText(
      (Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.cc"),
      $source, [Text.UTF8Encoding]::new($false))

  # Initialize the parser/runtime foundation when ImGuiDrawer initializes.
  $drawer = "src/xenia/ui/imgui_drawer.cc"
  $dc = Get-Content $drawer -Raw
  $includeNeedle = '#include "xenia/ui/imgui_notification.h"'
  $includeInsert = @'
#include "xenia/ui/imgui_notification.h"
#include "xenia/ui/xbox360_xui_runtime.h"
'@
  if (!$dc.Contains($includeNeedle)) { throw "imgui_drawer.cc include anchor not found" }
  $dc = $dc.Replace($includeNeedle, $includeInsert.TrimEnd())

  $setupNeedle = @'
    SetupFontTexture();
    SetupNotificationTextures();
'@
  $setupInsert = @'
    SetupFontTexture();
    SetupNotificationTextures();

    // Xbox 360 XUI PoC: load the original XUR8 scene resources at runtime.
    Xbox360XuiRuntime::Get().Initialize("xbox360_ui");
'@
  if (!$dc.Contains($setupNeedle)) { throw "imgui_drawer.cc setup anchor not found" }
  $dc = $dc.Replace($setupNeedle, $setupInsert)
  [IO.File]::WriteAllText((Resolve-Path $drawer), $dc,
                          [Text.UTF8Encoding]::new($false))

  Write-Host "Xbox 360 XUI runtime PoC parser inserted."
}
finally {
  Pop-Location
}
