@tool
class_name CdActorCatalog
extends Resource
## European CD data tables. Original CPU addresses are stable source IDs only;
## native gameplay never executes instructions from SHELL.BIN.
const Data = preload("res://scripts/assets/cd_level_decoder.gd")
const WORD_FIELDS := {
	"rate": 0,
	"accuracy": 2,
	"speed": 8,
	"rest": 10,
	"duration": 12,
	"spread": 14,
	"height": 16,
	"health": 18,
	"hit_rest": 20,
	"hit_clock": 22,
	"hit_attack_clock": 24,
	"hit_radius": 38,
	"lateral_push": 42,
	"forward_push": 44,
	"radius": 40,
	"stand_distance": 46
}
const POINTER_FIELDS := {"weapon": 4, "idle": 48, "walk": 52, "hurt": 56, "death": 60}
var frames: Dictionary = {}
var parameters: Dictionary = {}
var animations: Dictionary = {}
var actors: Array[Dictionary] = []
var sprite_palette := PackedColorArray()
var normal_major := PackedInt32Array()
var normal_minor := PackedInt32Array()
var theme: Dictionary = {}
var source_sha256: String
var level_sha256: String
var last_error: String
var _shell_bytes: PackedByteArray


func decode(shell: PackedByteArray, level: Resource) -> bool:
	frames.clear()
	parameters.clear()
	animations.clear()
	actors.clear()
	sprite_palette.clear()
	normal_major.clear()
	normal_minor.clear()
	if level == null or level.source_bytes.size() < 48 or shell.size() < 0x4b2b2:
		return _invalid("Truncated actor source tables")
	level_sha256 = level.source_sha256
	var bytes: PackedByteArray = level.source_bytes
	var palette_at := Data._u32(bytes, 16) + 64
	var pointers_at := Data._u32(bytes, 44)
	if palette_at + 32 > bytes.size() or pointers_at + 162 * 4 > bytes.size():
		return _invalid("Truncated level sprite palette/pointer table")
	for index: int in range(16):
		var color := Data._u16(bytes, palette_at + index * 2)
		sprite_palette.append(
			Color(
				float(color & 14) / 14,
				float((color >> 4) & 14) / 14,
				float((color >> 8) & 14) / 14,
				0.0 if index == 0 else 1.0
			)
		)
	for index: int in range(162):
		var address := 0x52648 + index * 18
		var at := address - 0x8000
		var width := Data._u16(shell, at)
		var height := Data._u16(shell, at + 2)
		var pointer_offset := Data._u32(shell, at + 12)
		# All verified descriptors select level-relative pixels. Direct pointers
		# are a separate format and must never be guessed as file offsets.
		if (
			Data._u32(shell, at + 8) != 0
			or pointer_offset % 4 != 0
			or pointer_offset >= 162 * 4
			or width < 1
			or width > 512
			or height < 1
			or height > 512
		):
			return _invalid("Unsupported frame descriptor at %x" % address)
		var offset := Data._u32(bytes, pointers_at + pointer_offset)
		if offset != 0 and (offset < 48 or offset + ((width + 1) >> 1) * height > bytes.size()):
			return _invalid("Sprite pixels outside the level")
		frames[address] = {
			"width": width,
			"height": height,
			"anchor": Vector2i(Data._s16(shell, at + 4), Data._s16(shell, at + 6)),
			"offset": offset,
			"mirror": Data._u16(shell, at + 16) != 0,
			"index": index
		}
	_shell_bytes = shell.duplicate()
	# Animation effects/projectiles carry direct pixel pointers into SHELL.
	# Decode references from identified animation and weapon data tables.
	# Release fan frame selected by the original $039374 immediate.
	# Approved native missile presentation uses two otherwise unreferenced CD frames.
	# Original projectile frame/state remains $3E156; these are visual resources only.
	var embedded_references: Array = [0x3e798, 0x3e394, 0x3e588]
	for at: int in range(0x30236 - 0x8000, 0x30606 - 0x8000 + 1, 4):
		embedded_references.append(Data._u32(shell, at))
	for index: int in range(21):
		embedded_references.append(Data._u32(shell, 0x32710 + index * 22 + 6))
	# $0377F6 selects the local player proxy's direction/walk/hurt frames from
	# this table. Its live body is hidden in first person; the resources remain
	# inspectable through the same runtime/editor catalog as its death frames.
	for index: int in range(40):
		embedded_references.append(Data._u32(shell, 0x2f87c + index * 4))
	for frame_reference: int in embedded_references:
		var address := frame_reference
		if address > 0x30606 and address < 0x52648 and not frames.has(address):
			var descriptor := address - 0x8000
			if descriptor < 0 or descriptor + 18 > shell.size():
				return _invalid("Invalid embedded frame descriptor")
			var width := Data._u16(shell, descriptor)
			var height := Data._u16(shell, descriptor + 2)
			var offset := Data._u32(shell, descriptor + 8) - 0x8000
			if (
				width < 1
				or width > 512
				or height < 1
				or height > 512
				or offset < 0
				or offset + ((width + 1) >> 1) * height > shell.size()
			):
				return _invalid("Unsupported embedded sprite pixels")
			frames[address] = {
				"width": width,
				"height": height,
				"anchor":
				Vector2i(Data._s16(shell, descriptor + 4), Data._s16(shell, descriptor + 6)),
				"offset": offset,
				"mirror": Data._u16(shell, descriptor + 16) != 0,
				"index": -1,
				"embedded": true
			}
	for index: int in range(257):
		normal_major.append(Data._s16(shell, 0x7d2 + index * 2))
		normal_minor.append(Data._s16(shell, 0x9d4 + index * 2))
	for address: int in range(0x30236, 0x30606 + 1, 4):
		animations[address] = Data._u32(shell, address - 0x8000)
	for kind: int in range(1, 20):
		var address := 0x2fd76 + (kind - 1) * 64
		var at := address - 0x8000
		var params: Dictionary = {}
		for field: String in WORD_FIELDS:
			params[field] = Data._s16(shell, at + int(WORD_FIELDS[field]))
		for field: String in POINTER_FIELDS:
			params[field] = Data._u32(shell, at + int(POINTER_FIELDS[field]))
		for sound: String in ["audio_activation", "audio_hurt", "audio_death"]:
			var offset := {"audio_activation": 26, "audio_hurt": 30, "audio_death": 34}
			var value := Data._u32(shell, at + int(offset[sound]))
			params[sound] = value - 0x100000000 if value >= 0x80000000 else value
		parameters[address] = params
	var theme_at := 0x2fd0e - 0x8000 + Data._u32(bytes, 22)
	if theme_at < 0 or theme_at + 26 > shell.size():
		return _invalid("Invalid campaign theme")
	theme = {
		"angular_speed": Data._s16(shell, theme_at),
		"shield_hit_angular": Data._s16(shell, theme_at + 2),
		"satellite_death_angular": Data._s16(shell, theme_at + 4),
		"maximum_angular": Data._s16(shell, theme_at + 6),
		"maximum_radius": Data._s16(shell, theme_at + 8),
		"minimum_radius": Data._s16(shell, theme_at + 10),
		"radial_speed": Data._s16(shell, theme_at + 12),
		"satellites": Data._s16(shell, theme_at + 14),
		"satellite_rate": Data._s16(shell, theme_at + 16),
		"maximum_satellite_rate": Data._s16(shell, theme_at + 18),
		"satellite_death_rate": Data._s16(shell, theme_at + 20),
		"shield_hit_rate": Data._s16(shell, theme_at + 22),
		"boss_rate": Data._s16(shell, theme_at + 24)
	}
	for placement: Dictionary in level.placements:
		var offset := int(placement.template_offset)
		if offset == 0 or offset == 6:
			continue  # Player spawn records do not allocate map actors.
		if offset < 12 or offset % 6 != 0 or offset > 0xf0:
			return _invalid("Unsupported actor template")
		var at := 0x531ac - 0x8000 + offset
		var frame := Data._u32(shell, at)
		var kind := Data._u16(shell, at + 4)
		if not frames.has(frame):
			return _invalid("Unknown initial actor frame")
		var actor := _actor(kind, frame, placement.position, int(placement.angle))
		actors.append(actor)
		if kind == 4:
			if int(theme.satellites) < 1 or int(theme.satellites) > 16:
				return _invalid("Invalid satellite count")
			for index: int in range(int(theme.satellites)):
				var satellite := _actor(17, 0x529a8, placement.position, 45)
				@warning_ignore("integer_division")
				satellite.phase = index * (256 / int(theme.satellites))
				actors.append(satellite)
	last_error = ""
	return true


func _actor(kind: int, frame: int, point: Vector2i, height: int) -> Dictionary:
	var parameter := 0x2fd76 + (kind - 1) * 64 if kind >= 1 and kind <= 19 else 0
	return {
		"kind": kind,
		"frame": frame,
		"cursor": 0,
		"timer": 0,
		"height": height,
		"x": point.x,
		"y": point.y,
		"target": -1,
		"seen": -1,
		"lost": 0,
		"parameter": parameter,
		"counter": 0,
		"wall_cursor": 0,
		"aim_x": 0,
		"aim_y": 0,
		"charge": 0,
		"cooldown": 0,
		"health": int(parameters[parameter].health) if parameter != 0 else 0,
		"impulse_x": 0,
		"impulse_y": 0,
		"phase": 0,
		"mine_clock": 0
	}


func decode_image(level: Resource, address: int) -> Image:
	if level == null or not frames.has(address):
		return null
	return decode_sprite_image(
		_shell_bytes if frames[address].get("embedded", false) else level.source_bytes,
		frames[address],
		sprite_palette
	)


func decode_index_image(level: Resource, address: int) -> Image:
	if level == null or not frames.has(address):
		return null
	var palette := preload("res://scripts/assets/cd_palette_data.gd").index_palette(32)
	return decode_sprite_image(
		_shell_bytes if frames[address].get("embedded", false) else level.source_bytes,
		frames[address], palette
	)


static func decode_sprite_image(
	bytes: PackedByteArray, frame: Dictionary, palette: PackedColorArray
) -> Image:
	var width := int(frame.get("width", 0))
	var height := int(frame.get("height", 0))
	var offset := int(frame.get("offset", 0))
	if (
		width < 1
		or width > 512
		or height < 1
		or height > 512
		or palette.size() != 16
		or offset <= 0
		or offset + ((width + 1) >> 1) * height > bytes.size()
	):
		return null
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for x: int in range(width):
		var source_x := width - 1 - x if frame.get("mirror", false) else x
		for y: int in range(height):
			var packed := int(bytes[offset + (source_x >> 1) * height + y])
			var index := (packed >> 4) if source_x % 2 == 0 else (packed & 15)
			var color := palette[index]
			if index == 0:
				color.a = 0
			image.set_pixel(x, y, color)
	return image


func _invalid(message: String) -> bool:
	last_error = message
	return false
