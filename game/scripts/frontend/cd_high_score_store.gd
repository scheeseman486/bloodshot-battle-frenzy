class_name CdHighScoreStore
extends RefCounted
## CD scores survive frontend returns in RAM. A versioned native save extends
## that lifetime across launches; no original media or decoded assets are saved.
const Rules = preload("res://scripts/frontend/cd_high_score_rules.gd")
const SOURCE_SHA256 := "fad81e1ffbc4fea03c478e26f6762fe0b24dcf7a81541023466add29ffca2c31"
const SHELL_SHA256 := "e96ddb13dbe99087d1cd526bc15e022ac76c42b2efce14703fef9214ac8193a4"
const DEFAULT_PATH := "user://high_scores.json"
static var _shared: RefCounted
var rows: Array = []
var path: String
var last_error := ""
var _load_error := ""


static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/frontend/cd_high_score_store.gd").new(DEFAULT_PATH)
	return _shared


func _init(save_path: String = "") -> void:
	path = save_path
	load_scores()


func qualify(level: int, power: int, cheated: bool = false) -> int:
	var index := Rules.qualification(rows, level, power, cheated)
	if index >= 0:
		rows.insert(index, {"level": level, "power": power & 0xffffffff, "initials": ""})
		# The CD search has seven slots. Its unbounded shift can spill into
		# an eighth row and then live counters; native persistence is bounded.
		rows.resize(mini(rows.size(), Rules.CAPACITY))
		save_scores()
	return index


func set_initials(index: int, name: String) -> bool:
	if index < 0 or index >= rows.size() or not _valid_name(name):
		return false
	rows[index].initials = name
	return save_scores()


func load_scores() -> bool:
	last_error = ""
	_load_error = ""
	if path.is_empty() or not FileAccess.file_exists(path):
		return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _reject_load(error_string(FileAccess.get_open_error()))
	if file.get_length() > 16384:
		return _reject_load("Invalid high-score file size")
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return _reject_load("Invalid high-score JSON")
	var data: Variant = parser.data
	if (
		not data is Dictionary
		or data.get("schema") != 1
		or data.get("source_sha256") != SOURCE_SHA256
		or data.get("shell_sha256") != SHELL_SHA256
		or data.get("edition") != "European Mega CD"
		or not _valid_rows(data.get("rows"))
	):
		return _reject_load("Invalid high-score file or source edition")
	rows = data.rows.duplicate(true)
	for row: Dictionary in rows:
		row.level = int(row.level)
		row.power = int(row.power)
	return true


func _reject_load(message: String) -> bool:
	last_error = message
	_load_error = message
	return false


func save_scores() -> bool:
	last_error = ""
	# A malformed or newer-edition file is retained for recovery. A failed
	# load must not quietly erase it when the next campaign qualifies.
	if not _load_error.is_empty():
		last_error = _load_error
		return false
	if path.is_empty():
		return true
	if not _valid_rows(rows):
		last_error = "Invalid high-score records"
		return false
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = error_string(FileAccess.get_open_error())
		return false
	file.store_string(
		(
			JSON.stringify(
				{
					"schema": 1,
					"edition": "European Mega CD",
					"source_sha256": SOURCE_SHA256,
					"shell_sha256": SHELL_SHA256,
					"rows": rows
				},
				"\t"
			)
			+ "\n"
		)
	)
	file.flush()
	var result := file.get_error()
	file.close()
	if result == OK:
		result = DirAccess.rename_absolute(
			ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path)
		)
	if result != OK:
		last_error = error_string(result)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
	return result == OK


static func _valid_rows(value: Variant) -> bool:
	if not value is Array or value.size() > Rules.CAPACITY:
		return false
	var previous: Dictionary = {}
	for item: Variant in value:
		if (
			not item is Dictionary
			or not _integer(item.get("level"), 1, 16)
			or not _integer(item.get("power"), 0, 0xffffffff)
			or not item.get("initials") is String
			or not _valid_name(item.initials)
		):
			return false
		if not previous.is_empty():
			if (
				int(item.level) > int(previous.level)
				or (
					int(item.level) == int(previous.level)
					and Rules._signed(int(item.power)) > Rules._signed(int(previous.power))
				)
			):
				return false
		previous = item
	return true


static func _integer(value: Variant, low: int, high: int) -> bool:
	return (
		(value is int or value is float)
		and is_finite(float(value))
		and float(value) == floor(float(value))
		and value >= low
		and value <= high
	)


static func _valid_name(name: String) -> bool:
	if name.length() > 3:
		return false
	for index: int in range(name.length()):
		var code := name.unicode_at(index)
		if code < 65 or code > 90:
			return false
	return true
