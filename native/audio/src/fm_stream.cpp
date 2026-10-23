#include "fm_stream.h"
#include <algorithm>
#include <godot_cpp/core/class_db.hpp>
namespace bloodshot {
using namespace godot;
namespace {
constexpr double RATE = 53203424.0 / 7.0 / 144.0;
}
void BloodshotFmPlayback::_start(double) {
    active_ = true;
    frames_ = 0;
    begin_resample();
}
void BloodshotFmPlayback::_stop() { active_ = false; }
bool BloodshotFmPlayback::_is_playing() const { return active_; }
double BloodshotFmPlayback::_get_playback_position() const { return double(frames_) / RATE; }
float BloodshotFmPlayback::_get_stream_sampling_rate() const { return float(RATE); }
int32_t BloodshotFmPlayback::_mix_resampled(AudioFrame *dst, int32_t count) {
    if (!active_) {
        std::fill_n(dst, count, AudioFrame{});
        return 0;
    }
    auto read = state->read.load(std::memory_order_relaxed);
    const auto written = state->written.load(std::memory_order_acquire);
    for (; read < written; ++read) {
        const auto &w = state->writes[read % FmState::CAPACITY];
        chips->ym_write(w.port, w.reg, w.value);
    }
    state->read.store(read, std::memory_order_release);
    // Keep mightyweenie's existing ymfm implementation unchanged. Only Godot's
    // output adapter is local; PCM effects never pass through this chip mixer.
    const auto samples = chips->render(count);
    for (int32_t i = 0; i < count; ++i)
        dst[i] = {samples[i].x, samples[i].y};
    frames_ += count;
    return count;
}
bool BloodshotFmStream::write(int port, int reg, int value) {
    const auto at = state_->written.load(std::memory_order_relaxed);
    if (at - state_->read.load(std::memory_order_acquire) == FmState::CAPACITY)
        return false;
    state_->writes[at % FmState::CAPACITY] = {port & 1, reg & 255, value & 255};
    state_->written.store(at + 1, std::memory_order_release);
    return true;
}
Ref<AudioStreamPlayback> BloodshotFmStream::_instantiate_playback() const {
    Ref<BloodshotFmPlayback> playback;
    playback.instantiate();
    playback->state = state_;
    playback->chips.instantiate();
    return playback;
}
void BloodshotFmStream::_bind_methods() {
    ClassDB::bind_method(D_METHOD("write", "port", "register", "value"), &BloodshotFmStream::write);
}
} // namespace bloodshot
