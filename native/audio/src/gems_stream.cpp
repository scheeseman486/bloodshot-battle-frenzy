#include "gems_stream.h"
#include <algorithm>
#include <godot_cpp/core/class_db.hpp>
namespace bloodshot {
using namespace godot;
void BloodshotGemsPlayback::_start(double) {
  engine_ = std::make_unique<GemsEngine>(rom);
  engine_->start(sequence);
  if (bleeps)
    engine_->start(56);
  frames_ = 0;
  active_ = true;
  begin_resample();
}
int32_t BloodshotGemsPlayback::_mix_resampled(AudioFrame *dst, int32_t count) {
  if (!active_ || !engine_) {
    std::fill_n(dst, count, AudioFrame{});
    return 0;
  }
  for (int i = 0; i < count; i++)
    engine_->sample(dst[i].left, dst[i].right);
  frames_ += count;
  if (!engine_->valid())
    active_ = false;
  return count;
}
bool BloodshotGemsStream::configure(const PackedByteArray &data, int variant) {
  if (data.size() != 2097152 || variant < 1 || variant > 12)
    return false;
  auto rom = std::make_shared<GemsRom>();
  rom->bytes.assign(data.ptr(), data.ptr() + data.size());
  // Full media identity is checked by the runtime catalog before this adapter.
  if (rom->le(0x5e1bf) != 224 || rom->le(0x5cee4) != 256)
    return false;
  rom_ = std::move(rom);
  variant_ = variant;
  frontend_sequence_ = 0;
  return true;
}
bool BloodshotGemsStream::configure_frontend(const PackedByteArray &data,
                                             bool title) {
  if (!configure(data, 1))
    return false;
  frontend_sequence_ = title ? 50 : 60;
  return true;
}
PackedByteArray BloodshotGemsStream::render_effect(int sequence) const {
  PackedByteArray result;
  if (!rom_ || sequence < 0 || sequence > 49 || sequence == 34 ||
      sequence == 36 || sequence == 39)
    return result;
  GemsEngine engine(rom_);
  engine.start(sequence);
  const int maximum = int(GemsEngine::RATE * 12);
  result.resize(maximum * 2);
  auto dst = result.ptrw();
  int quiet = 0, tail = 0, i = 0;
  for (; i < maximum; i++) {
    float l, r;
    engine.sample(l, r);
    int value = std::clamp(int((l + r) * .5f * 32767), -32768, 32767);
    dst[i * 2] = value & 255;
    dst[i * 2 + 1] = (value >> 8) & 255;
    if (!engine.valid())
      return PackedByteArray();
    quiet = std::abs(value) < 3 ? quiet + 1 : 0;
    if (!engine.sequenced())
      ++tail;
    if (tail > int(GemsEngine::RATE * .2) &&
        quiet > int(GemsEngine::RATE * .15)) {
      ++i;
      break;
    }
  }
  if (i == maximum)
    return PackedByteArray();
  result.resize(i * 2);
  return result;
}
Ref<AudioStreamPlayback> BloodshotGemsStream::_instantiate_playback() const {
  if (!rom_)
    return Ref<AudioStreamPlayback>();
  Ref<BloodshotGemsPlayback> p;
  p.instantiate();
  p->rom = rom_;
  p->sequence = frontend_sequence_ ? frontend_sequence_ : 99 + variant_;
  p->bleeps = frontend_sequence_ == 0;
  return p;
}
void BloodshotGemsStream::_bind_methods() {
  ClassDB::bind_method(D_METHOD("configure_frontend", "rom", "title"),
                       &BloodshotGemsStream::configure_frontend);
  ClassDB::bind_method(D_METHOD("configure", "rom", "variant"),
                       &BloodshotGemsStream::configure);
  ClassDB::bind_method(D_METHOD("render_effect", "sequence"),
                       &BloodshotGemsStream::render_effect);
}
} // namespace bloodshot
