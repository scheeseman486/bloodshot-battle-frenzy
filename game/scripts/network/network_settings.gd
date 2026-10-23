extends RefCounted
## Local preferences and private credentials. Never part of a game snapshot/save.
const PATH := "user://network.cfg"
const KEY_PATH := "user://network-private/player-identity.key"
const CERT_PATH := "user://network-private/host-certificate.crt"
const MAX_NAME := 16
static var player_name := ""
static var port := 28760
static var password := ""  # Deliberately memory-only, including joining passwords.
static var pins: Dictionary = {}
static var identity: CryptoKey
static var certificate: X509Certificate
static var loaded := false
static var last_error := ""


static func valid_name(value: Variant) -> bool:
	if not value is String or value.length() > MAX_NAME or value != value.strip_edges(): return false
	for index: int in range(value.length()):
		var code: int = value.unicode_at(index)
		if code < 32 or code > 126: return false
	return true


static func valid_password(value: String) -> bool:
	if value.length() > 64: return false
	for code: int in value.to_utf32_buffer().to_int32_array():
		if code < 32 or code > 126: return false
	return true


static func load_profile() -> bool:
	if loaded: return identity != null and certificate != null
	loaded = true
	if OS.has_environment("BLOODSHOT_NETWORK_PASSWORD"):
		password = OS.get_environment("BLOODSHOT_NETWORK_PASSWORD")
		if not valid_password(password):
			last_error = "Network password must use up to 64 printable characters"
			return false
	var config := ConfigFile.new()
	if config.load(PATH) == OK:
		var name: Variant = config.get_value("network", "name", "")
		if valid_name(name): player_name = name
		var number: Variant = config.get_value("network", "port", 28760)
		if number is int and number >= 1 and number <= 65535: port = number
		var saved: Variant = config.get_value("network", "pins", {})
		if saved is Dictionary and saved.size() <= 128:
			for address: Variant in saved:
				if address is String and address.length() <= 260 and saved[address] is String and saved[address].length() <= 4096:
					pins[address] = saved[address]
	var directory := ProjectSettings.globalize_path("user://network-private")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		last_error = "Cannot create private player profile"
		return false
	if OS.has_feature("linux") or OS.has_feature("macos"):
		if FileAccess.set_unix_permissions(directory, 448) != OK: # 0700
			last_error = "Cannot protect private player profile"
			return false
	identity = CryptoKey.new()
	if FileAccess.file_exists(KEY_PATH):
		if identity.load(KEY_PATH) != OK or identity.is_public_only():
			last_error = "Cannot read private player identity"
			identity = null
			return false
	else:
		identity = Crypto.new().generate_rsa(2048)
		if identity == null or identity.save(KEY_PATH) != OK:
			last_error = "Cannot save private player identity"
			identity = null
			return false
	# Key ownership relies on the local profile's filesystem permissions.
	if OS.has_feature("linux") or OS.has_feature("macos"):
		if FileAccess.set_unix_permissions(KEY_PATH, 384) != OK:
			last_error = "Cannot protect private player identity"
			identity = null
			return false
	certificate = X509Certificate.new()
	if FileAccess.file_exists(CERT_PATH):
		if certificate.load(CERT_PATH) != OK:
			last_error = "Cannot read host certificate"
			certificate = null
			return false
	else:
		certificate = make_certificate(identity)
		if certificate == null or certificate.save(CERT_PATH) != OK:
			last_error = "Cannot save host certificate"
			certificate = null
			return false
	return true


static func make_certificate(key: CryptoKey) -> X509Certificate:
	return Crypto.new().generate_self_signed_certificate(key, "CN=bloodshot", "20260101000000", "20460101000000")


static func certificate_text(value: X509Certificate) -> String:
	# Godot 4.7's save_to_string includes the PEM NUL in its ASCII span.
	# The file API excludes that terminator; keep this public-only workaround
	# outside packet loops and never write a private key for serialization.
	var path := "user://.public-certificate-%d.tmp" % value.get_instance_id()
	if value.save(path) != OK: return ""
	var result := FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	return result


static func save() -> bool:
	var config := ConfigFile.new()
	config.set_value("network", "name", player_name)
	config.set_value("network", "port", port)
	config.set_value("network", "pins", pins)
	if config.save(PATH + ".tmp") != OK: return false
	return DirAccess.rename_absolute(PATH + ".tmp", PATH) == OK


static func configure(transport: Node) -> bool:
	if not load_profile(): return false
	transport.bans.path = "user://network-private/player-bans.json"
	transport.identity_key = identity
	transport.host_certificate = certificate
	transport.player_name = player_name
	transport.password = password
	transport.trusted_servers = pins
	transport.trust_saved = save
	return true
