param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  $header = @'
#pragma once

#include <cstddef>
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

struct Xbox360XuiKeyframe {
  uint32_t frame = 0;
  uint8_t raw_flag = 0;
  uint8_t flags = 0;
  uint8_t unknown_high = 0;
  uint8_t ease_in = 0;
  uint8_t ease_out = 0;
  uint8_t ease_scale = 0;
  uint32_t extra = 0;
  uint32_t property_index = 0;
};

struct Xbox360XuiTimelineProbe {
  std::string object_name;
  uint32_t animated_property_count = 0;
  uint32_t keyframe_count = 0;
  uint32_t keyframe_base_index = 0;
  uint32_t first_frame = 0;
  uint32_t last_frame = 0;
  size_t unknown_flag_count = 0;
};

struct Xbox360XuiFileSummary {
  bool valid = false;
  uint32_t version = 0;
  uint16_t tool_version = 0;
  uint16_t section_count = 0;
  size_t string_count = 0;
  size_t keyframe_count = 0;
  size_t keyp_count = 0;
  size_t data_size = 0;
  bool notification_timeline_found = false;
  size_t notification_timeline_offset = 0;
  bool notification_id_near_timeline = false;
  std::vector<std::string> strings;
  std::vector<uint32_t> keyp_indexes;
  std::vector<Xbox360XuiKeyframe> keyframes;
  std::vector<Xbox360XuiNamedFrame> named_frames;
  std::vector<Xbox360XuiTimelineProbe> notification_timelines;
};

class Xbox360XuiRuntime {
 public:
  static Xbox360XuiRuntime& Get();
  bool Initialize(const std::filesystem::path& root_path);
  bool ready() const { return ready_; }

  const Xbox360XuiFileSummary& notify_summary() const { return notify_summary_; }
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
#include "xenia/ui/xbox360_xui_runtime.h"

#include <algorithm>
#include <array>
#include <fstream>
#include <optional>
#include <unordered_set>
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
constexpr uint32_t kMagicKEYP = MakeMagic('K', 'E', 'Y', 'P');
constexpr uint32_t kMagicKEYD = MakeMagic('K', 'E', 'Y', 'D');
constexpr uint32_t kMagicNAME = MakeMagic('N', 'A', 'M', 'E');
constexpr uint32_t kMagicDATA = MakeMagic('D', 'A', 'T', 'A');

struct SectionEntry {
  uint32_t magic = 0;
  uint32_t offset = 0;
  uint32_t length = 0;
};

struct Cursor {
  const std::vector<uint8_t>* bytes = nullptr;
  size_t pos = 0;
  size_t limit = 0;

  bool CanRead(size_t count) const {
    if (!bytes) return false;
    const size_t effective_limit = limit ? limit : bytes->size();
    return pos <= effective_limit && count <= effective_limit - pos &&
           effective_limit <= bytes->size();
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
    if (first < 0xF0) {
      out = first;
      return true;
    }
    if (first != 0xFF) {
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

int FindStringIndex(const Xbox360XuiFileSummary& summary,
                    const std::string& value) {
  for (size_t i = 0; i < summary.strings.size(); ++i) {
    if (summary.strings[i] == value) return static_cast<int>(i);
  }
  return -1;
}

bool HasString(const Xbox360XuiFileSummary& summary,
               const std::string& value) {
  return FindStringIndex(summary, value) >= 0;
}

std::vector<uint8_t> EncodePackedUInt(uint32_t value) {
  std::vector<uint8_t> out;
  if (value < 0xF0) {
    out.push_back(static_cast<uint8_t>(value));
  } else if (value <= 0xFFF) {
    out.push_back(static_cast<uint8_t>(0xF0 | ((value >> 8) & 0x0F)));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
  } else {
    out.push_back(0xFF);
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
  }
  return out;
}

bool ParseTimelineCandidate(const std::vector<uint8_t>& bytes,
                            const SectionEntry& data,
                            const Xbox360XuiFileSummary& summary,
                            size_t candidate_offset,
                            std::vector<Xbox360XuiTimelineProbe>& out) {
  Cursor c{&bytes, candidate_offset,
           size_t(data.offset) + size_t(data.length)};
  uint32_t timeline_count = 0;
  if (!c.ReadPackedUInt(timeline_count) || timeline_count != 13) return false;

  static const std::array<const char*, 13> kExpectedNames = {
      "bgCurve1", "round",      "logoback",   "bg",        "explosion",
      "Indicator2", "Indicator4", "Indicator3", "Indicator1", "xenonLogo1",
      "Image",      "TextPresenter", "PopUpSound"};
  std::unordered_set<std::string> expected;
  for (const char* n : kExpectedNames) expected.insert(n);
  std::unordered_set<std::string> seen;

  std::vector<Xbox360XuiTimelineProbe> parsed;
  parsed.reserve(13);
  for (uint32_t t = 0; t < timeline_count; ++t) {
    uint32_t object_name_index = 0;
    uint32_t property_def_count = 0;
    if (!c.ReadPackedUInt(object_name_index) ||
        object_name_index >= summary.strings.size() ||
        !c.ReadPackedUInt(property_def_count) || property_def_count == 0 ||
        property_def_count > 32) {
      return false;
    }
    const std::string& object_name = summary.strings[object_name_index];
    if (!expected.count(object_name) || seen.count(object_name)) return false;
    seen.insert(object_name);

    for (uint32_t p = 0; p < property_def_count; ++p) {
      uint8_t packed = 0, class_index = 0;
      if (!c.ReadU8(packed) || !c.ReadU8(class_index)) return false;
      const uint32_t class_depth = packed & 0x7Fu;
      const bool indexed = (packed & 0x80u) != 0;
      if (class_depth == 0 || class_depth > 16) return false;
      for (uint32_t depth = 0; depth < class_depth; ++depth) {
        uint8_t property_index = 0;
        if (!c.ReadU8(property_index)) return false;
      }
      if (indexed) {
        uint32_t compound_index = 0;
        if (!c.ReadPackedUInt(compound_index)) return false;
      }
    }

    uint32_t keyframe_count = 0, keyframe_base = 0;
    if (!c.ReadPackedUInt(keyframe_count) || !c.ReadPackedUInt(keyframe_base) ||
        keyframe_count == 0 || keyframe_count > 512 ||
        keyframe_base >= summary.keyframes.size() ||
        keyframe_count > summary.keyframes.size() - keyframe_base) {
      return false;
    }

    Xbox360XuiTimelineProbe probe;
    probe.object_name = object_name;
    probe.animated_property_count = property_def_count;
    probe.keyframe_count = keyframe_count;
    probe.keyframe_base_index = keyframe_base;
    probe.first_frame = summary.keyframes[keyframe_base].frame;
    probe.last_frame = summary.keyframes[keyframe_base + keyframe_count - 1].frame;
    for (uint32_t k = 0; k < keyframe_count; ++k) {
      const auto& key = summary.keyframes[keyframe_base + k];
      if (key.flags != 0 && key.flags != 1 && key.flags != 2 && key.flags != 3) {
        ++probe.unknown_flag_count;
      }
    }
    parsed.push_back(std::move(probe));
  }

  if (seen.size() != expected.size()) return false;
  out = std::move(parsed);
  return true;
}

void ProbeNotificationTimelines(const std::vector<uint8_t>& bytes,
                                const SectionEntry& data,
                                Xbox360XuiFileSummary& summary) {
  summary.data_size = data.length;
  const size_t begin = data.offset;
  const size_t end = size_t(data.offset) + size_t(data.length);
  for (size_t pos = begin; pos < end; ++pos) {
    std::vector<Xbox360XuiTimelineProbe> candidate;
    if (!ParseTimelineCandidate(bytes, data, summary, pos, candidate)) continue;
    summary.notification_timeline_found = true;
    summary.notification_timeline_offset = pos - begin;
    summary.notification_timelines = std::move(candidate);

    const int scr_index = FindStringIndex(summary, "scr_Notification");
    if (scr_index >= 0) {
      const auto encoded = EncodePackedUInt(static_cast<uint32_t>(scr_index));
      const size_t back_begin = pos > 768 ? pos - 768 : begin;
      for (size_t q = back_begin; q + encoded.size() <= pos; ++q) {
        bool match = true;
        for (size_t b = 0; b < encoded.size(); ++b) {
          if (bytes[q + b] != encoded[b]) { match = false; break; }
        }
        if (match) {
          summary.notification_id_near_timeline = true;
          break;
        }
      }
    }
    return;
  }
}

bool ParseXur8(const std::filesystem::path& path,
               Xbox360XuiFileSummary& summary) {
  summary = {};
  auto file_data = ReadWholeFile(path);
  if (!file_data) {
    XELOGW("XUI-POC3: unable to open '{}'", path.generic_string());
    return false;
  }

  Cursor c{&*file_data, 0, file_data->size()};
  uint32_t magic = 0, version = 0, flags = 0, file_size = 0;
  uint16_t tool_version = 0, section_count = 0;
  if (!c.ReadBE32(magic) || !c.ReadBE32(version) || !c.ReadBE32(flags) ||
      !c.ReadBE16(tool_version) || !c.ReadBE32(file_size) ||
      !c.ReadBE16(section_count)) return false;
  if (magic != kMagicXUIB || version != 8 || file_size != file_data->size()) {
    XELOGE("XUI-POC3: invalid XUR8 '{}'", path.generic_string());
    return false;
  }

  std::array<uint32_t, 12> counts{};
  for (auto& count : counts) if (!c.ReadPackedUInt(count)) return false;

  std::vector<SectionEntry> sections;
  sections.reserve(section_count);
  for (uint16_t i = 0; i < section_count; ++i) {
    SectionEntry entry;
    if (!c.ReadBE32(entry.magic) || !c.ReadBE32(entry.offset) ||
        !c.ReadBE32(entry.length)) return false;
    if (entry.offset > file_data->size() ||
        entry.length > file_data->size() - entry.offset) return false;
    sections.push_back(entry);
  }

  if (const auto* strn = FindSection(sections, kMagicSTRN)) {
    Cursor s{&*file_data, strn->offset,
             size_t(strn->offset) + size_t(strn->length)};
    uint32_t total_string_bytes = 0;
    uint16_t strings_count = 0;
    if (!s.ReadBE32(total_string_bytes) || !s.ReadBE16(strings_count)) return false;
    summary.strings.emplace_back("");
    for (uint16_t i = 0; i < strings_count; ++i) {
      std::string value;
      while (s.CanRead(1)) {
        uint8_t ch = 0;
        if (!s.ReadU8(ch)) return false;
        if (!ch) break;
        value.push_back(static_cast<char>(ch));
      }
      summary.strings.push_back(std::move(value));
    }
  }

  if (const auto* keyp = FindSection(sections, kMagicKEYP)) {
    Cursor p{&*file_data, keyp->offset,
             size_t(keyp->offset) + size_t(keyp->length)};
    while (p.pos < p.limit) {
      uint32_t value = 0;
      if (!p.ReadPackedUInt(value)) return false;
      summary.keyp_indexes.push_back(value);
    }
  }

  if (const auto* keyd = FindSection(sections, kMagicKEYD)) {
    Cursor k{&*file_data, keyd->offset,
             size_t(keyd->offset) + size_t(keyd->length)};
    while (k.pos < k.limit) {
      Xbox360XuiKeyframe key;
      if (!k.ReadPackedUInt(key.frame) || !k.ReadU8(key.raw_flag)) return false;
      key.flags = key.raw_flag & 0x3Fu;
      key.unknown_high = key.raw_flag >> 6;
      if (key.flags == 0x02) {
        if (!k.ReadU8(key.ease_in) || !k.ReadU8(key.ease_out) ||
            !k.ReadU8(key.ease_scale)) return false;
      } else if (key.flags == 0x0A) {
        if (!k.ReadPackedUInt(key.extra)) return false;
      } else if (key.flags == 0x0B) {
        uint8_t extra = 0;
        if (!k.ReadU8(extra)) return false;
        key.extra = extra;
      }
      if (!k.ReadPackedUInt(key.property_index)) return false;
      summary.keyframes.push_back(key);
    }
  }

  if (const auto* name = FindSection(sections, kMagicNAME)) {
    Cursor n{&*file_data, name->offset,
             size_t(name->offset) + size_t(name->length)};
    while (n.pos < n.limit) {
      uint32_t string_index = 0, frame = 0;
      uint8_t command = 0;
      if (!n.ReadPackedUInt(string_index) || !n.ReadPackedUInt(frame) ||
          !n.ReadU8(command)) return false;
      Xbox360XuiNamedFrame nf;
      nf.frame = frame;
      nf.command = command;
      if (string_index < summary.strings.size()) nf.name = summary.strings[string_index];
      if (command == 2 || command == 3 || command == 4) {
        uint32_t target_index = 0;
        if (!n.ReadPackedUInt(target_index)) return false;
        if (target_index < summary.strings.size()) nf.target = summary.strings[target_index];
      }
      summary.named_frames.push_back(std::move(nf));
    }
  }

  if (const auto* data = FindSection(sections, kMagicDATA)) {
    ProbeNotificationTimelines(*file_data, *data, summary);
  }

  summary.valid = true;
  summary.version = version;
  summary.tool_version = tool_version;
  summary.section_count = section_count;
  summary.string_count = summary.strings.size();
  summary.keyframe_count = summary.keyframes.size();
  summary.keyp_count = summary.keyp_indexes.size();

  XELOGI("XUI-POC3: loaded '{}' sections={} strings={} KEYP={} KEYD={} NAME={} DATA={} bytes",
         path.generic_string(), summary.section_count, summary.string_count,
         summary.keyp_count, summary.keyframe_count, summary.named_frames.size(),
         summary.data_size);
  return true;
}

void LogNamedFrameMatches(const Xbox360XuiFileSummary& summary,
                          const std::string& name) {
  for (const auto& nf : summary.named_frames) {
    if (nf.name == name) {
      XELOGI("XUI-POC3: named-frame '{}' frame={} command={} target='{}'",
             nf.name, nf.frame, nf.command, nf.target);
    }
  }
}

void LogNotificationTimeline(const Xbox360XuiFileSummary& summary) {
  XELOGI("XUI-POC3: scr_Notification timeline-block found={} DATA+0x{:X} id-nearby={} timelines={}",
         summary.notification_timeline_found,
         summary.notification_timeline_offset,
         summary.notification_id_near_timeline,
         summary.notification_timelines.size());
  for (size_t i = 0; i < summary.notification_timelines.size(); ++i) {
    const auto& t = summary.notification_timelines[i];
    XELOGI("XUI-POC3: timeline[{}] object='{}' props={} keyframes={} base={} frames={}..{} unknown-flags={}",
           i, t.object_name, t.animated_property_count, t.keyframe_count,
           t.keyframe_base_index, t.first_frame, t.last_frame,
           t.unknown_flag_count);
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
  XELOGI("XUI-POC3: initializing native original-XUR timeline binder from '{}'",
         root_path_.generic_string());

  const bool notify_ok = ParseXur8(root_path_ / "notify.xur", notify_summary_);
  const bool skin_ok = ParseXur8(root_path_ / "skin.xur", skin_summary_);
  if (!notify_ok || !skin_ok) {
    XELOGW("XUI-POC3: XUR load failed");
    return false;
  }

  const bool graph_ok = HasString(notify_summary_, "NotifyPopupScene") &&
                        HasString(notify_summary_, "scr_Notification") &&
                        HasString(skin_summary_, "scr_Notification") &&
                        HasString(skin_summary_, "xam://xenonLogo.png") &&
                        HasString(skin_summary_, "NotifyPopup.xma");

  LogNamedFrameMatches(skin_summary_, "TransTo");
  LogNamedFrameMatches(skin_summary_, "loop");
  LogNamedFrameMatches(skin_summary_, "EndTransTo");
  LogNamedFrameMatches(skin_summary_, "TransFrom");
  LogNamedFrameMatches(skin_summary_, "EndTransFrom");
  LogNotificationTimeline(skin_summary_);

  bool all_known_flags = true;
  for (const auto& timeline : skin_summary_.notification_timelines) {
    if (timeline.unknown_flag_count) all_known_flags = false;
  }

  ready_ = graph_ok && skin_summary_.notification_timeline_found &&
           skin_summary_.notification_timelines.size() == 13 && all_known_flags;
  XELOGI("XUI-POC3: runtime timeline binding ready={}", ready_);
  return ready_;
}

}  // namespace ui
}  // namespace xe
'@

  [IO.File]::WriteAllText(
      (Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.h"),
      $header, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText(
      (Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.cc"),
      $source, [Text.UTF8Encoding]::new($false))

  Write-Host "Applied XUI runtime PoC 3 native DATA/KEYP/KEYD timeline probe."
} finally {
  Pop-Location
}
