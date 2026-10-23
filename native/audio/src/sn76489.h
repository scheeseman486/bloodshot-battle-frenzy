// mightyweenie - audio GDExtension (native/mw_audio).
// Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
// (see LICENSE).
//
// Sn76489: the Sega VDP's PSG (an SN76489 derivative), written for this
// project from the chip's public documentation (SMS Power "SN76489" notes,
// the Sega Genesis technical overview). Not derived from any emulator's code.
//
// What is modelled:
//   * 3 tone channels: a 10-bit divider N; the channel's counter steps once
//     every 16 input clocks and flips the channel's output each time it
//     counts N steps, so f = clock / (32 N). Sega's chip treats N = 0 like
//     N = 1, and a divider of 0 or 1 holds the output at +1 (the "volume
//     register PCM" trick of Sega's PSG).
//   * 1 noise channel: a 16-bit shift register (Sega's length; TI's chips
//     use 15) shifted on each rising edge of the noise clock; white noise
//     feeds back bit 0 XOR bit 3, periodic noise feeds back bit 0 (one pulse
//     every 16 shifts). The register is reset to $8000 whenever the noise
//     control register is written. Noise clock: the input clock / 512, /1024,
//     /2048 (control 0-2) or tone channel 2's output (control 3).
//   * 4 attenuators of 2 dB per step; 15 = off.
//   * The write protocol: a byte with bit 7 set latches a register
//     (bits 6-5 channel, bit 4 1 = attenuation / 0 = tone or noise) and
//     writes its low 4 bits; a byte with bit 7 clear writes the latched
//     register's high 6 bits (tone) or its whole value (attenuation, noise).
//
// Output: each channel is bipolar (+level / -level), level = 10^(-2a/20)
// for attenuation a (1.0 at 0 dB, 0 when off). output() is the sum of the
// four channels (-4..4); the owner scales it into the mix.
//
// The real chip powers up with all attenuations at 0 (loud); reset() starts
// silent (all attenuations 15), which is what every Genesis game does first.
#pragma once

#include <cstdint>

namespace mw {

class Sn76489 {
public:
	// The tone and noise counters step once every TICK_CLOCKS input clocks.
	static constexpr int TICK_CLOCKS = 16;

	Sn76489();

	// Back to the power-on state used by the port (silent, see above).
	void reset();

	// One byte written to the PSG port (the Genesis' $C00011 / Z80 $7F11).
	void write(uint8_t value);

	// Advance one counter step (TICK_CLOCKS input clocks).
	void tick();

	// Current output: the four channels summed, each in -1..1.
	float output() const { return output_; }

	// Register state, for tests.
	int tone_divider(int channel) const { return divider_[channel]; }
	int attenuation(int channel) const { return attenuation_[channel]; }
	int noise_control() const { return noise_control_; }
	uint16_t noise_shift_register() const { return lfsr_; }

private:
	void update_output();
	void shift_noise();

	uint16_t divider_[3];     // tone dividers N (10 bits)
	uint8_t attenuation_[4];  // 0 = loudest .. 15 = off
	uint8_t noise_control_;   // bit 2: 1 = white noise; bits 1-0: noise clock
	uint8_t latched_;         // latched register: channel * 2 + (1 = attenuation)

	uint16_t counter_[4];     // steps left until the next output flip
	int8_t flip_flop_[4];     // tone outputs (+1 / -1); [3] = noise clock
	uint16_t lfsr_;           // noise shift register; output = bit 0
	float output_;
};

} // namespace mw
