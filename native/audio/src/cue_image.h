#pragma once
// Read-only, bounded CUE/BINARY view. No console emulation or conversion tool.
#include <cstdint>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

namespace bloodshot {
struct CueFile {
    std::string path, installed_name;
    uint64_t bytes = 0;
    uint32_t sector_bytes = 0;
    std::ifstream stream;
};
struct CueTrack {
    int number = 0, file = -1;
    int64_t index00 = -1, index01 = -1;
    uint32_t pregap = 0, postgap = 0, frames = 0;
    uint64_t disc_lba = 0;
    bool audio = false, has_pregap = false, has_postgap = false;
};
class CueImage {
  public:
    bool open(const std::string &path);
    bool sector(uint64_t lba, uint8_t *dst);
    bool audio_frames(int number, uint64_t frame, uint32_t count, uint8_t *dst);
    std::vector<std::unique_ptr<CueFile>> files;
    std::vector<CueTrack> tracks;
    std::string error, installed_cue;
    uint32_t payload_offset = 16;
  private:
    bool bytes(int file, uint64_t offset, uint8_t *dst, size_t count);
};
} // namespace bloodshot
