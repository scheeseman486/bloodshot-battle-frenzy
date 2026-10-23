extends RefCounted
## CD $2ED58 endpoint palettes, using a private presentation clock/RNG.
## All frontend backgrounds blend complete endpoint palettes on fractional time.
## Discrete integer steps remain available for original-behaviour checks.
## Mean spacing of the 44 recorded main-menu palette completions: 1,151 PAL
## video periods / 43 intervals. Native drawing never waits for graphics hardware.
const STEP_TICKS := 1151.0 / 43.0
var texture: ImageTexture
var _image: Image
var _targets: Array = []
var _rng := RandomNumberGenerator.new()
var _from := Vector3i.ZERO
var _target := Vector3i.ZERO
var _target_index := -1
var _last_step := -1


func configure(targets: Array, initial: int = -1, explicit_rgb := Vector3i(-1,-1,-1), seed_value: int = 0) -> void:
	_targets = targets.duplicate()
	if seed_value == 0: _rng.randomize()
	else: _rng.seed = seed_value
	var first := _rng.randi_range(0, _targets.size()-1) if initial < 0 else posmod(initial, _targets.size())
	_from = explicit_rgb if explicit_rgb.x >= 0 else _targets[first]
	_target_index = first
	_choose_target()
	_last_step = -1
	advance(0,true)


func _choose_target() -> void:
	# Draw uniformly from all other source targets; no simulation RNG or fixed order.
	var next := _rng.randi_range(0, _targets.size()-2)
	if next >= _target_index: next += 1
	_target_index = next
	_target = _targets[next]


func advance(ticks: float, smooth: bool = true) -> void:
	var step := maxi(0, int(floor(float(ticks) / STEP_TICKS)))
	var format := Image.FORMAT_RGBAF if smooth else Image.FORMAT_RGBA8
	if step == _last_step and not smooth and _image.get_format() == format: return
	# Absolute ticks make catch-up independent of render frame count.
	for boundary: int in range((maxi(_last_step, 0) / 32) + 1, (step / 32) + 1):
		_from = _target
		_choose_target()
	_last_step = step
	var rgb := interpolate(_from, _target, step % 32)
	var replace := _image == null or _image.get_format() != format
	if replace: _image = Image.create_empty(16,1,false,format)
	# Native menu refinement: blend the complete source endpoint palettes over
	# all 32 steps. Never round the moving RGB value into console colour bits;
	# that would hold colours for long intervals even with fractional time.
	var weight := fposmod(maxf(0.0,ticks) / STEP_TICKS,32.0) / 32.0
	for index: int in range(16):
		var ink := interpolate(Vector3i.ZERO,rgb,index,15)
		var colour := packed_colour(ink)
		if smooth:
			var first := packed_colour(interpolate(Vector3i.ZERO,_from,index,15))
			var target := packed_colour(interpolate(Vector3i.ZERO,_target,index,15))
			colour = first.lerp(target,weight)
		_image.set_pixel(index,0,colour)
	if texture == null: texture = ImageTexture.create_from_image(_image)
	elif replace: texture.set_image(_image)
	else: texture.update(_image)


static func interpolate(first: Vector3i, target: Vector3i, step: int, divisor: int = 32) -> Vector3i:
	var result := first
	for channel: int in range(3):
		# Integer division truncates towards zero, including falling components.
		@warning_ignore("integer_division")
		var delta: int = ((target[channel]-first[channel])*step) / divisor
		result[channel] += delta
	return result


static func packed_colour(rgb: Vector3i) -> Color:
	var word := rgb.x | (rgb.y << 4) | (rgb.z << 8)
	return Color(float(word & 14)/14.0,float((word >> 4)&14)/14.0,float((word >> 8)&14)/14.0)
