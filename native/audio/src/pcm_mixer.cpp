// mightyweenie - audio GDExtension (native/mw_audio).
// Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
// (see LICENSE).
//
// PcmMixer, see pcm_mixer.h.
#include "pcm_mixer.h"

#include <cmath>

namespace mw {

namespace {

constexpr double kPi = 3.14159265358979323846;

double sinc(double x) {
	if (std::fabs(x) < 1e-9) {
		return 1.0;
	}
	return std::sin(kPi * x) / (kPi * x);
}

} // namespace

PcmMixer::PcmMixer() {
	// Lanczos kernel: taps at offsets -3..+4 from the sample before the
	// position, for PHASES + 1 fractions in [0, 1]; each row normalised so a
	// constant signal stays constant.
	constexpr int a = TAPS / 2;
	for (int p = 0; p <= PHASES; p++) {
		const double frac = static_cast<double>(p) / PHASES;
		double sum = 0.0;
		double row[TAPS];
		for (int t = 0; t < TAPS; t++) {
			const double x = static_cast<double>(t - (a - 1)) - frac;
			row[t] = std::fabs(x) < a ? sinc(x) * sinc(x / a) : 0.0;
			sum += row[t];
		}
		for (int t = 0; t < TAPS; t++) {
			kernel_[p][t] = static_cast<float>(row[t] / sum);
		}
	}
}

void PcmMixer::load(int id, const uint8_t *data, int64_t size, double rate, int64_t loop_start) {
	if (id < 0) {
		return;
	}
	if (static_cast<size_t>(id) >= samples_.size()) {
		samples_.resize(id + 1);
	}
	Sample &s = samples_[id];
	s.data.resize(size > 0 ? size : 0);
	for (int64_t i = 0; i < size; i++) {
		s.data[i] = (static_cast<float>(data[i]) - 128.0f) / 128.0f;
	}
	s.rate = rate;
	s.loop_start = (loop_start >= 0 && loop_start < size) ? loop_start : -1;
}

void PcmMixer::configure(double out_rate, double gain) {
	out_rate_ = out_rate;
	gain_ = gain;
	for (Voice &v : voices_) {
		update(v);
	}
}

void PcmMixer::update(Voice &v) {
	double rate = 0.0;
	if (v.id >= 0 && static_cast<size_t>(v.id) < samples_.size()) {
		rate = samples_[v.id].rate;
	}
	v.inc = rate * (static_cast<double>(v.step) / 256.0) / out_rate_;
	v.gain = static_cast<float>(gain_ * static_cast<double>(v.volume) / 128.0);
}

void PcmMixer::start(int ch, int id, int64_t from_index) {
	if (ch < 0 || ch >= VOICES) {
		return;
	}
	Voice &v = voices_[ch];
	if (id < 0 || static_cast<size_t>(id) >= samples_.size() || samples_[id].data.empty()) {
		v.active = false;
		v.id = -1;
		return;
	}
	v.id = id;
	v.pos = static_cast<double>(from_index > 0 ? from_index : 0);
	v.active = true;
	v.serial = ++serial_;
	v.fade_left = -1;
	v.fade_gain = 1.0f;
	update(v);
}

void PcmMixer::stop(int v) {
	if (v >= 0 && v < TOTAL) {
		voices_[v].active = false;
	}
}

int PcmMixer::sample_of(int v) const {
	return (v >= 0 && v < TOTAL && voices_[v].active) ? voices_[v].id : -1;
}

int PcmMixer::free_extra() {
	int oldest = VOICES;
	for (int v = VOICES; v < TOTAL; v++) {
		if (!voices_[v].active) {
			return v;
		}
		if (voices_[v].serial < voices_[oldest].serial) {
			oldest = v;
		}
	}
	return oldest;
}

int PcmMixer::detach(int ch) {
	if (ch < 0 || ch >= VOICES || !voices_[ch].active) {
		return -1;
	}
	const int e = free_extra();
	voices_[e] = voices_[ch];
	voices_[ch].active = false;
	return e;
}

int PcmMixer::start_extra(int id, int step, int volume) {
	if (id < 0 || static_cast<size_t>(id) >= samples_.size() || samples_[id].data.empty()) {
		return -1;
	}
	const int e = free_extra();
	Voice &v = voices_[e];
	v.id = id;
	v.pos = 0.0;
	v.step = step;
	v.volume = volume;
	v.active = true;
	v.serial = ++serial_;
	v.fade_left = -1;
	v.fade_gain = 1.0f;
	update(v);
	return e;
}

void PcmMixer::fade(int v, int frames) {
	if (v < 0 || v >= TOTAL || !voices_[v].active) {
		return;
	}
	Voice &voice = voices_[v];
	if (frames <= 0) {
		voice.active = false;
		return;
	}
	voice.fade_left = frames;
	voice.fade_step = voice.fade_gain / static_cast<float>(frames);
}

void PcmMixer::stop_all() {
	for (Voice &v : voices_) {
		v.active = false;
	}
}

void PcmMixer::set_step(int v, int step) {
	if (v >= 0 && v < TOTAL) {
		voices_[v].step = step;
		update(voices_[v]);
	}
}

void PcmMixer::set_volume(int v, int volume) {
	if (v >= 0 && v < TOTAL) {
		voices_[v].volume = volume;
		update(voices_[v]);
	}
}

bool PcmMixer::active(int v) const {
	return v >= 0 && v < TOTAL && voices_[v].active;
}

float PcmMixer::tap(const Sample &s, int64_t i) const {
	const int64_t n = static_cast<int64_t>(s.data.size());
	if (i < 0) {
		return 0.0f;
	}
	if (i >= n) {
		if (s.loop_start < 0) {
			return 0.0f;
		}
		const int64_t len = n - s.loop_start;
		i = s.loop_start + (i - n) % len;
	}
	return s.data[i];
}

float PcmMixer::next() {
	float sum = 0.0f;
	for (Voice &v : voices_) {
		if (!v.active) {
			continue;
		}
		const Sample &s = samples_[v.id];
		const int64_t i = static_cast<int64_t>(v.pos);
		const double frac = v.pos - static_cast<double>(i);
		const float *k = kernel_[static_cast<int>(frac * PHASES + 0.5)];
		float acc = 0.0f;
		for (int t = 0; t < TAPS; t++) {
			acc += k[t] * tap(s, i + t - (TAPS / 2 - 1));
		}
		if (v.fade_left >= 0) {
			sum += acc * v.gain * v.fade_gain;
			v.fade_gain -= v.fade_step;
			if (--v.fade_left <= 0 || v.fade_gain <= 0.0f) {
				v.active = false;
				continue;
			}
		} else {
			sum += acc * v.gain;
		}
		v.pos += v.inc;
		const double n = static_cast<double>(s.data.size());
		if (v.pos >= n) {
			if (s.loop_start >= 0) {
				const double len = n - static_cast<double>(s.loop_start);
				v.pos = static_cast<double>(s.loop_start) + std::fmod(v.pos - n, len);
			} else {
				v.active = false;
			}
		}
	}
	return sum;
}

} // namespace mw
