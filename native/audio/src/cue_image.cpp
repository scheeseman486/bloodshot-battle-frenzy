#include "cue_image.h"
#include <algorithm>
#include <filesystem>
#include <iomanip>
#include <sstream>

namespace bloodshot {
namespace {
namespace fs = std::filesystem;
constexpr uint64_t MAX_IMAGE = 1024ull * 1024 * 1024;
constexpr uint32_t MAX_SECTORS = 100 * 60 * 75, SAMPLES = 588;
std::string upper(std::string s) {
    for (auto &c : s) if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
    return s;
}
bool timecode(const std::string &text, uint32_t &frames) {
    if (text.size() != 8 || text[2] != ':' || text[5] != ':') return false;
    for (size_t i : {0u, 1u, 3u, 4u, 6u, 7u}) if (text[i] < '0' || text[i] > '9') return false;
    const unsigned m = (text[0] - '0') * 10 + text[1] - '0';
    const unsigned s = (text[3] - '0') * 10 + text[4] - '0';
    const unsigned f = (text[6] - '0') * 10 + text[7] - '0';
    if (s >= 60 || f >= 75) return false;
    frames = (m * 60 + s) * 75 + f;
    return true;
}
std::string timestamp(uint32_t frame) {
    std::ostringstream out;
    out << std::setfill('0') << std::setw(2) << frame / 4500 << ':'
        << std::setw(2) << frame / 75 % 60 << ':' << std::setw(2) << frame % 75;
    return out.str();
}
bool valid_utf8(const std::string &s) {
    for (size_t i = 0; i < s.size();) {
        const auto c = uint8_t(s[i++]);
        if (c < 0x80) continue;
        unsigned count = c >= 0xc2 && c <= 0xdf ? 1 : c >= 0xe0 && c <= 0xef ? 2 : c >= 0xf0 && c <= 0xf4 ? 3 : 0;
        if (!count || count > s.size() - i) return false;
        uint32_t code = c & ((1u << (6 - count)) - 1);
        for (unsigned j = 0; j < count; ++j) {
            const auto next = uint8_t(s[i++]);
            if ((next & 0xc0) != 0x80) return false;
            code = (code << 6) | (next & 63);
        }
        if (code < (count == 1 ? 0x80u : count == 2 ? 0x800u : 0x10000u) ||
            code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return false;
    }
    return true;
}
bool relative_name(std::string &name) {
    std::replace(name.begin(), name.end(), '\\', '/');
    if (!valid_utf8(name) || name.empty() || name[0] == '/' || name.find(':') != std::string::npos ||
        name.find('\0') != std::string::npos) return false;
    for (unsigned char c : name) if (c < 32) return false;
    for (const auto &part : fs::u8path(name)) if (part == "..") return false;
    return true;
}
} // namespace

bool CueImage::open(const std::string &path) {
    files.clear(); tracks.clear(); installed_cue.clear(); error.clear();
    auto fail = [&](const std::string &why) { error = why; return false; };
    std::error_code ec;
    const auto cue_path = fs::canonical(fs::u8path(path), ec);
    if (ec || !fs::is_regular_file(cue_path, ec) || fs::file_size(cue_path, ec) > 128 * 1024)
        return fail("Cannot read CUE, or CUE exceeds 128 KiB");
    const auto root = cue_path.parent_path();
    std::ifstream cue(cue_path, std::ios::binary);
    if (!cue) return fail("Cannot read CUE");
    int current_file = -1; uint64_t total = 0; unsigned line_number = 0;
    std::string line;
    while (std::getline(cue, line)) {
        if (++line_number > 4096 || !valid_utf8(line) || line.find('\0') != std::string::npos)
            return fail("CUE must be valid UTF-8 text with at most 4096 lines");
        if (line_number == 1 && line.compare(0, 3, "\xef\xbb\xbf") == 0) line.erase(0, 3);
        std::istringstream row(line); std::string command;
        if (!(row >> command)) continue;
        command = upper(command);
        if (command == "REM" || command == "TITLE" || command == "PERFORMER" ||
            command == "SONGWRITER" || command == "CATALOG" || command == "ISRC") continue;
        if (command == "FILE") {
            std::string name, type, extra;
            if (!(row >> std::quoted(name) >> type) || row >> extra || upper(type) != "BINARY")
                return fail("CUE FILE must name a BINARY file; WAVE/MP3 and other encodings are unsupported");
            if (!relative_name(name)) return fail("CUE FILE must be a safe relative path inside its folder");
            auto resolved = fs::canonical(root / fs::u8path(name), ec);
            if (ec || !fs::is_regular_file(resolved, ec)) return fail("A CUE binary file is missing or unreadable: " + name);
            auto relative = fs::relative(resolved, root, ec);
            if (ec || relative.empty() || *relative.begin() == "..")
                return fail("CUE binary symlink escapes the selected folder");
            current_file = -1;
            for (size_t i = 0; i < files.size(); ++i)
                if (files[i]->path == resolved.u8string()) current_file = int(i);
            if (current_file < 0) {
                if (files.size() >= 99) return fail("Too many CUE binary files");
                const auto length = fs::file_size(resolved, ec);
                if (ec || !length || length > MAX_IMAGE - total) return fail("CUE image exceeds bounded CD size");
                total += length;
                auto file = std::make_unique<CueFile>();
                file->path = resolved.u8string(); file->bytes = length;
                file->installed_name = "file-" + std::to_string(files.size() + 1) + ".bin";
                file->stream.open(resolved, std::ios::binary);
                if (!file->stream) return fail("Cannot read a CUE binary file");
                current_file = int(files.size()); files.push_back(std::move(file));
            }
        } else if (command == "TRACK") {
            unsigned number; std::string type, extra;
            if (!(row >> number >> type) || row >> extra || current_file < 0 ||
                number != tracks.size() + 1 || number > 99)
                return fail("CUE tracks must be numbered consecutively under a FILE");
            type = upper(type);
            const bool audio = type == "AUDIO";
            if ((number == 1 && type != "MODE1/2352" && type != "MODE1/2048") ||
                (number > 1 && !audio)) return fail("Expected Mode 1 data followed by binary AUDIO tracks");
            const uint32_t width = type == "MODE1/2048" ? 2048 : 2352;
            auto &file = *files[current_file];
            if ((file.sector_bytes && file.sector_bytes != width) || file.bytes % width)
                return fail("CUE binary length or mixed sector sizes are invalid");
            file.sector_bytes = width;
            if (number == 1) payload_offset = width == 2352 ? 16 : 0;
            CueTrack track; track.number = number; track.file = current_file; track.audio = audio;
            tracks.push_back(track);
        } else if (command == "INDEX" || command == "PREGAP" || command == "POSTGAP") {
            if (tracks.empty() || tracks.back().file != current_file) return fail("CUE index/gap has no current track");
            auto &track = tracks.back(); std::string text, extra; unsigned number = 0; uint32_t value;
            if ((command == "INDEX" && !(row >> number)) || !(row >> text) || row >> extra || !timecode(text, value))
                return fail("Invalid CUE index/gap time; expected MM:SS:FF");
            if (command == "INDEX") {
                if (number > 1 || (number == 0 && (track.index00 >= 0 || track.index01 >= 0)) ||
                    (number == 1 && track.index01 >= 0)) return fail("Unsupported, repeated or out-of-order CUE INDEX");
                (number == 0 ? track.index00 : track.index01) = value;
            } else {
                auto &gap = command == "PREGAP" ? track.pregap : track.postgap;
                auto &seen = command == "PREGAP" ? track.has_pregap : track.has_postgap;
                if (seen) return fail("Repeated CUE gap");
                seen = true; gap = value;
            }
        } else return fail("Unsupported CUE directive: " + command);
    }
    if (tracks.empty()) return fail("CUE has no tracks");
    uint64_t disc = 0;
    for (size_t i = 0; i < tracks.size(); ++i) {
        auto &track = tracks[i]; const auto &file = *files[track.file];
        uint64_t end = file.bytes / file.sector_bytes;
        if (i + 1 < tracks.size() && tracks[i + 1].file == track.file) {
            const auto &next = tracks[i + 1];
            if (next.index01 < 0) return fail("Every CUE track needs INDEX 01");
            end = next.index00 >= 0 ? next.index00 : next.index01;
        }
        if (track.index01 < 0 || uint64_t(track.index01) >= end || end > file.bytes / file.sector_bytes ||
            (track.index00 >= 0 && track.index00 > track.index01) ||
            (track.pregap && track.index00 >= 0)) return fail("CUE track indices/gaps overlap or exceed binary bounds");
        // A binary may be shared by adjacent tracks, but not revisited later.
        if (i && tracks[i - 1].file != track.file)
            for (size_t j = 0; j + 1 < i; ++j)
                if (tracks[j].file == track.file) return fail("CUE binary tracks must be contiguous");
        const uint32_t gap = track.pregap + (track.index00 >= 0 ? track.index01 - track.index00 : 0);
        track.frames = end - track.index01;
        // CUE may explicitly describe the first track's conventional lead-in;
        // the ISO data view and disc-relative TOC still start at LBA zero.
        track.disc_lba = i == 0 ? 0 : disc + gap;
        disc = track.disc_lba + track.frames + track.postgap;
        if (disc > MAX_SECTORS) return fail("CUE exceeds bounded CD duration");
        if (!i || tracks[i - 1].file != track.file)
            installed_cue += "FILE \"" + file.installed_name + "\" BINARY\n";
        installed_cue += "  TRACK " + std::to_string(track.number) + (track.audio ? " AUDIO\n" :
            (file.sector_bytes == 2352 ? " MODE1/2352\n" : " MODE1/2048\n"));
        if (track.pregap) installed_cue += "    PREGAP " + timestamp(track.pregap) + "\n";
        if (track.index00 >= 0) installed_cue += "    INDEX 00 " + timestamp(track.index00) + "\n";
        installed_cue += "    INDEX 01 " + timestamp(track.index01) + "\n";
        if (track.postgap) installed_cue += "    POSTGAP " + timestamp(track.postgap) + "\n";
    }
    for (const auto &file : files) if (!file->sector_bytes) return fail("Unused CUE FILE declaration");
    return true;
}

bool CueImage::bytes(int file, uint64_t offset, uint8_t *dst, size_t count) {
    auto &source = *files[file];
    if (offset > source.bytes || count > source.bytes - offset) { error = "Read outside CUE binary"; return false; }
    source.stream.clear(); source.stream.seekg(offset);
    if (!source.stream.read(reinterpret_cast<char *>(dst), count)) { error = "Cannot read CUE binary bytes"; return false; }
    return true;
}
bool CueImage::sector(uint64_t lba, uint8_t *dst) {
    if (tracks.empty() || lba >= tracks[0].frames) { error = "Read outside CUE data track"; return false; }
    const auto &track = tracks[0]; const auto &file = *files[track.file];
    return bytes(track.file, (track.index01 + lba) * file.sector_bytes + payload_offset, dst, 2048);
}
bool CueImage::audio_frames(int number, uint64_t frame, uint32_t count, uint8_t *dst) {
    if (number < 2 || number > int(tracks.size())) { error = "Invalid CUE audio track"; return false; }
    const auto &track = tracks[number - 1];
    if (frame > uint64_t(track.frames) * SAMPLES || count > uint64_t(track.frames) * SAMPLES - frame) {
        error = "Read outside CUE audio track"; return false;
    }
    if (!bytes(track.file, uint64_t(track.index01) * 2352 + frame * 4, dst, size_t(count) * 4)) return false;
    // BINARY CUE audio is little-endian; the shared CD playback view is big-endian.
    for (size_t i = 0; i < size_t(count) * 4; i += 2) std::swap(dst[i], dst[i + 1]);
    return true;
}
} // namespace bloodshot
