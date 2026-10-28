#include "gems_engine.h"
#include <algorithm>
#include <cmath>
namespace bloodshot {
namespace {
constexpr int INST = 0x5cee4, SEQ = 0x5e1bf, SMP = 0x6037e;
constexpr int FM_ORDER[] = {0, 1, 3, 4, 5, 2};
} // namespace
GemsEngine::GemsEngine(std::shared_ptr<const GemsRom> rom)
    : rom_(std::move(rom)), ym_(interface_) {
  ym_.reset();
}
int GemsEngine::get(Channel &c) {
  if (c.pc < 0x5e42d || c.pc >= SMP) {
    error_ = true;
    c.active = false;
    return 96;
  }
  return rom_->byte(c.pc++);
}
bool GemsEngine::start(int sequence) {
  if (sequence < 0 || sequence >= 112)
    return false;
  int p = rom_->bank(SEQ, sequence), n = rom_->byte(p);
  if (n > 16)
    return false;
  for (int k = 0; k < n; k++) {
    auto it = std::find_if(channels_.begin(), channels_.end(),
                           [](const Channel &c) { return !c.active; });
    if (it == channels_.end()) {
      error_ = true;
      return false;
    }
    *it = Channel{};
    it->active = true;
    it->pc = SEQ + rom_->le(p + 1 + k * 2);
  }
  return true;
}
bool GemsEngine::sequenced() const {
  for (auto &c : channels_)
    if (c.active)
      return true;
  return false;
}
void GemsEngine::chip_write(int port, int value) {
#ifdef BLOODSHOT_GEMS_TEST_TRACE
  static thread_local int addresses[2] = {};
  if (!(port & 1))
    addresses[port / 2] = value;
  else
    register_trace.push_back(
        {int(ticks_), addresses[port / 2] + (port / 2) * 256, value});
#endif
  ym_.write(port, value);
}
void GemsEngine::write(int voice, int reg, int value) {
  int hw = FM_ORDER[voice];
  int port = hw / 3;
  chip_write(port * 2, reg + hw % 3);
  chip_write(port * 2 + 1, value);
}
void GemsEngine::pitch(int v) {
  auto &voice = voices_[v];
  if (voice.channel < 0)
    return;
  auto &c = channels_[voice.channel];
  int fixed = std::clamp(voice.note * 256 + c.bend, 0, 95 * 256 + 255),
      note = fixed >> 8, frac = fixed & 255;
  if (v < 6) {
    int p = rom_->bank(INST, voice.patch);
    if (rom_->byte(p + 2) & 64)
      return;
    // The source driver contains these frequency tables at Z80 $1168/$1182.
    int t = 0x5b65e + 0x1168 + (note % 12) * 2, a = rom_->le(t),
        b = rom_->le(t + 2);
    int f = a + ((b - a) * frac >> 8);
    f |= (note / 12) << 11;
    write(v, 0xa4, f >> 8);
    write(v, 0xa0, f & 255);
  } else {
    int n = std::max(0, note - 33);
    int t = 0x5b65e + 0x1182 + n * 2;
    int a = rom_->le(t), b = rom_->le(t + 2), f = a + ((b - a) * frac >> 8);
    int ch = v - 6;
    if (ch == 3) {
      int ctrl = rom_->byte(rom_->bank(INST, voice.patch) + 1);
      if ((ctrl & 3) != 3)
        return;
      ch = 2;
    }
    psg_.write(0x80 + ch * 32 + (f & 15));
    psg_.write((f >> 4) & 63);
  }
}
void GemsEngine::off(int v) {
  if (v < 6) {
    chip_write(0, 0x28);
    int hw = FM_ORDER[v];
    chip_write(1, hw < 3 ? hw : hw + 1);
  } else if (env_[v - 6].mode)
    env_[v - 6].mode = 4;
  voices_[v].left = 0;
  voices_[v].release = 254;
}
void GemsEngine::note(int ci, int n) {
  auto &c = channels_[ci];
  int p = rom_->bank(INST, c.patch), type = rom_->byte(p);
  if (type == 1) {
    int sample = n >= 48 ? n - 48 : n + 48;
    if (sample >= 25) {
      error_ = true;
      return;
    }
    int h = SMP + sample * 12, flags = rom_->byte(h), counter = flags & 15;
    if (rom_->byte(p + 1) != 4)
      counter = rom_->byte(p + 1);
    if (!counter || flags & 0x90) {
      error_ = true;
      return;
    }
    // Z80 $12F7/$17AD: DAC shares hardware channel 6 with ordinary FM.
    // Its fixed allocator can reject lower-priority samples, and normal FM
    // skips this entry while the original sample still owns the DAC.
    if (voices_[4].channel >= 0 && !voices_[4].release &&
        voices_[4].priority > c.priority)
      return;
    if (voices_[4].channel >= 0)
      off(4);
    voices_[4] = {ci, n, c.duration, c.patch, 0, c.sfx, c.priority};
    write(4, 0xb4, 0); // Software PCM replaces the hardware channel output.
    dac_pos_ =
        SMP + rom_->le(h + 1) + (rom_->byte(h + 3) << 16) + rom_->le(h + 4);
    dac_end_ = dac_pos_ + rom_->le(h + 6);
    dac_rate_ = 53203424.0 / 7 / 72 / counter / (counter >= 10 ? 2 : 1);
    dac_phase_ = 0;
    return;
  }
  if (type > 3) {
    error_ = true;
    return;
  }
  int begin = type == 0 ? 0 : type == 2 ? 6 : 9;
  // Z80 $1791..$17BB includes all six FM entries. Three-slot patches
  // use the fixed entry at $17B4; both routes respect voice priority.
  int end = type == 0 ? 6 : type == 2 ? 9 : 10;
  int v = -1;
  if (type == 0 && (rom_->byte(p + 2) & 64)) {
    v = 5;
    if (voices_[v].channel >= 0 && !voices_[v].release &&
        voices_[v].priority > c.priority)
      return;
  } else {
    // $17DE..$1840: reuse this sequence channel's released voice first;
    // otherwise take the oldest release, then the lowest-priority active
    // voice. Release age counts down, so a smaller value is older.
    int active = -1;
    for (int j = begin; j < end; ++j) {
      auto &voice = voices_[j];
      if (j == 4 && dac_pos_ < dac_end_)
        continue;
      if (voice.channel < 0 || voice.release) {
        if (voice.channel == ci) {
          v = j;
          break;
        }
        if (v < 0 || (voice.channel < 0 ? 0 : voice.release) <
                         (voices_[v].channel < 0 ? 0 : voices_[v].release))
          v = j;
      } else if (active < 0 || voice.priority < voices_[active].priority)
        active = j;
    }
    if (v < 0) {
      if (active < 0 || voices_[active].priority > c.priority)
        return;
      v = active;
    }
  }
  if (voices_[v].channel >= 0)
    off(v);
  voices_[v] = {ci, n, c.duration, c.patch, 0, c.sfx, c.priority};
  if (type == 0) {
    auto global = [&](int r, int value) {
      chip_write(0, r);
      chip_write(1, value);
    };
    if (rom_->byte(p + 1) & 8)
      global(0x22, rom_->byte(p + 1));
    int hw = FM_ORDER[v];
    if (hw == 2)
      global(0x27, rom_->byte(p + 2) | 5);
    write(v, 0xb0, rom_->byte(p + 3));
    write(v, 0xb4, rom_->byte(p + 4));
    const int carriers[] = {8, 8, 8, 8, 10, 14, 14, 15};
    int mask = carriers[rom_->byte(p + 3) & 7];
    for (int op = 0; op < 4; op++) {
      int offset = p + (op == 1   ? 17
                        : op == 2 ? 11
                                  : 5 + op * 6),
          slot = op == 1   ? 8
                 : op == 2 ? 4
                           : op * 4;
      for (int reg = 0; reg < 6; reg++) {
        int value = rom_->byte(offset + reg);
        if (reg == 1 && (mask & (1 << op))) {
          int level = 127 - value;
          value = 127 - (level - ((level * 2 * c.atten) >> 8));
        }
        write(v, 0x30 + reg * 16 + slot, value);
      }
      write(v, 0x90 + slot, 0);
    }
    if (rom_->byte(p + 2) & 64) {
      const int regs[] = {0xa6, 0xa2, 0xac, 0xa8, 0xad, 0xa9, 0xae, 0xaa};
      for (int k = 0; k < 8; k++)
        global(regs[k], rom_->byte(p + 29 + k));
    } else
      pitch(v);
    global(0x28, (rom_->byte(p + 37) << 4) | (hw < 3 ? hw : hw + 1));
  } else {
    pitch(v);
    int ch = v - 6;
    if (type == 3)
      psg_.write(0xe0 | rom_->byte(p + 1));
    env_[ch] = {1,
                255,
                rom_->byte(p + 2),
                (rom_->byte(p + 4) & 15) << 4,
                (rom_->byte(p + 3) & 15) << 4,
                rom_->byte(p + 5),
                rom_->byte(p + 6)};
  }
}
void GemsEngine::commands(int i) {
  auto &c = channels_[i];
  for (int budget = 0; budget < 512 && c.active; budget++) {
    int op = get(c);
    if (op >= 128) {
      int value = op & 63, group = op & 192;
      while ((rom_->byte(c.pc) & 192) == group)
        value = (value << 6) | (get(c) & 63);
      if (group == 192)
        c.delay = value;
      else
        c.duration = value;
      continue;
    }
    bool wait = true;
    if (op < 96)
      note(i, op);
    else
      switch (op) {
      case 96:
        c.active = false;
        return;
      case 97:
        c.patch = get(c);
        break;
      case 99:
        break;
      case 100:
        if (c.depth == 4) {
          error_ = true;
          return;
        }
        c.loop_count[c.depth] = get(c);
        c.loop_pc[c.depth] = c.pc;
        ++c.depth;
        wait = false;
        break;
      case 101: {
        if (!c.depth) {
          error_ = true;
          return;
        }
        int d = c.depth - 1;
        if (c.loop_count[d] != 127)
          --c.loop_count[d];
        if (c.loop_count[d])
          c.pc = c.loop_pc[d];
        else
          --c.depth;
        wait = false;
        break;
      }
      case 104:
        tempo_ = ((get(c) + 40) * 218) >> 7;
        break;
      case 106:
        c.priority = get(c);
        break;
      case 107: {
        int seq = get(c);
        if (!start(seq))
          error_ = true;
        break;
      }
      case 108: {
        int lo = get(c), hi = get(c);
        c.bend = int16_t(lo | (hi << 8));
        for (int v = 0; v < 10; v++)
          if (voices_[v].channel == i)
            pitch(v);
        break;
      }
      case 109:
        c.sfx = true;
        break;
      case 114: {
        int code = get(c), val = get(c);
        if (code == 5)
          c.atten = val;
        else if (code == 4) {
          for (auto &ch : channels_)
            ch.atten = val;
        } else
          error_ = true;
        break;
      }
      default:
        error_ = true;
        c.active = false;
        return;
      }
    if (wait && c.delay) {
      c.wait = c.delay;
      return;
    }
  }
  if (c.active)
    error_ = true;
}
void GemsEngine::envelope() {
  for (int i = 0; i < 4; i++) {
    auto &e = env_[i];
    if (e.mode == 1) {
      e.level -= e.attack;
      if (e.level <= e.target) {
        e.level = e.target;
        e.mode = 2;
      }
    } else if (e.mode == 2) {
      if (e.level < e.sustain)
        e.level = std::min(e.sustain, e.level + e.decay);
      else
        e.level = std::max(e.sustain, e.level - e.decay);
      if (e.level == e.sustain)
        e.mode = 3;
    } else if (e.mode == 4) {
      e.level += e.release;
      if (e.level > 255) {
        e.level = 255;
        e.mode = 0;
        voices_[6 + i].channel = -1;
      }
    }
    if (e.mode || e.level == 255)
      psg_.write(0x90 + i * 32 + (std::clamp(e.level, 0, 255) >> 4));
  }
}
void GemsEngine::tick() {
  ++ticks_;
  subbeat_ += tempo_;
  envelope();
  bool sfx = true;
  do {
    bool music = subbeat_ >= 256;
    if (music)
      subbeat_ -= 256;
    for (int v = 0; v < 10; v++) {
      auto &a = voices_[v];
      if (a.channel < 0)
        continue;
      if (a.release) {
        if (sfx && !--a.release)
          a.channel = -1;
        continue;
      }
      if (a.left > 0 && (a.sfx ? sfx : music) && !--a.left)
        off(v);
    }
    for (int i = 0; i < 64; i++) {
      auto &c = channels_[i];
      if (c.active && (c.sfx ? sfx : music)) {
        if (c.wait > 0)
          --c.wait;
        if (!c.wait)
          commands(i);
      }
    }
    sfx = false;
  } while (subbeat_ >= 256);
}
void GemsEngine::sample(float &left, float &right) {
  tick_phase_ += TICK;
  if (tick_phase_ >= RATE) {
    tick_phase_ -= RATE;
    tick();
  }
  ymfm::ym2612::output_data out;
  ym_.generate(&out);
  int span = 21;
  float psg = 0;
  while (span) {
    int n = std::min(span, psg_left_);
    psg += psg_.output() * n;
    span -= n;
    psg_left_ -= n;
    if (!psg_left_) {
      psg_.tick();
      psg_left_ = 5;
    }
  }
  dac_phase_ += dac_rate_;
  if (dac_phase_ >= RATE) {
    dac_phase_ -= RATE;
    if (dac_pos_ < dac_end_)
      dac_value_ = (rom_->byte(dac_pos_++) - 128) / 128.f * .066f;
    else {
      dac_value_ = 0;
      if (voices_[4].channel >= 0 && !voices_[4].release &&
          rom_->byte(rom_->bank(INST, voices_[4].patch)) == 1)
        off(4);
    }
  }
  constexpr float scale = .8f / 32768.f;
  float mono = psg * (.03365f / 21) + dac_value_;
  left = std::clamp((out.data[0] - 504) * scale + mono, -1.f, 1.f);
  right = std::clamp((out.data[1] - 504) * scale + mono, -1.f, 1.f);
}
} // namespace bloodshot
