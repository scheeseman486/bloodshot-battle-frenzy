// mightyweenie - audio GDExtension (native/mw_audio).
// Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
// (see LICENSE).
//
// PcmMixer: the PCM samples the original's Z80 mixes into the YM2612's DAC,
// played natively instead (plan 12; docs/re/sound.md). The Z80 outputs one
// 8-bit value per loop pass (11 048 Hz raw, 10 930 Hz DPCM) and the DAC holds
// it until the next one (a zero-order hold: the gritty images around
// multiples of the rate). Here each voice is resampled to the mix rate with a
// windowed-sinc (Lanczos, 8 taps) kernel, so the samples sound as recorded.
//
// Voices are started, stopped and re-pitched by the game's port of the Z80
// (MwSoundZ80) on the tick the original does it; the data comes from the ROM
// (MwSoundSamples.decode: unsigned 8-bit, $80 = silence). Mixed as a sum
// without the original's hard clip (and without its 4-voice carry bug).
//
// Voices 0-3 are the Z80's four channels. Voices 4-15 are extra voices for
// the audio service's enhancement switches (MwAudio.free_music_samples,
// free_effects): sounds the original cuts short or refuses for want of a
// channel or a bank play on there - detach() moves a channel's voice to one,
// start_extra() starts one; when all are busy the oldest is taken.
#pragma once

#include <cstdint>
#include <vector>

namespace mw {

class PcmMixer {
public:
	static constexpr int VOICES = 4;    // the Z80's channels
	static constexpr int EXTRA = 12;    // extra voices (ids VOICES..TOTAL-1)
	static constexpr int TOTAL = VOICES + EXTRA;
	static constexpr int TAPS = 8;      // Lanczos a = 4
	static constexpr int PHASES = 512;  // kernel table resolution

	PcmMixer();

	// Sample `id`: unsigned 8-bit values, played at `rate` Hz for step $100;
	// `loop_start` = index the voice restarts at after the last value
	// (-1: the sample ends there).
	void load(int id, const uint8_t *data, int64_t size, double rate, int64_t loop_start);
	// Channel `ch` (0-3) plays sample `id`.
	void start(int ch, int id, int64_t from_index);
	// Voice `v` (0-15) stops at once; all voices stop.
	void stop(int v);
	void stop_all();
	// 8.8 step: $100 = the sample's own rate (any voice).
	void set_step(int v, int step);
	// $80 = unity (linear; any voice).
	void set_volume(int v, int volume);
	bool active(int v) const;
	// The sample voice `v` plays, or -1 when it is silent.
	int sample_of(int v) const;
	// Channel `ch`'s voice (position, step, volume) moves on to an extra
	// voice and the channel falls silent. The extra voice's id, or -1 when
	// the channel was silent.
	int detach(int ch);
	// Sample `id` on an extra voice from its start. The voice's id, or -1.
	int start_extra(int id, int step, int volume);
	// Voice `v` fades to silence over `frames` output samples, then stops.
	void fade(int v, int frames);
	// Output sample rate (the YM2612's) and the level of a full-scale value.
	void configure(double out_rate, double gain);
	// One output sample (mono).
	float next();

private:
	struct Sample {
		std::vector<float> data;  // (s - $80) / $80
		double rate = 0.0;
		int64_t loop_start = -1;
	};
	struct Voice {
		int id = -1;
		double pos = 0.0;
		double inc = 0.0;
		int step = 0x100;
		float gain = 0.0f;
		int volume = 0x80;
		bool active = false;
		uint32_t serial = 0;      // start order (the oldest extra is taken first)
		int fade_left = -1;       // output samples of the fade left (-1: none)
		float fade_gain = 1.0f;
		float fade_step = 0.0f;
	};

	float tap(const Sample &s, int64_t i) const;
	void update(Voice &v);
	int free_extra();

	std::vector<Sample> samples_;
	Voice voices_[TOTAL];
	uint32_t serial_ = 0;
	float kernel_[PHASES + 1][TAPS];
	double out_rate_ = 53267.0;
	double gain_ = 0.13;
};

} // namespace mw
