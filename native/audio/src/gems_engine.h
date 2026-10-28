#pragma once
// Source-data sequencer for the verified European cartridge, not a CPU
// emulator. Fixed state/voice arrays keep generation bounded and
// allocation-free after init.
#include "sn76489.h"
#include "ymfm_opn.h"
#include <array>
#include <cstdint>
#include <memory>
#include <vector>
namespace bloodshot {
struct GemsRom {
  std::vector<uint8_t> bytes;
  int byte(int p) const {
    return p >= 0 && size_t(p) < bytes.size() ? bytes[p] : 0;
  }
  int le(int p) const { return byte(p) | (byte(p + 1) << 8); }
  int bank(int base, int i) const { return base + le(base + i * 2); }
};
class GemsEngine {
public:
  static constexpr double RATE = 53203424.0 / 7.0 / 144.0;
  static constexpr double TICK = 49.7014591857706;
  explicit GemsEngine(std::shared_ptr<const GemsRom> rom);
  bool start(int sequence);
  void sample(float &left, float &right);
  bool valid() const { return !error_; }
  bool sequenced() const;
  uint64_t ticks() const { return ticks_; }
#ifdef BLOODSHOT_GEMS_TEST_TRACE
  // Numeric register events only in the standalone original-trace harness.
  std::vector<std::array<int, 3>> register_trace;
#endif

private:
  struct Channel {
    int pc = 0, delay = 0, duration = 0, wait = 0, patch = 0, bend = 0,
        atten = 0, priority = 0;
    bool active = false, sfx = false;
    int depth = 0;
    std::array<int, 4> loop_pc{}, loop_count{};
  };
  struct Voice {
    int channel = -1, note = 0, left = 0, patch = 0, release = 0;
    bool sfx = false;
    int priority = 0;
  };
  struct PsgEnv {
    int mode = 0, level = 255, attack = 0, target = 0, sustain = 0, decay = 0,
        release = 0;
  };
  std::shared_ptr<const GemsRom> rom_;
  ymfm::ymfm_interface interface_;
  ymfm::ym2612 ym_;
  mw::Sn76489 psg_;
  std::array<Channel, 64> channels_{};
  std::array<Voice, 10> voices_{};
  std::array<PsgEnv, 4> env_{};
  int subbeat_ = 0, tempo_ = 284, psg_left_ = 5;
  double tick_phase_ = 0, dac_phase_ = 0, dac_rate_ = 0;
  int dac_pos_ = 0, dac_end_ = 0;
  float dac_value_ = 0;
  bool error_ = false;
  uint64_t ticks_ = 0;
  int get(Channel &c);
  void tick();
  void commands(int i);
  void note(int i, int n);
  void off(int v);
  void pitch(int v);
  void envelope();
  void chip_write(int port, int value);
  void write(int voice, int reg, int value);
};
} // namespace bloodshot
