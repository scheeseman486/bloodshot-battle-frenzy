// mightyweenie - audio GDExtension (native/mw_audio).
// Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
// (see LICENSE).
//
// Sega VDP PSG (SN76489 derivative). Behaviour summary in sn76489.h.
#include "sn76489.h"

#include <cmath>

namespace mw {

namespace {

// Attenuation in 2 dB steps: level[a] = 10^(-2a/20); 15 = off.
struct AttenuationTable {
	float level[16];
	AttenuationTable() {
		for (int a = 0; a < 15; a++) {
			level[a] = static_cast<float>(std::pow(10.0, -2.0 * a / 20.0));
		}
		level[15] = 0.0f;
	}
};
const AttenuationTable kAttenuation;

// Shift register: 16 bits, reset value, white-noise taps (Sega: bits 0 and 3).
constexpr uint16_t kLfsrReset = 0x8000;
constexpr uint16_t kWhiteNoiseTaps = 0x0009;

} // namespace

Sn76489::Sn76489() {
	reset();
}

void Sn76489::reset() {
	for (int c = 0; c < 3; c++) {
		divider_[c] = 0;
	}
	for (int c = 0; c < 4; c++) {
		attenuation_[c] = 15;
		counter_[c] = 0;
		flip_flop_[c] = 1;
	}
	noise_control_ = 0;
	latched_ = 0;
	lfsr_ = kLfsrReset;
	update_output();
}

void Sn76489::write(uint8_t value) {
	if (value & 0x80) {
		// Latch byte: 1 cc t dddd
		latched_ = (value >> 4) & 0x07;
	}
	const int channel = latched_ >> 1;
	const bool is_attenuation = latched_ & 1;
	if (is_attenuation) {
		attenuation_[channel] = value & 0x0F;
	} else if (channel == 3) {
		// Noise control (both byte kinds write its 3 bits); resets the register.
		noise_control_ = value & 0x07;
		lfsr_ = kLfsrReset;
	} else if (value & 0x80) {
		divider_[channel] = (divider_[channel] & 0x3F0) | (value & 0x0F);
	} else {
		divider_[channel] = (divider_[channel] & 0x00F) | ((value & 0x3F) << 4);
	}
	update_output();
}

void Sn76489::shift_noise() {
	const bool white = noise_control_ & 0x04;
	uint16_t feedback;
	if (white) {
		uint16_t taps = lfsr_ & kWhiteNoiseTaps;
		feedback = (taps == 0 || taps == kWhiteNoiseTaps) ? 0 : 1; // parity of 2 bits
	} else {
		feedback = lfsr_ & 1;
	}
	lfsr_ = static_cast<uint16_t>((lfsr_ >> 1) | (feedback << 15));
}

void Sn76489::tick() {
	// Tone channels: count down N steps, then flip (N = 0 counts as 1).
	for (int c = 0; c < 3; c++) {
		if (counter_[c] > 0) {
			counter_[c]--;
		}
		if (counter_[c] == 0) {
			counter_[c] = divider_[c] ? divider_[c] : 1;
			flip_flop_[c] = static_cast<int8_t>(-flip_flop_[c]);
			// Noise clocked by tone 2: shift on its rising edge.
			if (c == 2 && (noise_control_ & 0x03) == 0x03 && flip_flop_[c] > 0) {
				shift_noise();
			}
		}
	}
	// Noise channel's own clock (controls 0-2): divider $10 / $20 / $40.
	if ((noise_control_ & 0x03) != 0x03) {
		if (counter_[3] > 0) {
			counter_[3]--;
		}
		if (counter_[3] == 0) {
			counter_[3] = static_cast<uint16_t>(0x10 << (noise_control_ & 0x03));
			flip_flop_[3] = static_cast<int8_t>(-flip_flop_[3]);
			if (flip_flop_[3] > 0) {
				shift_noise();
			}
		}
	}
	update_output();
}

void Sn76489::update_output() {
	float sum = 0.0f;
	for (int c = 0; c < 3; c++) {
		// Dividers 0 and 1 hold the output high (Sega PSG).
		const float polarity = divider_[c] <= 1 ? 1.0f : static_cast<float>(flip_flop_[c]);
		sum += polarity * kAttenuation.level[attenuation_[c]];
	}
	sum += ((lfsr_ & 1) ? 1.0f : -1.0f) * kAttenuation.level[attenuation_[3]];
	output_ = sum;
}

} // namespace mw
