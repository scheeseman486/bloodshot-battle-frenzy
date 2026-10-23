#pragma once
#include "mw_chips.h"
#include <array>
#include <atomic>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback_resampled.hpp>
#include <memory>

namespace bloodshot {
// One main-thread producer and one audio-mixer consumer. Writes are applied at
// the next native mixer block; there is no speculative or render-frame queue.
struct FmState {
    struct Write {
        int port, reg, value;
    };
    static constexpr uint32_t CAPACITY = 2048;
    std::array<Write, CAPACITY> writes{};
    std::atomic<uint64_t> read{0}, written{0};
};
class BloodshotFmPlayback : public godot::AudioStreamPlaybackResampled {
    GDCLASS(BloodshotFmPlayback, godot::AudioStreamPlaybackResampled)
  public:
    BloodshotFmPlayback() { ++live_; }
    ~BloodshotFmPlayback() override { chips.unref(); state.reset(); --live_; }
    static uint64_t live_instances() { return live_.load(); }
    std::shared_ptr<FmState> state;
    godot::Ref<mw::MwChips> chips;
    void _start(double from) override;
    void _stop() override;
    bool _is_playing() const override;
    double _get_playback_position() const override;
    float _get_stream_sampling_rate() const override;
    int32_t _mix_resampled(godot::AudioFrame *dst, int32_t count) override;

  protected:
    static void _bind_methods() {}

  private:
    inline static std::atomic<uint64_t> live_{0};
    bool active_ = false;
    uint64_t frames_ = 0;
};
class BloodshotFmStream : public godot::AudioStream {
    GDCLASS(BloodshotFmStream, godot::AudioStream)
  public:
    bool write(int port, int reg, int value);
    godot::Ref<godot::AudioStreamPlayback> _instantiate_playback() const override;
    bool _is_monophonic() const override { return true; }

  protected:
    static void _bind_methods();

  private:
    std::shared_ptr<FmState> state_ = std::make_shared<FmState>();
};
} // namespace bloodshot
