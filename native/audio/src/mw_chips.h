// mightyweenie - audio GDExtension (native/mw_audio).
// Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
// (see LICENSE). Links ymfm (BSD-3-Clause,
// Aaron Giles) and godot-cpp (MIT); notices in
// game/addons/mw_audio/THIRD_PARTY_NOTICES.txt.
//
// MwChips: the Genesis' two sound chips as one Godot object (RefCounted).
//
//   * YM2612 (Model 1 OPN2): ymfm::ym2612 at 7 670 453 Hz (the master clock
//     53 693 175 Hz / 7). One output sample per 144 chip clocks:
//     sample_rate() = 7 670 453 / 144 = 53 267.03 Hz - the rate render()
//     produces.
//   * PSG: our Sn76489 at 3 579 545 Hz (master / 15). Its counters step every
//     16 of its clocks, i.e. exactly 21/5 steps per YM sample; render()
//     box-filters (averages) its output over each sample's span.
//
// Levels (render() returns stereo floats in -1..1):
//   * FM: ymfm's 16-bit output (all six channels at full scale ~ +-32 640)
//     / 32768 * FM_GAIN (0.8). ymfm models the YM2612's DAC "ladder"
//     offset (+4 / -3 9-bit steps per channel), so a silent chip outputs a
//     constant +504; that DC is removed (the console's output is AC
//     coupled), so silence is exactly 0. One FM channel at full volume is
//     about +-0.13 (one 9-bit DAC step = 0.000513).
//   * PSG: one channel at 0 dB is +-PSG_CHANNEL_MAX (0.0337), mono, the same
//     on both sides.
//   * Balance: Genesis Plus GX's defaults - the project's reference emulator
//     (stable-retro). There a full-volume PSG channel swings 2800 x 150 %
//     (its psg_preamp) = 4200 in units where one YM2612 DAC step is 32, i.e.
//     +-65.6 DAC steps; PSG_CHANNEL_MAX is that many of ymfm's steps. Measured
//     in GPGX (out/plan12/ext/gp_balance.py): fundamental of a 440 Hz PSG
//     square / that of a full-volume FM sine = 0.327; MwChips: 0.322 (ymfm's
//     full-volume sine is 1.8 % larger than GPGX's; 0.15 dB).
//     (MAME's megadriv mix makes the PSG about twice as loud; real consoles
//     differ by model.)
//   * The DAC channel (register $2A with $2B = $80) replaces FM channel 6;
//     dac_full_scale() is its output for $2A = $FF minus that for $80 in
//     this mix (the port plays PCM natively at that level).
//
//   * PCM (pcm_*): the samples the original's Z80 streams through the DAC,
//     mixed here natively (PcmMixer: windowed-sinc resampling, no DAC hold)
//     at the DAC's level: a full-scale value ($FF) = dac_full_scale(), i.e.
//     pcm_gain() = dac_full_scale() x 128 / 127 for (s - $80) / $80. The DAC
//     itself (register $2A) stays at $80: $2B still mutes FM channel 6 while
//     samples play, as on the hardware.
//
// Register writes take effect at the next rendered sample (the original's
// Z80 writes a tick's registers ~34 us apart, which this ignores).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <memory>

#include "pcm_mixer.h"
#include "sn76489.h"

namespace ymfm {
class ym2612;
}

namespace mw {

class YmInterface;

class MwChips : public godot::RefCounted {
	GDCLASS(MwChips, godot::RefCounted)

public:
	static constexpr int MASTER_CLOCK = 53693175;  // NTSC Genesis
	static constexpr int YM_CLOCK = 7670453;       // master / 7
	static constexpr int YM_CLOCKS_PER_SAMPLE = 144;  // 6 channels x 4 operators x 6
	static constexpr int PSG_CLOCK = 3579545;      // master / 15
	// PSG counter steps per YM sample = (144 * 7 / 15) / 16 = 21 / 5.
	static constexpr int PSG_SPAN_PER_SAMPLE = 21; // in fifths of a PSG step
	static constexpr int PSG_SPAN_PER_STEP = 5;
	static constexpr float FM_GAIN = 0.8f;
	// ymfm: one 9-bit DAC step = 128 * 64 / (6 * 65) of its 16-bit output.
	static constexpr float YM_DAC_STEP = FM_GAIN * (128.0f * 64.0f / 390.0f) / 32768.0f;
	// GPGX: a full-volume PSG channel = +-2100 / 32 DAC steps (see above).
	static constexpr float PSG_CHANNEL_MAX = (2100.0f / 32.0f) * YM_DAC_STEP;  // 0.03365

	MwChips();
	~MwChips() override;

	// Both chips back to their reset state (silent; DAC off at $80).
	void reset();
	// One YM2612 register write: address then data on port 0 ($4000/1: regs
	// $21-$B6 for channels 1-3 and the globals) or 1 ($4002/3: channels 4-6).
	void ym_write(int port, int reg, int value);
	// One byte to the PSG port.
	void psg_write(int value);
	// The next `frames` stereo samples at sample_rate().
	godot::PackedVector2Array render(int frames);
	// 7 670 453 / 144 Hz.
	double sample_rate() const;
	// Mix-level amplitude of the DAC at $FF relative to $80 ($2B = $80).
	double dac_full_scale() const;

	// PCM: sample `id` (unsigned 8-bit, $80 = silence) at `rate` Hz for step
	// $100, looping from `loop_start` (-1: no loop).
	void pcm_load(int id, const godot::PackedByteArray &data, double rate, int loop_start);
	// Channel `ch` (0-3, the Z80's) plays sample `id` from `from_index`.
	// Voice `v` (0-3 the channels, 4-15 extra voices) stops; 8.8 step;
	// volume ($80 = unity); still sounding; its sample (-1: silent).
	void pcm_start(int ch, int id, int from_index);
	void pcm_stop(int v);
	void pcm_stop_all();
	void pcm_rate(int v, int step);
	void pcm_volume(int v, int volume);
	bool pcm_active(int v) const;
	int pcm_sample(int v) const;
	// Extra voices (PcmMixer): channel `ch`'s voice moved on to one (its id
	// or -1); sample `id` started on one (id or -1); voice `v` faded out over
	// `frames` output samples.
	int pcm_detach(int ch);
	int pcm_start_extra(int id, int step, int volume);
	void pcm_fade(int v, int frames);
	// Level of a full-scale PCM value in the mix.
	void set_pcm_gain(double gain);
	double pcm_gain() const;

protected:
	static void _bind_methods();

private:
	void reset_chips();
	float psg_sample();

	std::unique_ptr<YmInterface> ym_interface_;
	std::unique_ptr<ymfm::ym2612> ym_;
	Sn76489 psg_;
	PcmMixer pcm_;
	double pcm_gain_ = 0.0;
	int psg_step_left_ = PSG_SPAN_PER_STEP;  // fifths of a step until the next PSG step
	double dac_full_scale_ = 0.0;
};

} // namespace mw
