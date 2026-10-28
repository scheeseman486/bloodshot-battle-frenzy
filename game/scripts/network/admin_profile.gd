extends RefCounted
## Public connection profiles are explicit trust decisions, never admin grants.
const Settings = preload("res://scripts/network/network_settings.gd")
const Auth = preload("res://scripts/network/network_auth.gd")
const MAX_BYTES := 6144
var last_error := ""


static func valid_host(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 253 or value != value.to_lower():
		return false
	if value.is_valid_ip_address():
		return true
	for label: String in value.split("."):
		if (
			label.is_empty()
			or label.length() > 63
			or label.begins_with("-")
			or label.ends_with("-")
		):
			return false
		for code: int in label.to_utf32_buffer().to_int32_array():
			if not (code in range(97, 123) or code in range(48, 58) or code == 45):
				return false
	return true


static func endpoint(value: Dictionary) -> String:
	return "%s:%d" % [value.host, int(value.port)]


func read_file(path: String) -> Dictionary:
	last_error = "Invalid public server profile"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES:
		return {}
	var bytes := file.get_buffer(file.get_length())
	var value: Variant = preload("res://scripts/network/bounded_json.gd").decode(
		bytes, MAX_BYTES, 6, true
	)
	if (
		not value is Dictionary
		or value.size() != 4
		or not value.has_all(["version", "host", "port", "certificate"])
	):
		return {}
	if (
		not (value.version is int or value.version is float)
		or value.version != 1
		or not valid_host(value.host)
		or not preload("res://scripts/network/admin_protocol.gd").whole(value.port, 1, 65535)
	):
		return {}
	if (
		not value.certificate is String
		or value.certificate.length() > 4096
		or not value.certificate.begins_with("-----BEGIN CERTIFICATE-----\n")
		or not value.certificate.ends_with("-----END CERTIFICATE-----\n")
	):
		return {}
	var body: String = (
		value
		. certificate
		. trim_prefix("-----BEGIN CERTIFICATE-----\n")
		. trim_suffix("-----END CERTIFICATE-----\n")
		. replace("\n", "")
	)
	if not Auth.valid_base64(body):
		return {}
	var der := Marshalls.base64_to_raw(body)
	# Exact bounded outer DER sequence before passing bytes to the vetted parser.
	if (
		der.size() < 256
		or der.size() > 2048
		or der[0] != 0x30
		or der[1] != 0x82
		or der[2] * 256 + der[3] != der.size() - 4
	):
		return {}
	var certificate := X509Certificate.new()
	if certificate.load_from_string(value.certificate) != OK:
		return {}
	last_error = ""
	return value


func install(value: Dictionary) -> bool:
	# Call only after an explicit local confirmation showing the certificate hash.
	var address := endpoint(value)
	if Settings.pins.size() >= 128 and not Settings.pins.has(address):
		last_error = "Server trust list is full"
		return false
	var old_pins := Settings.pins.duplicate()
	var old_admin := Settings.admin_pins.duplicate()
	Settings.pins[address] = value.certificate
	Settings.admin_pins[address] = value.certificate
	if Settings.save():
		return true
	Settings.pins.clear()
	Settings.pins.merge(old_pins)
	Settings.admin_pins.clear()
	Settings.admin_pins.merge(old_admin)
	last_error = "Could not save trusted server profile"
	return false


static func export_server(transport: Node, host: String) -> bool:
	if not valid_host(host) or transport._certificate_text.is_empty():
		return false
	var value := {
		"version": 1,
		"host": host,
		"port": transport.port(),
		"certificate": transport._certificate_text
	}
	var file := FileAccess.open("user://server-profile.json.tmp", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "\t") + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	return (
		error == OK
		and (
			DirAccess.rename_absolute(
				"user://server-profile.json.tmp", "user://server-profile.json"
			)
			== OK
		)
	)
