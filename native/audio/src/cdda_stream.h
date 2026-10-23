#pragma once
#include "chd_disc.h"
#include <array>
#include <atomic>
#include <condition_variable>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback_resampled.hpp>
#include <mutex>
#include <thread>

namespace bloodshot {
// Disc I/O/decompression happens on a private producer. Godot's mixer only
// consumes a bounded PCM ring and uses its own resampling/output machinery.
class BloodshotCddaPlayback : public godot::AudioStreamPlaybackResampled {
    GDCLASS(BloodshotCddaPlayback, godot::AudioStreamPlaybackResampled)
  public:
    BloodshotCddaPlayback();
    ~BloodshotCddaPlayback() override;
    static uint64_t live_instances() { return live_.load(); }
    bool initialize(const godot::String &path, int track, bool loop);
    void _start(double from_pos) override;
    void _stop() override;
    bool _is_playing() const override;
    int32_t _get_loop_count() const override;
    double _get_playback_position() const override;
    void _seek(double position) override;
    float _get_stream_sampling_rate() const override;
    int32_t _mix_resampled(godot::AudioFrame *dst, int32_t frames) override;
    int64_t buffered_frames() const;
    int64_t underruns() const;
    int64_t worker_wakes() const;
    godot::String get_error() const;

  protected:
    static void _bind_methods();

  private:
    inline static std::atomic<uint64_t> live_{0};
    static constexpr uint32_t CAPACITY = 16384, CHUNK = 2048;
    std::unique_ptr<ChdReader> reader_;
    std::array<godot::AudioFrame, CAPACITY> ring_{};
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::thread producer_;
    std::atomic<bool> active_{false};
    std::atomic<uint64_t> position_{0}, underruns_{0}, worker_wakes_{0};
    uint64_t total_ = 0, next_ = 0, generation_ = 0;
    std::atomic<uint64_t> read_{0}, write_{0};
    bool loop_ = false, quit_ = false;
    std::atomic<bool> eof_{false};
    int track_ = 0;
    std::string error_;
    void produce();
    bool decode(uint64_t from, uint32_t count, godot::AudioFrame *dst);
};

class BloodshotCddaStream : public godot::AudioStream {
    GDCLASS(BloodshotCddaStream, godot::AudioStream)
  public:
    bool configure(const godot::String &path, int track, bool loop = true);
    godot::Ref<godot::AudioStreamPlayback> _instantiate_playback() const override;
    godot::String _get_stream_name() const override;
    double _get_length() const override;
    bool _is_monophonic() const override;
    bool _has_loop() const override;
    godot::String get_error() const;

  protected:
    static void _bind_methods();

  private:
    godot::String path_, error_;
    int track_ = 0;
    bool loop_ = false;
    uint64_t frames_ = 0;
};
} // namespace bloodshot
