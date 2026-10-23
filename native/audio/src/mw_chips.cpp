// mightyweenie - audio GDExtension (native/mw_audio).
// Copyright (c) 2026 the mightyweenie authors. BSD-3-Clause
// (see LICENSE). Links ymfm (BSD-3-Clause,
// Aaron Giles) and godot-cpp (MIT).
//
// MwChips: YM2612 (ymfm) + PSG (Sn76489), see mw_chips.h.
#include "mw_chips.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>

#include "ymfm_opn.h"

namespace mw {

// ymfm's host interface. The defaults are what the Genesis needs here: the
// timers are never armed (the original's driver neither reads the status
// register nor uses timer interrupts), the busy flag is never read, and
// there is no external memory (the YM2612 has none).
class YmInterface : public ymfm::ymfm_interface {};

namespace {

// ymfm::ym2612::generate output for a silent chip: each of the six channel
// slots adds the DAC ladder offset dac_discontinuity(0) = +4, then the sum is
// scaled by 128 * 64 / (6 * 65) (ymfm_opn.cpp). Removed so silence is 0.
constexpr int32_t kYmSilence = (6 * 4 * 128) * 64 / (6 * 65);  // 504
constexpr float kYmScale = MwChips::FM_GAIN / 32768.0f;

int32_t dac_output(ymfm::ym2612 &chip, uint8_t value) {
	chip.write(0, 0x2A);
	chip.write(1, value);
	ymfm::ym2612::output_data out;
	chip.generate(&out, 1);
	return out.data[0];
}

} // namespace

MwChips::MwChips() :
		ym_interface_(std::make_unique<YmInterface>()),
		ym_(std::make_unique<ymfm::ym2612>(*ym_interface_)) {
	// The DAC's level, measured on a scratch chip: $2B = $80, $2A = $FF vs $80.
	YmInterface probe_interface;
	ymfm::ym2612 probe(probe_interface);
	probe.reset();
	probe.write(0, 0x2B);
	probe.write(1, 0x80);
	const int32_t high = dac_output(probe, 0xFF);
	const int32_t centre = dac_output(probe, 0x80);
	dac_full_scale_ = static_cast<double>(high - centre) * kYmScale;
	pcm_gain_ = dac_full_scale_ * 128.0 / 127.0;
	pcm_.configure(sample_rate(), pcm_gain_);
	reset_chips();
}

MwChips::~MwChips() = default;

void MwChips::reset_chips() {
	ym_->reset();
	// ymfm's reset leaves the DAC latch alone; the hardware's DAC is off at reset.
	ym_->write(0, 0x2B);
	ym_->write(1, 0x00);
	ym_->write(0, 0x2A);
	ym_->write(1, 0x80);
	psg_.reset();
	psg_step_left_ = PSG_SPAN_PER_STEP;
	pcm_.stop_all();
}

void MwChips::reset() {
	reset_chips();
}

void MwChips::ym_write(int port, int reg, int value) {
	const uint32_t base = (port & 1) ? 2 : 0;
	ym_->write(base, static_cast<uint8_t>(reg));
	ym_->write(base + 1, static_cast<uint8_t>(value));
}

void MwChips::psg_write(int value) {
	psg_.write(static_cast<uint8_t>(value));
}

float MwChips::psg_sample() {
	// Average the PSG's (piecewise constant) output over one YM sample: 21
	// fifths of a counter step, stepping the PSG at each step boundary.
	int span = PSG_SPAN_PER_SAMPLE;
	float acc = 0.0f;
	while (span > 0) {
		const int take = std::min(span, psg_step_left_);
		acc += psg_.output() * static_cast<float>(take);
		span -= take;
		psg_step_left_ -= take;
		if (psg_step_left_ == 0) {
			psg_.tick();
			psg_step_left_ = PSG_SPAN_PER_STEP;
		}
	}
	return acc * (PSG_CHANNEL_MAX / PSG_SPAN_PER_SAMPLE);
}

godot::PackedVector2Array MwChips::render(int frames) {
	godot::PackedVector2Array out;
	if (frames <= 0) {
		return out;
	}
	out.resize(frames);
	godot::Vector2 *dst = out.ptrw();
	ymfm::ym2612::output_data ym;
	for (int i = 0; i < frames; i++) {
		ym_->generate(&ym, 1);
		const float mono = psg_sample() + pcm_.next();
		const float left = static_cast<float>(ym.data[0] - kYmSilence) * kYmScale + mono;
		const float right = static_cast<float>(ym.data[1] - kYmSilence) * kYmScale + mono;
		dst[i] = godot::Vector2(std::clamp(left, -1.0f, 1.0f), std::clamp(right, -1.0f, 1.0f));
	}
	return out;
}

double MwChips::sample_rate() const {
	return static_cast<double>(YM_CLOCK) / YM_CLOCKS_PER_SAMPLE;
}

double MwChips::dac_full_scale() const {
	return dac_full_scale_;
}

void MwChips::pcm_load(int id, const godot::PackedByteArray &data, double rate, int loop_start) {
	pcm_.load(id, data.ptr(), data.size(), rate, loop_start);
}

void MwChips::pcm_start(int ch, int id, int from_index) {
	pcm_.start(ch, id, from_index);
}

void MwChips::pcm_stop(int ch) {
	pcm_.stop(ch);
}

void MwChips::pcm_stop_all() {
	pcm_.stop_all();
}

void MwChips::pcm_rate(int ch, int step) {
	pcm_.set_step(ch, step);
}

void MwChips::pcm_volume(int ch, int volume) {
	pcm_.set_volume(ch, volume);
}

bool MwChips::pcm_active(int ch) const {
	return pcm_.active(ch);
}

int MwChips::pcm_sample(int v) const {
	return pcm_.sample_of(v);
}

int MwChips::pcm_detach(int ch) {
	return pcm_.detach(ch);
}

int MwChips::pcm_start_extra(int id, int step, int volume) {
	return pcm_.start_extra(id, step, volume);
}

void MwChips::pcm_fade(int v, int frames) {
	pcm_.fade(v, frames);
}

void MwChips::set_pcm_gain(double gain) {
	pcm_gain_ = gain;
	pcm_.configure(sample_rate(), pcm_gain_);
}

double MwChips::pcm_gain() const {
	return pcm_gain_;
}

void MwChips::_bind_methods() {
	using godot::ClassDB;
	using godot::D_METHOD;
	ClassDB::bind_method(D_METHOD("reset"), &MwChips::reset);
	ClassDB::bind_method(D_METHOD("ym_write", "port", "reg", "value"), &MwChips::ym_write);
	ClassDB::bind_method(D_METHOD("psg_write", "value"), &MwChips::psg_write);
	ClassDB::bind_method(D_METHOD("render", "frames"), &MwChips::render);
	ClassDB::bind_method(D_METHOD("sample_rate"), &MwChips::sample_rate);
	ClassDB::bind_method(D_METHOD("dac_full_scale"), &MwChips::dac_full_scale);
	ClassDB::bind_method(D_METHOD("pcm_load", "id", "data", "rate", "loop_start"), &MwChips::pcm_load);
	ClassDB::bind_method(D_METHOD("pcm_start", "ch", "id", "from_index"), &MwChips::pcm_start);
	ClassDB::bind_method(D_METHOD("pcm_stop", "ch"), &MwChips::pcm_stop);
	ClassDB::bind_method(D_METHOD("pcm_stop_all"), &MwChips::pcm_stop_all);
	ClassDB::bind_method(D_METHOD("pcm_rate", "ch", "step"), &MwChips::pcm_rate);
	ClassDB::bind_method(D_METHOD("pcm_volume", "ch", "volume"), &MwChips::pcm_volume);
	ClassDB::bind_method(D_METHOD("pcm_active", "v"), &MwChips::pcm_active);
	ClassDB::bind_method(D_METHOD("pcm_sample", "v"), &MwChips::pcm_sample);
	ClassDB::bind_method(D_METHOD("pcm_detach", "ch"), &MwChips::pcm_detach);
	ClassDB::bind_method(D_METHOD("pcm_start_extra", "id", "step", "volume"), &MwChips::pcm_start_extra);
	ClassDB::bind_method(D_METHOD("pcm_fade", "v", "frames"), &MwChips::pcm_fade);
	ClassDB::bind_method(D_METHOD("set_pcm_gain", "gain"), &MwChips::set_pcm_gain);
	ClassDB::bind_method(D_METHOD("pcm_gain"), &MwChips::pcm_gain);
}

} // namespace mw
