class_name MdAudioCatalog
extends RefCounted
## Optional cartridge presentation; all resources derive from immutable media in
## memory. The canonical CD events and network payloads never contain preferences.
const ROM_SHA := "e47e35f9e4bb4e42998b814e81dd91d8a5b2941496a989cab3b7afd27ea2667b"
const RATE := 53203424.0 / 7.0 / 144.0
const VARIANTS := [1,1,2,2,3,4,5,5,6,7,7,8,9,10,11,12]
# Direct roles and the paired edition weapon/actor data. Shared laser4/roar4 stay CD
# until activation versus projectile roles can be distinguished without guessing.
const EFFECTS := {
	0xcdee:1, 0xdc92:2, 0xed52:3, 0x10122:-1, 0x10d18:5,
	0x119d0:6, 0x12aa4:7, 0x139e6:8, 0x14420:9, 0x153d8:10,
	0x1647a:16, 0x17c8c:11, 0x18700:0,
	0x19d60:17, 0x1a6ca:18, 0x1b144:19, 0x1bbb0:-1,
	0x1c5d6:13, 0x1cc3a:14, 0x1d406:23, 0x1daee:24, 0x1e424:25, 0x1edde:26,
	0x1f72a:12, 0x20b5e:35, 0x21272:32, 0x21c9a:31,
	0x229dc:37, 0x2322c:38, 0x24d64:21, 0x2547e:22,
	0x2572c:27, 0x27392:28, 0x28390:15, 0x2873c:33, 0x29bba:30, 0x2a544:29
}
var bytes := PackedByteArray()
var streams: Dictionary = {}
var error := ""
var prepare_usec := 0
var pcm_bytes := 0

func load_rom(path: String) -> bool:
	bytes.clear()
	streams.clear()
	error=""
	pcm_bytes=0
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null or file.get_length() != 2097152:
		error="Select the original European Bloodshot Mega Drive ROM."
		return false
	var candidate := file.get_buffer(file.get_length())
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(candidate)
	if hash.finish().hex_encode() != ROM_SHA:
		error="This cartridge version is not supported. Select the European Bloodshot ROM."
		return false
	bytes=candidate
	return true

func prepare() -> bool:
	pcm_bytes=0
	var started := Time.get_ticks_usec()
	if not ClassDB.class_exists("BloodshotGemsStream"):
		error="The cartridge audio module is unavailable. CD audio is active."
		return false
	var renderer: AudioStream = ClassDB.instantiate("BloodshotGemsStream")
	if not renderer.call("configure",bytes,1):
		error="Could not read the cartridge audio banks."
		return false
	var candidate := {}
	for sequence: int in EFFECTS.values():
		if sequence < 0 or candidate.has(sequence): continue
		var pcm: PackedByteArray = renderer.call("render_effect",sequence)
		if pcm.is_empty():
			error="Could not prepare cartridge sound %d. CD audio is active." % sequence
			return false
		var stream := AudioStreamWAV.new()
		stream.format=AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate=roundi(RATE)
		stream.data=pcm
		candidate[sequence]=stream
		pcm_bytes+=pcm.size()
	streams=candidate
	prepare_usec=Time.get_ticks_usec()-started
	return true

func effect(source_id: int) -> AudioStream:
	return streams.get(EFFECTS.get(source_id,-1))

func ambient(level: int) -> AudioStream:
	if bytes.is_empty(): return null
	var stream: AudioStream = ClassDB.instantiate("BloodshotGemsStream")
	var variant: int = VARIANTS[level-1] if level >= 1 and level <= 16 else 1
	return stream if stream.call("configure",bytes,variant) else null


func frontend(track: int) -> AudioStream:
	if bytes.is_empty() or track not in [2, 3]:
		return null
	var stream: AudioStream = ClassDB.instantiate("BloodshotGemsStream")
	return stream if stream.call("configure_frontend", bytes, track == 2) else null
