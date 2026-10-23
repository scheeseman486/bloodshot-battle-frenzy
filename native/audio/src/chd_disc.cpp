#include "chd_disc.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <iomanip>
#include <sstream>
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace bloodshot {
using namespace godot;
namespace {
constexpr uint32_t kUnit = 2448, kData = 2048, kAudio = 2352, kFrames = 588;
constexpr uint32_t kMaxRead = 16 * 1024 * 1024;
#if defined(_WIN32)
FILE *open_utf8_readonly(const std::string &path) {
    // Godot paths are UTF-8; narrow fopen uses Windows' active ANSI codepage.
    // Keep byte-mode reads, converting the filename only, without changing
    // global codepages or any other file readers in the process.
    if (path.find('\0') != std::string::npos)
        return nullptr;
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         path.c_str(), -1, nullptr, 0);
    if (size <= 0)
        return nullptr;
    std::vector<wchar_t> wide(size);
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                            path.c_str(), -1, wide.data(), size))
        return nullptr;
    return _wfopen(wide.data(), L"rb");
}
#endif
uint32_t be32(const uint8_t *p) {
    return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
uint32_t le32(const uint8_t *p) {
    return uint32_t(p[3]) << 24 | uint32_t(p[2]) << 16 | uint32_t(p[1]) << 8 | p[0];
}
} // namespace
ChdReader::~ChdReader() {
    if (handle_)
        chd_close(handle_);
}
bool ChdReader::open(const std::string &path) {
    if (handle_) {
        chd_close(handle_);
        handle_ = nullptr;
    }
#if defined(_WIN32)
    file_.reset();
#endif
    cue_.reset();
    tracks.clear();
    error.clear();
    sha1.clear();
    cached_[0] = cached_[1] = UINT64_MAX;
    auto extension = path.size() >= 4 ? path.substr(path.size() - 4) : "";
    for (auto &c : extension) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (extension == ".cue") {
        cue_ = std::make_unique<CueImage>();
        if (!cue_->open(path)) { error = cue_->error; cue_.reset(); return false; }
        payload_offset = cue_->payload_offset;
        hunk_bytes = 0; logical_bytes = 0; hunk_reads = 0;
        for (auto &cache : cache_) { cache.clear(); cache.shrink_to_fit(); }
        for (const auto &t : cue_->tracks)
            tracks.push_back({t.number, uint64_t(t.index01), t.frames, 0, t.disc_lba, t.audio});
        return true;
    }
#if defined(_WIN32)
    file_.reset(open_utf8_readonly(path));
    if (!file_) {
        error = "Cannot open original disc read-only";
        return false;
    }
    const auto status = chd_open_file(file_.get(), CHD_OPEN_READ, nullptr, &handle_);
#else
    const auto status = chd_open(path.c_str(), CHD_OPEN_READ, nullptr, &handle_);
#endif
    if (status != CHDERR_NONE) {
#if defined(_WIN32)
        file_.reset();
#endif
        error = chd_error_string(status);
        return false;
    }
    const chd_header *header = chd_get_header(handle_);
    if (header->version != 5 || header->unitbytes != kUnit || header->hunkbytes < kUnit ||
        header->hunkbytes > 512 * 1024 || header->hunkbytes % kUnit != 0) {
        error = "Expected a standalone CD CHD v5 with 2448-byte units";
        return false;
    }
    for (uint8_t value : header->parentsha1)
        if (value) {
            error = "Parent CHDs are unsupported";
            return false;
        }
    logical_bytes = header->logicalbytes;
    hunk_bytes = header->hunkbytes;
    std::ostringstream digest;
    for (uint8_t value : header->sha1)
        digest << std::hex << std::setfill('0') << std::setw(2) << unsigned(value);
    sha1 = digest.str();
    for (auto &cache : cache_)
        cache.resize(hunk_bytes);
    uint64_t stored = 0, disc = 0;
    for (int index = 0; index < 99; ++index) {
        char metadata[1024] = {}, type[16] = {}, subtype[16] = {}, pgtype[16] = {}, pgsub[16] = {};
        unsigned number = 0, frames = 0, pregap = 0, postgap = 0;
        const auto result = chd_get_metadata(handle_, CHD_MAKE_TAG('C', 'H', 'T', '2'), index,
                                             metadata, sizeof(metadata), nullptr, nullptr, nullptr);
        if (result == CHDERR_METADATA_NOT_FOUND)
            break;
        if (result != CHDERR_NONE ||
            std::sscanf(metadata,
                        "TRACK:%u TYPE:%15s SUBTYPE:%15s FRAMES:%u PREGAP:%u PGTYPE:%15s "
                        "PGSUB:%15s POSTGAP:%u",
                        &number, type, subtype, &frames, &pregap, pgtype, pgsub, &postgap) != 8 ||
            number != unsigned(index + 1) || frames == 0) {
            error = "Invalid ordered CD track metadata";
            return false;
        }
        const bool audio = std::strcmp(type, "AUDIO") == 0;
        if ((index == 0 && std::strcmp(type, "MODE1_RAW") && std::strcmp(type, "MODE1")) ||
            (index > 0 && !audio) || std::strcmp(subtype, "NONE") || std::strcmp(pgsub, "NONE")) {
            error = "Unsupported CD track layout";
            return false;
        }
        if (index == 0) {
            payload_offset = std::strcmp(type, "MODE1") == 0 ? 0 : 16;
            if (pregap) {
                error = "Data-track pregap unsupported";
                return false;
            }
        }
        // CHD's V prefix means pregap sectors are physically stored in FRAMES.
        const uint32_t included_gap = pgtype[0] == 'V' ? pregap : 0;
        if (included_gap >= frames || (stored + frames) * kUnit > logical_bytes) {
            error = "Track outside CHD bounds";
            return false;
        }
        tracks.push_back(
            {int(number), stored + included_gap, frames, included_gap, disc + pregap, audio});
        disc += pregap + frames - included_gap + postgap;
        stored += (uint64_t(frames) + 3) / 4 * 4;
    }
    if (tracks.empty()) {
        error = "CHD has no data track";
        return false;
    }
    return true;
}
bool ChdReader::read(uint64_t offset, uint8_t *dst, size_t bytes) {
    if (!handle_ || offset > logical_bytes || bytes > logical_bytes - offset) {
        error = "Read outside CHD";
        return false;
    }
    while (bytes) {
        const uint64_t hunk = offset / hunk_bytes;
        const uint32_t inside = offset % hunk_bytes;
        int slot = cached_[0] == hunk ? 0 : cached_[1] == hunk ? 1 : -1;
        if (slot < 0) {
            slot = replacement_;
            replacement_ ^= 1;
            const auto result = chd_read(handle_, uint32_t(hunk), cache_[slot].data());
            if (result != CHDERR_NONE) {
                error = chd_error_string(result);
                return false;
            }
            cached_[slot] = hunk;
            ++hunk_reads;
        }
        const size_t take = std::min(bytes, size_t(hunk_bytes - inside));
        std::memcpy(dst, cache_[slot].data() + inside, take);
        dst += take;
        offset += take;
        bytes -= take;
    }
    return true;
}
bool ChdReader::sector(uint64_t lba, uint8_t *dst) {
    if (cue_) {
        const bool ok = cue_->sector(lba, dst);
        if (!ok) error = cue_->error;
        return ok;
    }
    if (tracks.empty() || lba >= tracks[0].frames) {
        error = "Read outside data track";
        return false;
    }
    return read(lba * kUnit + payload_offset, dst, kData);
}
const DiscTrack *ChdReader::track(int number) const {
    return number > 0 && number <= int(tracks.size()) ? &tracks[number - 1] : nullptr;
}
bool ChdReader::audio_frames(int number, uint64_t frame, uint32_t count, uint8_t *dst) {
    if (cue_) {
        const bool ok = cue_->audio_frames(number, frame, count, dst);
        if (!ok) error = cue_->error;
        return ok;
    }
    const auto *t = track(number);
    if (!t || !t->audio || frame > uint64_t(t->playable_frames()) * kFrames ||
        count > uint64_t(t->playable_frames()) * kFrames - frame) {
        error = "Read outside audio track";
        return false;
    }
    while (count) {
        const uint64_t sector = frame / kFrames;
        const uint32_t inside = frame % kFrames, take = std::min(count, kFrames - inside);
        if (!read((t->stored_sector + sector) * kUnit + inside * 4, dst, take * 4))
            return false;
        frame += take;
        dst += take * 4;
        count -= take;
    }
    return true;
}

Dictionary ChdReader::image_description() const {
    Dictionary result;
    result["format"] = cue_ ? "cue" : "chd";
    Array files;
    if (cue_) {
        for (const auto &file : cue_->files) {
            Dictionary row;
            row["path"] = String::utf8(file->path.c_str());
            row["installed_name"] = file->installed_name.c_str();
            row["size"] = int64_t(file->bytes);
            files.append(row);
        }
        result["cue_text"] = String::utf8(cue_->installed_cue.c_str());
    }
    result["image_files"] = files;
    return result;
}
Dictionary BloodshotDisc::inspect_image(const String &path) {
    ChdReader reader;
    error_ = "";
    if (!reader.open(path.utf8().get_data())) { error_ = String::utf8(reader.error.c_str()); return {}; }
    return reader.image_description();
}

bool BloodshotDisc::open(const String &path) {
    reader_ = std::make_unique<ChdReader>();
    catalog_.clear();
    error_ = "";
    if (!reader_->open(path.utf8().get_data())) {
        error_ = String::utf8(reader_->error.c_str());
        return false;
    }
    std::vector<uint8_t> pvd(kData);
    if (!reader_->sector(16, pvd.data()) ||
        std::memcmp(pvd.data(),
                    "\x01"
                    "CD001\x01",
                    7) ||
        pvd[128] != 0 || pvd[129] != 8 || pvd[130] != 8 || pvd[131] != 0) {
        error_ = "Unsupported ISO9660 descriptor";
        return false;
    }
    volume_sectors_ = le32(&pvd[80]);
    if (volume_sectors_ != be32(&pvd[84]) || volume_sectors_ > reader_->tracks[0].frames ||
        le32(&pvd[158]) != be32(&pvd[162]) || le32(&pvd[166]) != be32(&pvd[170])) {
        error_ = "Invalid ISO extent";
        return false;
    }
    catalog_["files"] = Array();
    std::vector<uint32_t> visited;
    if (!walk(le32(&pvd[158]), le32(&pvd[166]), "", 0, visited)) {
        catalog_.clear();
        return false;
    }
    const Dictionary description = reader_->image_description();
    catalog_.merge(description);
    catalog_["ok"] = true;
    catalog_["chd_sha1"] = reader_->sha1.c_str();
    catalog_["volume"] = String::utf8(reinterpret_cast<const char *>(&pvd[40]), 32).strip_edges();
    catalog_["track"] = String("TRACK:1 TYPE:") +
                        (reader_->payload_offset ? "MODE1_RAW" : "MODE1") +
                        " SUBTYPE:NONE FRAMES:" + String::num_int64(reader_->tracks[0].frames) +
                        " PREGAP:0 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0";
    Array tracks;
    for (const auto &t : reader_->tracks) {
        Dictionary d;
        d["number"] = t.number;
        d["audio"] = t.audio;
        d["frames"] = t.playable_frames();
        d["sample_frames"] = int64_t(t.playable_frames()) * kFrames;
        d["stored_sector"] = int64_t(t.stored_sector);
        d["disc_lba"] = int64_t(t.disc_lba);
        tracks.append(d);
    }
    catalog_["tracks"] = tracks;
    return true;
}
bool BloodshotDisc::extent(uint32_t lba, uint32_t size, std::vector<uint8_t> &out) {
    if (size > kMaxRead || uint64_t(lba) + (uint64_t(size) + kData - 1) / kData > volume_sectors_) {
        error_ = "Invalid ISO range";
        return false;
    }
    out.resize(size);
    uint8_t block[kData];
    for (uint32_t at = 0; at < size; at += kData) {
        if (!reader_->sector(lba + at / kData, block)) {
            error_ = String::utf8(reader_->error.c_str());
            return false;
        }
        std::memcpy(out.data() + at, block, std::min(kData, size - at));
    }
    return true;
}
bool BloodshotDisc::walk(uint32_t lba, uint32_t size, const std::string &prefix, int depth,
                         std::vector<uint32_t> &visited) {
    if (depth > 16 || std::find(visited.begin(), visited.end(), lba) != visited.end()) {
        error_ = "Cyclic ISO directory";
        return false;
    }
    visited.push_back(lba);
    std::vector<uint8_t> bytes;
    if (!extent(lba, size, bytes))
        return false;
    Array files = catalog_["files"];
    for (size_t at = 0; at < bytes.size();) {
        const uint8_t length = bytes[at];
        if (!length) {
            at = (at / kData + 1) * kData;
            continue;
        }
        if (length < 34 || at + length > bytes.size() || at % kData + length > kData) {
            error_ = "Truncated ISO record";
            return false;
        }
        const uint8_t *r = &bytes[at];
        at += length;
        if (r[32] == 1 && (r[33] == 0 || r[33] == 1))
            continue;
        if (33 + r[32] > length || r[1] || r[26] || r[27] || (r[25] & 0x80) ||
            le32(r + 2) != be32(r + 6) || le32(r + 10) != be32(r + 14)) {
            error_ = "Unsupported ISO record";
            return false;
        }
        std::string name(reinterpret_cast<const char *>(r + 33), r[32]);
        name = name.substr(0, name.find(';'));
        if (name.empty() || name == "." || name == ".." ||
            name.find_first_of("/\\") != std::string::npos ||
            name.find('\0') != std::string::npos) {
            error_ = "Unsafe ISO name";
            return false;
        }
        const auto path = prefix + "/" + name;
        const uint32_t start = le32(r + 2), count = le32(r + 10);
        if (uint64_t(start) + (uint64_t(count) + kData - 1) / kData > volume_sectors_) {
            error_ = "File outside ISO volume";
            return false;
        }
        if (r[25] & 2) {
            if (!walk(start, count, path, depth + 1, visited))
                return false;
        } else {
            if (files.size() >= 10000) {
                error_ = "Too many ISO files";
                return false;
            }
            for (int i = 0; i < files.size(); ++i)
                if (String(Dictionary(files[i])["path"]) == String(path.c_str())) {
                    error_ = "Duplicate ISO name";
                    return false;
                }
            Dictionary d;
            d["path"] = path.c_str();
            d["lba"] = start;
            d["size"] = count;
            files.append(d);
        }
    }
    return true;
}
Dictionary BloodshotDisc::catalog() const { return catalog_.duplicate(true); }
PackedByteArray BloodshotDisc::read_file(const String &name, int64_t offset, int64_t count) {
    PackedByteArray result;
    error_ = "";
    if (!reader_ || catalog_.is_empty() || offset < 0 || count < -1) {
        error_ = "No mounted disc or invalid byte range";
        return result;
    }
    Array files = catalog_["files"];
    for (int i = 0; i < files.size(); ++i) {
        Dictionary file = files[i];
        if (String(file["path"]) != name)
            continue;
        const int64_t size = file["size"], lba = file["lba"];
        if (count == -1)
            count = size - offset;
        if (offset > size || count < 0 || count > size - offset || count > kMaxRead) {
            error_ = "Read outside file bounds";
            return result;
        }
        std::vector<uint8_t> data;
        const uint32_t inside = offset % kData;
        if (!extent(uint32_t(lba + offset / kData), uint32_t(inside + count), data))
            return result;
        result.resize(count);
        if (count)
            std::memcpy(result.ptrw(), data.data() + inside, count);
        return result;
    }
    error_ = "ISO file not found";
    return result;
}
PackedByteArray BloodshotDisc::read_audio(int track, int64_t frame, int count) {
    PackedByteArray result;
    error_ = "";
    if (!reader_ || frame < 0 || count < 0 || count > 44100) {
        error_ = "Invalid bounded audio read";
        return result;
    }
    result.resize(int64_t(count) * 4);
    if (!reader_->audio_frames(track, frame, count, result.ptrw())) {
        error_ = String::utf8(reader_->error.c_str());
        result.clear();
    }
    return result; // Shared big-endian signed 16-bit stereo view for CHD and CUE/BIN.
}
String BloodshotDisc::get_error() const { return error_; }
int64_t BloodshotDisc::get_cache_bytes() const {
    return reader_ ? int64_t(reader_->hunk_bytes) * 2 : 0;
}
int64_t BloodshotDisc::get_hunk_reads() const { return reader_ ? reader_->hunk_reads : 0; }
void BloodshotDisc::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open", "path"), &BloodshotDisc::open);
    ClassDB::bind_method(D_METHOD("catalog"), &BloodshotDisc::catalog);
    ClassDB::bind_method(D_METHOD("inspect_image", "path"), &BloodshotDisc::inspect_image);
    ClassDB::bind_method(D_METHOD("read_file", "name", "offset", "count"),
                         &BloodshotDisc::read_file, DEFVAL(0), DEFVAL(-1));
    ClassDB::bind_method(D_METHOD("read_audio", "track", "frame", "count"),
                         &BloodshotDisc::read_audio);
    ClassDB::bind_method(D_METHOD("get_error"), &BloodshotDisc::get_error);
    ClassDB::bind_method(D_METHOD("get_cache_bytes"), &BloodshotDisc::get_cache_bytes);
    ClassDB::bind_method(D_METHOD("get_hunk_reads"), &BloodshotDisc::get_hunk_reads);
}
} // namespace bloodshot
