param(
  [Parameter(Mandatory = $true)]
  [string]$XeniaPath
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path $XeniaPath).Path
Push-Location $root
try {
  $source = @'
#include "xenia/ui/xbox360_xui_runtime.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <optional>
#include <sstream>
#include <string>
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
constexpr uint32_t kMagicVECT = MakeMagic('V', 'E', 'C', 'T');
constexpr uint32_t kMagicQUAT = MakeMagic('Q', 'U', 'A', 'T');
constexpr uint32_t kMagicFLOT = MakeMagic('F', 'L', 'O', 'T');
constexpr uint32_t kMagicCOLR = MakeMagic('C', 'O', 'L', 'R');
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
    return effective_limit <= bytes->size() && pos <= effective_limit &&
           count <= effective_limit - pos;
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

  bool ReadBEFloat(float& out) {
    uint32_t bits = 0;
    if (!ReadBE32(bits)) return false;
    static_assert(sizeof(float) == sizeof(uint32_t));
    std::memcpy(&out, &bits, sizeof(out));
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

struct Vec3 {
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
};

enum class PropertyKind {
  kUnknown,
  kBool,
  kUnsigned,
  kFloat,
  kVector,
  kString,
};

struct PropertyDescriptor {
  uint8_t class_index = 0;
  bool indexed = false;
  std::vector<uint8_t> path;
  uint32_t compound_index = 0;
  std::string name;
  PropertyKind kind = PropertyKind::kUnknown;
};

struct TimelineDetails {
  Xbox360XuiTimelineProbe probe;
  std::vector<PropertyDescriptor> properties;
};

struct ParsedDetails {
  std::vector<float> floats;
  std::vector<Vec3> vectors;
  std::vector<std::array<float, 4>> quaternions;
  std::vector<uint32_t> colours;
  std::vector<TimelineDetails> notification_timelines;
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

void ResolveNotificationPropertySchema(const std::string& object_name,
                                       PropertyDescriptor& property) {
  if (property.path.size() != 1) return;
  const uint8_t property_index = property.path[0];

  // XUI core XuiElement property schema. The DATA8 timeline descriptor tells
  // us the class depth/index and property index; values still come exclusively
  // from the user's original XUR pools through KEYP8.
  if (property.class_index == 1) {
    switch (property_index) {
      case 3:
        property.name = "Position";
        property.kind = PropertyKind::kVector;
        return;
      case 4:
        property.name = "Scale";
        property.kind = PropertyKind::kVector;
        return;
      case 6:
        property.name = "Opacity";
        property.kind = PropertyKind::kFloat;
        return;
      case 7:
        property.name = "Anchor";
        property.kind = PropertyKind::kUnsigned;
        return;
      case 9:
        property.name = "Show";
        property.kind = PropertyKind::kBool;
        return;
      default:
        return;
    }
  }

  // XuiSoundXAudio::File. This is the only non-XuiElement animated property
  // used by scr_Notification in the 17559 notification scene.
  if (object_name == "PopUpSound" && property.class_index == 0 &&
      property_index == 0) {
    property.name = "File";
    property.kind = PropertyKind::kString;
  }
}

bool ParseTimelineCandidate(const std::vector<uint8_t>& bytes,
                            const SectionEntry& data,
                            const Xbox360XuiFileSummary& summary,
                            size_t candidate_offset,
                            std::vector<TimelineDetails>& out) {
  Cursor c{&bytes, candidate_offset,
           size_t(data.offset) + size_t(data.length)};
  uint32_t timeline_count = 0;
  if (!c.ReadPackedUInt(timeline_count) || timeline_count != 13) return false;

  static const std::array<const char*, 13> kExpectedNames = {
      "bgCurve1", "round", "logoback", "bg", "explosion", "Indicator2",
      "Indicator4", "Indicator3", "Indicator1", "xenonLogo1", "Image",
      "TextPresenter", "PopUpSound"};
  std::unordered_set<std::string> expected;
  for (const char* n : kExpectedNames) expected.insert(n);
  std::unordered_set<std::string> seen;

  std::vector<TimelineDetails> parsed;
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

    TimelineDetails details;
    details.probe.object_name = object_name;
    details.probe.animated_property_count = property_def_count;
    details.properties.reserve(property_def_count);

    for (uint32_t p = 0; p < property_def_count; ++p) {
      uint8_t packed = 0, class_index = 0;
      if (!c.ReadU8(packed) || !c.ReadU8(class_index)) return false;
      const uint32_t class_depth = packed & 0x7Fu;
      const bool indexed = (packed & 0x80u) != 0;
      if (class_depth == 0 || class_depth > 16) return false;

      PropertyDescriptor property;
      property.class_index = class_index;
      property.indexed = indexed;
      property.path.reserve(class_depth);
      for (uint32_t depth = 0; depth < class_depth; ++depth) {
        uint8_t property_index = 0;
        if (!c.ReadU8(property_index)) return false;
        property.path.push_back(property_index);
      }
      if (indexed) {
        if (!c.ReadPackedUInt(property.compound_index)) return false;
      }
      ResolveNotificationPropertySchema(object_name, property);
      details.properties.push_back(std::move(property));
    }

    uint32_t keyframe_count = 0, keyframe_base = 0;
    if (!c.ReadPackedUInt(keyframe_count) || !c.ReadPackedUInt(keyframe_base) ||
        keyframe_count == 0 || keyframe_count > 512 ||
        keyframe_base >= summary.keyframes.size() ||
        keyframe_count > summary.keyframes.size() - keyframe_base) {
      return false;
    }

    details.probe.keyframe_count = keyframe_count;
    details.probe.keyframe_base_index = keyframe_base;
    details.probe.first_frame = summary.keyframes[keyframe_base].frame;
    details.probe.last_frame =
        summary.keyframes[keyframe_base + keyframe_count - 1].frame;
    for (uint32_t k = 0; k < keyframe_count; ++k) {
      const auto& key = summary.keyframes[keyframe_base + k];
      if (key.flags != 0 && key.flags != 1 && key.flags != 2 &&
          key.flags != 3) {
        ++details.probe.unknown_flag_count;
      }
    }
    parsed.push_back(std::move(details));
  }

  if (seen.size() != expected.size()) return false;
  out = std::move(parsed);
  return true;
}

void ProbeNotificationTimelines(const std::vector<uint8_t>& bytes,
                                const SectionEntry& data,
                                Xbox360XuiFileSummary& summary,
                                ParsedDetails& parsed_details) {
  summary.data_size = data.length;
  const size_t begin = data.offset;
  const size_t end = size_t(data.offset) + size_t(data.length);
  for (size_t pos = begin; pos < end; ++pos) {
    std::vector<TimelineDetails> candidate;
    if (!ParseTimelineCandidate(bytes, data, summary, pos, candidate)) continue;

    summary.notification_timeline_found = true;
    summary.notification_timeline_offset = pos - begin;
    summary.notification_timelines.clear();
    for (const auto& timeline : candidate) {
      summary.notification_timelines.push_back(timeline.probe);
    }
    parsed_details.notification_timelines = std::move(candidate);

    const int scr_index = FindStringIndex(summary, "scr_Notification");
    if (scr_index >= 0) {
      const auto encoded = EncodePackedUInt(static_cast<uint32_t>(scr_index));
      const size_t back_begin = pos > 768 ? pos - 768 : begin;
      for (size_t q = back_begin; q + encoded.size() <= pos; ++q) {
        bool match = true;
        for (size_t b = 0; b < encoded.size(); ++b) {
          if (bytes[q + b] != encoded[b]) {
            match = false;
            break;
          }
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
               Xbox360XuiFileSummary& summary, ParsedDetails& details) {
  summary = {};
  details = {};
  auto file_data = ReadWholeFile(path);
  if (!file_data) {
    XELOGW("XUI-POC4: unable to open '{}'", path.generic_string());
    return false;
  }

  Cursor c{&*file_data, 0, file_data->size()};
  uint32_t magic = 0, version = 0, flags = 0, file_size = 0;
  uint16_t tool_version = 0, section_count = 0;
  if (!c.ReadBE32(magic) || !c.ReadBE32(version) || !c.ReadBE32(flags) ||
      !c.ReadBE16(tool_version) || !c.ReadBE32(file_size) ||
      !c.ReadBE16(section_count)) {
    return false;
  }
  if (magic != kMagicXUIB || version != 8 || file_size != file_data->size()) {
    XELOGE("XUI-POC4: invalid XUR8 '{}'", path.generic_string());
    return false;
  }

  std::array<uint32_t, 12> counts{};
  for (auto& count : counts) {
    if (!c.ReadPackedUInt(count)) return false;
  }

  std::vector<SectionEntry> sections;
  sections.reserve(section_count);
  for (uint16_t i = 0; i < section_count; ++i) {
    SectionEntry entry;
    if (!c.ReadBE32(entry.magic) || !c.ReadBE32(entry.offset) ||
        !c.ReadBE32(entry.length)) {
      return false;
    }
    if (entry.offset > file_data->size() ||
        entry.length > file_data->size() - entry.offset) {
      return false;
    }
    sections.push_back(entry);
  }

  if (const auto* strn = FindSection(sections, kMagicSTRN)) {
    Cursor s{&*file_data, strn->offset,
             size_t(strn->offset) + size_t(strn->length)};
    uint32_t total_string_bytes = 0;
    uint16_t strings_count = 0;
    if (!s.ReadBE32(total_string_bytes) || !s.ReadBE16(strings_count)) {
      return false;
    }
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

  if (const auto* vect = FindSection(sections, kMagicVECT)) {
    if ((vect->length % 12) != 0) return false;
    Cursor v{&*file_data, vect->offset,
             size_t(vect->offset) + size_t(vect->length)};
    while (v.pos < v.limit) {
      Vec3 value;
      if (!v.ReadBEFloat(value.x) || !v.ReadBEFloat(value.y) ||
          !v.ReadBEFloat(value.z)) {
        return false;
      }
      details.vectors.push_back(value);
    }
  }

  if (const auto* quat = FindSection(sections, kMagicQUAT)) {
    if ((quat->length % 16) != 0) return false;
    Cursor q{&*file_data, quat->offset,
             size_t(quat->offset) + size_t(quat->length)};
    while (q.pos < q.limit) {
      std::array<float, 4> value{};
      for (float& component : value) {
        if (!q.ReadBEFloat(component)) return false;
      }
      details.quaternions.push_back(value);
    }
  }

  if (const auto* flot = FindSection(sections, kMagicFLOT)) {
    if ((flot->length % 4) != 0) return false;
    Cursor f{&*file_data, flot->offset,
             size_t(flot->offset) + size_t(flot->length)};
    while (f.pos < f.limit) {
      float value = 0.0f;
      if (!f.ReadBEFloat(value)) return false;
      details.floats.push_back(value);
    }
  }

  if (const auto* colr = FindSection(sections, kMagicCOLR)) {
    if ((colr->length % 4) != 0) return false;
    Cursor r{&*file_data, colr->offset,
             size_t(colr->offset) + size_t(colr->length)};
    while (r.pos < r.limit) {
      uint32_t value = 0;
      if (!r.ReadBE32(value)) return false;
      details.colours.push_back(value);
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
            !k.ReadU8(key.ease_scale)) {
          return false;
        }
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

  if (const auto* data = FindSection(sections, kMagicDATA)) {
    ProbeNotificationTimelines(*file_data, *data, summary, details);
  }

  summary.valid = true;
  summary.version = version;
  summary.tool_version = tool_version;
  summary.section_count = section_count;
  summary.string_count = summary.strings.size();
  summary.keyframe_count = summary.keyframes.size();
  summary.keyp_count = summary.keyp_indexes.size();

  XELOGI(
      "XUI-POC4: loaded '{}' sections={} strings={} FLOT={} VECT={} QUAT={} COLR={} KEYP={} KEYD={} NAME={} DATA={} bytes",
      path.generic_string(), summary.section_count, summary.string_count,
      details.floats.size(), details.vectors.size(), details.quaternions.size(),
      details.colours.size(), summary.keyp_count, summary.keyframe_count,
      summary.named_frames.size(), summary.data_size);
  return true;
}

const char* InterpolationName(uint8_t flags) {
  switch (flags) {
    case 0:
      return "Linear";
    case 1:
      return "None";
    case 2:
      return "Ease";
    case 3:
      return "Linear3";
    default:
      return "Unknown";
  }
}

const char* PropertyKindName(PropertyKind kind) {
  switch (kind) {
    case PropertyKind::kBool:
      return "bool";
    case PropertyKind::kUnsigned:
      return "unsigned";
    case PropertyKind::kFloat:
      return "float";
    case PropertyKind::kVector:
      return "vector";
    case PropertyKind::kString:
      return "string";
    default:
      return "unknown";
  }
}

std::string FormatFloat(float value) {
  std::ostringstream stream;
  stream << std::fixed << std::setprecision(6) << value;
  return stream.str();
}

bool ResolveValue(const Xbox360XuiFileSummary& summary,
                  const ParsedDetails& details,
                  const Xbox360XuiKeyframe& keyframe,
                  size_t animated_property_index,
                  const PropertyDescriptor& property,
                  std::string& value_string) {
  const size_t keyp_offset =
      size_t(keyframe.property_index) + animated_property_index;
  if (keyp_offset >= summary.keyp_indexes.size()) return false;
  const uint32_t value_index = summary.keyp_indexes[keyp_offset];

  switch (property.kind) {
    case PropertyKind::kBool:
      value_string = value_index ? "true" : "false";
      return true;
    case PropertyKind::kUnsigned:
      value_string = std::to_string(value_index);
      return true;
    case PropertyKind::kFloat:
      if (value_index >= details.floats.size()) return false;
      value_string = FormatFloat(details.floats[value_index]);
      return true;
    case PropertyKind::kVector: {
      if (value_index >= details.vectors.size()) return false;
      const auto& value = details.vectors[value_index];
      value_string = "(" + FormatFloat(value.x) + "," + FormatFloat(value.y) +
                     "," + FormatFloat(value.z) + ")";
      return true;
    }
    case PropertyKind::kString:
      if (value_index >= summary.strings.size()) return false;
      value_string = "\"" + summary.strings[value_index] + "\"";
      return true;
    default:
      value_string = "raw-index=" + std::to_string(value_index);
      return false;
  }
}

void LogNamedFrameMatches(const Xbox360XuiFileSummary& summary,
                          const std::string& name) {
  for (const auto& nf : summary.named_frames) {
    if (nf.name == name) {
      XELOGI("XUI-POC4: named-frame '{}' frame={} command={} target='{}'",
             nf.name, nf.frame, nf.command, nf.target);
    }
  }
}

bool LogResolvedNotificationTimelines(const Xbox360XuiFileSummary& summary,
                                      const ParsedDetails& details) {
  XELOGI(
      "XUI-POC4: scr_Notification timeline-block found={} DATA+0x{:X} id-nearby={} timelines={}",
      summary.notification_timeline_found,
      summary.notification_timeline_offset,
      summary.notification_id_near_timeline,
      details.notification_timelines.size());

  bool all_resolved = true;
  size_t resolved_keyframes = 0;
  size_t resolved_values = 0;

  for (size_t i = 0; i < details.notification_timelines.size(); ++i) {
    const auto& timeline = details.notification_timelines[i];
    const auto& probe = timeline.probe;

    std::ostringstream schema;
    for (size_t p = 0; p < timeline.properties.size(); ++p) {
      if (p) schema << ", ";
      const auto& property = timeline.properties[p];
      if (property.name.empty()) {
        schema << "class" << unsigned(property.class_index) << ":path";
        for (uint8_t index : property.path) schema << "/" << unsigned(index);
        schema << ":unknown";
        all_resolved = false;
      } else {
        schema << property.name << ":" << PropertyKindName(property.kind);
      }
    }

    XELOGI(
        "XUI-POC4: timeline[{}] object='{}' schema=[{}] keyframes={} base={} frames={}..{} unknown-flags={}",
        i, probe.object_name, schema.str(), probe.keyframe_count,
        probe.keyframe_base_index, probe.first_frame, probe.last_frame,
        probe.unknown_flag_count);

    for (uint32_t k = 0; k < probe.keyframe_count; ++k) {
      const size_t key_index = size_t(probe.keyframe_base_index) + k;
      if (key_index >= summary.keyframes.size()) {
        all_resolved = false;
        continue;
      }
      const auto& keyframe = summary.keyframes[key_index];
      std::ostringstream values;
      bool key_resolved = true;
      for (size_t p = 0; p < timeline.properties.size(); ++p) {
        if (p) values << "; ";
        const auto& property = timeline.properties[p];
        std::string value;
        const bool resolved = ResolveValue(summary, details, keyframe, p,
                                           property, value);
        if (!resolved) key_resolved = false;
        values << (property.name.empty() ? "?" : property.name) << "="
               << value;
        if (resolved) ++resolved_values;
      }
      if (!key_resolved) all_resolved = false;
      if (key_resolved) ++resolved_keyframes;

      XELOGI(
          "XUI-POC4: key object='{}' frame={} interp={} raw_flag=0x{:02X} ease={}/{}/{} keyp_base={} values=[{}]",
          probe.object_name, keyframe.frame, InterpolationName(keyframe.flags),
          keyframe.raw_flag, keyframe.ease_in, keyframe.ease_out,
          keyframe.ease_scale, keyframe.property_index, values.str());
    }
  }

  XELOGI(
      "XUI-POC4: resolved notification properties keyframes={} values={} all_resolved={}",
      resolved_keyframes, resolved_values, all_resolved);
  return all_resolved;
}

}  // namespace

Xbox360XuiRuntime& Xbox360XuiRuntime::Get() {
  static Xbox360XuiRuntime runtime;
  return runtime;
}

bool Xbox360XuiRuntime::Initialize(const std::filesystem::path& root_path) {
  root_path_ = root_path;
  ready_ = false;
  XELOGI(
      "XUI-POC4: initializing original-XUR property/value binder from '{}'",
      root_path_.generic_string());

  ParsedDetails notify_details;
  ParsedDetails skin_details;
  const bool notify_ok =
      ParseXur8(root_path_ / "notify.xur", notify_summary_, notify_details);
  const bool skin_ok =
      ParseXur8(root_path_ / "skin.xur", skin_summary_, skin_details);
  if (!notify_ok || !skin_ok) {
    XELOGW("XUI-POC4: XUR load failed");
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

  bool all_known_flags = true;
  for (const auto& timeline : skin_summary_.notification_timelines) {
    if (timeline.unknown_flag_count) all_known_flags = false;
  }

  const bool property_values_ok =
      LogResolvedNotificationTimelines(skin_summary_, skin_details);

  ready_ = graph_ok && skin_summary_.notification_timeline_found &&
           skin_details.notification_timelines.size() == 13 &&
           all_known_flags && property_values_ok;
  XELOGI("XUI-POC4: runtime property binding ready={}", ready_);
  return ready_;
}

}  // namespace ui
}  // namespace xe
'@

  [IO.File]::WriteAllText(
      (Join-Path (Get-Location) "src/xenia/ui/xbox360_xui_runtime.cc"),
      $source, [Text.UTF8Encoding]::new($false))

  Write-Host "Applied XUI runtime PoC 4 FLOT/VECT/KEYP resolved property binder."
} finally {
  Pop-Location
}
