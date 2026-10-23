#pragma once
// Read-only original media. A reader owns its CHD handle and two-hunk cache;
// separate readers are used by the asset loader and streaming audio worker.
#include "cue_image.h"
#include <cstdint>
#include <cstdio>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <libchdr/chd.h>
#include <memory>
#include <string>
#include <vector>

namespace bloodshot {
struct DiscTrack {
    int number = 0;
    uint64_t stored_sector = 0;
    uint32_t frames = 0, pregap = 0;
    uint64_t disc_lba = 0;
    bool audio = false;
    uint32_t playable_frames() const { return frames - pregap; }
};

class ChdReader {
  public:
    ~ChdReader();
    bool open(const std::string &path);
    godot::Dictionary image_description() const;
    bool read(uint64_t offset, uint8_t *dst, size_t bytes);
    bool sector(uint64_t lba, uint8_t *dst);
    bool audio_frames(int track, uint64_t frame, uint32_t count, uint8_t *dst);
    const DiscTrack *track(int number) const;
    std::vector<DiscTrack> tracks;
    std::string error, sha1;
    uint32_t hunk_bytes = 0, payload_offset = 16;
    uint64_t logical_bytes = 0, hunk_reads = 0;

  private:
    std::unique_ptr<CueImage> cue_;
    chd_file *handle_ = nullptr;
#if defined(_WIN32)
    // chd_open_file borrows this stream; close it after the CHD handle.
    std::unique_ptr<FILE, decltype(&std::fclose)> file_{nullptr, &std::fclose};
#endif
    std::vector<uint8_t> cache_[2];
    uint64_t cached_[2] = {UINT64_MAX, UINT64_MAX};
    int replacement_ = 0;
};

class BloodshotDisc : public godot::RefCounted {
    GDCLASS(BloodshotDisc, godot::RefCounted)
  public:
    bool open(const godot::String &path);
    godot::Dictionary catalog() const;
    godot::Dictionary inspect_image(const godot::String &path);
    godot::PackedByteArray read_file(const godot::String &name, int64_t offset = 0,
                                     int64_t count = -1);
    godot::PackedByteArray read_audio(int track, int64_t frame, int count);
    godot::String get_error() const;
    int64_t get_cache_bytes() const;
    int64_t get_hunk_reads() const;

  protected:
    static void _bind_methods();

  private:
    std::unique_ptr<ChdReader> reader_;
    godot::Dictionary catalog_;
    godot::String error_;
    uint32_t volume_sectors_ = 0;
    bool walk(uint32_t lba, uint32_t size, const std::string &prefix, int depth,
              std::vector<uint32_t> &visited);
    bool extent(uint32_t lba, uint32_t size, std::vector<uint8_t> &out);
};
} // namespace bloodshot
