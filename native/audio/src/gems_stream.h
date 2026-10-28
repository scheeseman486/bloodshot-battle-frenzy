#pragma once
#include "gems_engine.h"
#include <atomic>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback_resampled.hpp>
namespace bloodshot {
class BloodshotGemsPlayback : public godot::AudioStreamPlaybackResampled {
  GDCLASS(BloodshotGemsPlayback, godot::AudioStreamPlaybackResampled)
public:
  BloodshotGemsPlayback() { ++live_; }
  ~BloodshotGemsPlayback() override {
    engine_.reset();
    --live_;
  }
  static uint64_t live_instances() { return live_.load(); }
  std::shared_ptr<const GemsRom> rom;
  int sequence = 100;
  bool bleeps = true;
  void _start(double) override;
  void _stop() override { active_ = false; }
  bool _is_playing() const override { return active_; }
  double _get_playback_position() const override {
    return frames_ / GemsEngine::RATE;
  }
  float _get_stream_sampling_rate() const override { return GemsEngine::RATE; }
  int32_t _mix_resampled(godot::AudioFrame *, int32_t) override;

protected:
  static void _bind_methods() {}

private:
  inline static std::atomic<uint64_t> live_{0};
  std::unique_ptr<GemsEngine> engine_;
  bool active_ = false;
  uint64_t frames_ = 0;
};
class BloodshotGemsStream : public godot::AudioStream {
  GDCLASS(BloodshotGemsStream, godot::AudioStream)
public:
  bool configure(const godot::PackedByteArray &, int variant);
  bool configure_frontend(const godot::PackedByteArray &, bool title);
  godot::PackedByteArray render_effect(int sequence) const;
  godot::Ref<godot::AudioStreamPlayback> _instantiate_playback() const override;
  bool _is_monophonic() const override { return true; }

protected:
  static void _bind_methods();

private:
  std::shared_ptr<const GemsRom> rom_;
  int variant_ = 1;
  int frontend_sequence_ = 0;
};
} // namespace bloodshot
