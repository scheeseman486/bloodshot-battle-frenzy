#include "cdda_stream.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <godot_cpp/core/class_db.hpp>

namespace bloodshot {
using namespace godot;
namespace {
float sample(const uint8_t *p) {
    const auto value = int16_t(uint16_t(p[0]) << 8 | p[1]);
    return float(value) / 32768.0f;
}
} // namespace
bool BloodshotCddaPlayback::decode(uint64_t from, uint32_t count, AudioFrame *dst) {
    std::array<uint8_t, CHUNK * 4> raw;
    if (!reader_->audio_frames(track_, from, count, raw.data()))
        return false;
    for (uint32_t i = 0; i < count; ++i) {
        dst[i].left = sample(raw.data() + i * 4);
        dst[i].right = sample(raw.data() + i * 4 + 2);
    }
    return true;
}
bool BloodshotCddaPlayback::initialize(const String &path, int track, bool loop) {
    reader_ = std::make_unique<ChdReader>();
    if (!reader_->open(path.utf8().get_data())) {
        error_ = reader_->error;
        return false;
    }
    const auto *t = reader_->track(track);
    if (!t || !t->audio) {
        error_ = "Requested track is not CD audio";
        return false;
    }
    track_ = track;
    loop_ = loop;
    total_ = uint64_t(t->playable_frames()) * 588;
    // Startup prefetch runs before playback is handed to Godot's audio mixer.
    const uint32_t preload = uint32_t(std::min<uint64_t>(CHUNK * 2, total_));
    for (uint32_t at = 0; at < preload; at += CHUNK) {
        const auto count = std::min(CHUNK, preload - at);
        if (!decode(at, count, ring_.data() + at)) {
            error_ = reader_->error;
            return false;
        }
    }
    write_.store(preload, std::memory_order_release);
    next_ = preload;
    producer_ = std::thread(&BloodshotCddaPlayback::produce, this);
    return true;
}
BloodshotCddaPlayback::BloodshotCddaPlayback() { ++live_; }
BloodshotCddaPlayback::~BloodshotCddaPlayback() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        quit_ = true;
    }
    wake_.notify_one();
    if (producer_.joinable())
        producer_.join();
    reader_.reset();
    --live_;
}
void BloodshotCddaPlayback::_start(double from_pos) {
    if (total_ == 0)
        return;
    // Preserve initial prefetched samples for the common play-from-zero path.
    if (from_pos != 0.0 || position_.load() != 0)
        _seek(from_pos);
    {
        // Pair the inactive-worker predicate with its wait mutex so a start
        // cannot be lost between checking that predicate and going to sleep.
        std::lock_guard<std::mutex> lock(mutex_);
        active_.store(true);
    }
    wake_.notify_one();
    begin_resample();
}
void BloodshotCddaPlayback::_stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        active_.store(false);
    }
    wake_.notify_one();
}
bool BloodshotCddaPlayback::_is_playing() const { return active_.load(); }
int32_t BloodshotCddaPlayback::_get_loop_count() const {
    return loop_ && total_ ? int32_t(position_.load() / total_) : 0;
}
double BloodshotCddaPlayback::_get_playback_position() const {
    auto at = position_.load();
    if (loop_ && total_)
        at %= total_;
    return double(at) / 44100.0;
}
void BloodshotCddaPlayback::_seek(double seconds) {
    if (total_ == 0 || !std::isfinite(seconds))
        return;
    auto frame = uint64_t(std::max(0.0, std::min(seconds * 44100.0, double(total_))));
    if (loop_ && frame == total_)
        frame = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ++generation_;
        read_.store(write_.load(std::memory_order_acquire), std::memory_order_release);
        next_ = frame;
        position_.store(frame);
        eof_ = false;
    }
    wake_.notify_one();
    begin_resample();
}
float BloodshotCddaPlayback::_get_stream_sampling_rate() const { return 44100.0f; }
int32_t BloodshotCddaPlayback::_mix_resampled(AudioFrame *dst, int32_t frames) {
    if (frames <= 0)
        return 0;
    // Single-producer/single-consumer ring: the mixer never takes a worker
    // lock, allocates, reads media or decompresses CHD hunks.
    if (!active_.load()) {
        std::fill_n(dst, frames, AudioFrame{});
        return 0;
    }
    auto read = read_.load(std::memory_order_relaxed);
    const auto written = write_.load(std::memory_order_acquire);
    const uint32_t count = uint32_t(std::min(uint64_t(frames), written - read));
    for (uint32_t i = 0; i < count; ++i) {
        dst[i] = ring_[(read + i) % CAPACITY];
    }
    read_.store(read + count, std::memory_order_release);
    position_.fetch_add(count);
    std::fill_n(dst + count, frames - count, AudioFrame{});
    const bool ended = eof_.load() && read + count == write_.load(std::memory_order_acquire);
    if (ended)
        active_.store(false);
    else if (count < uint32_t(frames))
        ++underruns_;
    wake_.notify_one();
    return ended ? int32_t(count) : frames;
}
void BloodshotCddaPlayback::produce() {
    std::array<AudioFrame, CHUNK> samples;
    while (true) {
        uint64_t from, generation, write;
        uint32_t count;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            // No playback can consume data while stopped or after EOF. Sleep
            // until start/seek/destruction instead of polling those states.
            wake_.wait(lock, [&] { return quit_ || (active_.load() && !eof_); });
            // The lock-free mixer notifies after consuming a block. Retain a
            // bounded fallback for a notification racing the predicate/wait;
            // 20 ms is well below the 372 ms ring capacity at native CD rate.
            // A paused/full ring no longer wakes every two milliseconds.
            wake_.wait_for(lock, std::chrono::milliseconds(20), [&] {
                return quit_ || !active_.load() || eof_ ||
                       CAPACITY - (write_.load(std::memory_order_relaxed) -
                                   read_.load(std::memory_order_acquire)) >= CHUNK;
            });
            ++worker_wakes_;
            if (quit_)
                return;
            if (!active_.load() || eof_.load() || write_.load() - read_.load() > CAPACITY - CHUNK)
                continue;
            if (next_ == total_) {
                if (loop_)
                    next_ = 0;
                else {
                    eof_ = true;
                    continue;
                }
            }
            write = write_.load(std::memory_order_relaxed);
            from = next_;
            generation = generation_;
            count = uint32_t(std::min<uint64_t>(CHUNK, total_ - next_));
        }
        const bool ok = decode(from, count, samples.data());
        // Only this producer writes unpublished slots. A seek flushes the
        // published range; generation validation below discards a stale decode.
        if (ok)
            for (uint32_t i = 0; i < count; ++i)
                ring_[(write + i) % CAPACITY] = samples[i];
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation != generation_)
                continue; // A seek discarded this decoded block.
            if (!ok) {
                error_ = reader_->error;
                eof_ = true;
                continue;
            }
            write_.store(write + count, std::memory_order_release);
            next_ += count;
        }
    }
}
int64_t BloodshotCddaPlayback::buffered_frames() const {
    const auto read = read_.load(std::memory_order_acquire);
    return write_.load(std::memory_order_acquire) - read;
}
int64_t BloodshotCddaPlayback::underruns() const { return underruns_.load(); }
int64_t BloodshotCddaPlayback::worker_wakes() const { return worker_wakes_.load(); }
String BloodshotCddaPlayback::get_error() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return error_.c_str();
}
void BloodshotCddaPlayback::_bind_methods() {
    ClassDB::bind_method(D_METHOD("buffered_frames"), &BloodshotCddaPlayback::buffered_frames);
    ClassDB::bind_method(D_METHOD("underruns"), &BloodshotCddaPlayback::underruns);
    ClassDB::bind_method(D_METHOD("worker_wakes"), &BloodshotCddaPlayback::worker_wakes);
    ClassDB::bind_method(D_METHOD("get_error"), &BloodshotCddaPlayback::get_error);
}
bool BloodshotCddaStream::configure(const String &path, int track, bool loop) {
    ChdReader reader;
    error_ = "";
    frames_ = 0;
    if (!reader.open(path.utf8().get_data())) {
        error_ = reader.error.c_str();
        return false;
    }
    const auto *t = reader.track(track);
    if (!t || !t->audio) {
        error_ = "Requested track is not CD audio";
        return false;
    }
    path_ = path;
    track_ = track;
    loop_ = loop;
    frames_ = uint64_t(t->playable_frames()) * 588;
    return true;
}
Ref<AudioStreamPlayback> BloodshotCddaStream::_instantiate_playback() const {
    if (frames_ == 0)
        return {};
    Ref<BloodshotCddaPlayback> playback;
    playback.instantiate();
    if (!playback->initialize(path_, track_, loop_))
        return {};
    return playback;
}
String BloodshotCddaStream::_get_stream_name() const {
    return "Original CD track " + String::num_int64(track_);
}
double BloodshotCddaStream::_get_length() const { return double(frames_) / 44100.0; }
bool BloodshotCddaStream::_is_monophonic() const { return true; }
bool BloodshotCddaStream::_has_loop() const { return loop_; }
String BloodshotCddaStream::get_error() const { return error_; }
void BloodshotCddaStream::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "path", "track", "loop"),
                         &BloodshotCddaStream::configure, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("get_error"), &BloodshotCddaStream::get_error);
}
} // namespace bloodshot
