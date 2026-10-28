extends RefCounted
## Fresh challenge proof, only exchanged over a certificate-verified DTLS link.
## Names are cosmetic; ownership is the canonical public-key fingerprint.
const Settings = preload("res://scripts/network/network_settings.gd")


static func digest(bytes: PackedByteArray) -> PackedByteArray:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		hash.update(bytes)
	return hash.finish()


static func fingerprint(key: CryptoKey) -> String:
	return digest(key.save_to_string(true).to_utf8_buffer()).hex_encode()


static func transcript(
	nonce: String,
	certificate: String,
	name: String,
	proof: String,
	purpose: String = "",
	admin: bool = false
) -> PackedByteArray:
	if not purpose.is_empty():
		return digest(
			(
				(
					"bloodshot-auth-v2\n"
					+ purpose
					+ "\n"
					+ str(int(admin))
					+ "\n"
					+ nonce
					+ "\n"
					+ certificate.sha256_text()
					+ "\n"
					+ name
					+ "\n"
					+ proof
				)
				. to_utf8_buffer()
			)
		)
	return digest(
		(
			(
				"bloodshot-auth-v1\n"
				+ nonce
				+ "\n"
				+ certificate.sha256_text()
				+ "\n"
				+ name
				+ "\n"
				+ proof
			)
			. to_utf8_buffer()
		)
	)


static func response(
	key: CryptoKey,
	nonce: String,
	certificate: String,
	name: String,
	password: String,
	purpose: String = "",
	admin: bool = false
) -> Dictionary:
	var crypto := Crypto.new()
	var proof := (
		crypto
		. hmac_digest(
			HashingContext.HASH_SHA256, digest(password.to_utf8_buffer()), nonce.to_utf8_buffer()
		)
		. hex_encode()
	)
	var result := {
		"type": "auth",
		"name": name,
		"key": key.save_to_string(true),
		"proof": proof,
		"signature":
		Marshalls.raw_to_base64(
			crypto.sign(
				HashingContext.HASH_SHA256,
				transcript(nonce, certificate, name, proof, purpose, admin),
				key
			)
		)
	}
	if not purpose.is_empty():
		result.merge({"version": 2, "purpose": purpose, "admin": admin})
	return result


static func verify(
	message: Dictionary, nonce: String, certificate: String, password: String, version: int = 1
) -> Dictionary:
	var purpose := ""
	var admin := false
	if version == 2:
		if (
			message.size() != 8
			or not message.get("version") is float and not message.get("version") is int
		):
			return {}
		if (
			message.version != 2
			or not message.get("purpose") is String
			or message.purpose not in ["play", "manage"]
			or not message.get("admin") is bool
		):
			return {}
		purpose = message.purpose
		admin = message.admin
		if purpose == "manage" and not admin:
			return {}
	elif version != 1 or message.size() != 5:
		return {}
	if not message.has_all(["type", "name", "key", "proof", "signature"]):
		return {}
	if (
		not message.type is String
		or message.type != "auth"
		or not Settings.valid_name(message.name)
	):
		return {}
	if (
		not message.key is String
		or message.key.length() > 500
		or not message.proof is String
		or message.proof.length() != 64
	):
		return {}
	if not message.signature is String or message.signature.length() != 344:
		return {}
	for index: int in range(message.proof.length()):
		if "0123456789abcdef".find(message.proof[index]) < 0:
			return {}
	var crypto := Crypto.new()
	var expected := (
		crypto
		. hmac_digest(
			HashingContext.HASH_SHA256, digest(password.to_utf8_buffer()), nonce.to_utf8_buffer()
		)
		. hex_encode()
	)
	if not crypto.constant_time_compare(
		expected.to_ascii_buffer(), message.proof.to_ascii_buffer()
	):
		return {}
	var public_key := public_key_from_pem(message.key)
	if public_key == null:
		return {}
	if not valid_base64(message.signature):
		return {}
	var signature := Marshalls.base64_to_raw(message.signature)
	if (
		signature.size() != 256
		or not crypto.verify(
			HashingContext.HASH_SHA256,
			transcript(nonce, certificate, message.name, message.proof, purpose, admin),
			signature,
			public_key
		)
	):
		return {}
	var result := {"key": fingerprint(public_key), "name": message.name}
	if version == 2:
		result.merge({"purpose": purpose, "admin": admin})
	return result


static func valid_base64(text: String) -> bool:
	if text.is_empty() or text.length() % 4 != 0:
		return false
	var padding := 2 if text.ends_with("==") else (1 if text.ends_with("=") else 0)
	var alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var count := text.length() - padding
	for index: int in range(count):
		if alphabet.find(text[index]) < 0:
			return false
	# Canonical padding also prevents a malformed body reaching the decoder.
	var last := alphabet.find(text[count - 1])
	return not ((padding == 2 and (last & 15) != 0) or (padding == 1 and (last & 3) != 0))


static func public_key_from_pem(text: String) -> CryptoKey:
	# Only the RSA-2048/SPKI/65537 keys this client generates are supported.
	# Validate its bounded DER structure before asking the engine parser, whose
	# malformed-key errors would otherwise let hostile clients flood the log.
	if (
		not text.begins_with("-----BEGIN PUBLIC KEY-----\n")
		or not text.ends_with("-----END PUBLIC KEY-----\n")
	):
		return null
	var body := (
		text
		. trim_prefix("-----BEGIN PUBLIC KEY-----\n")
		. trim_suffix("-----END PUBLIC KEY-----\n")
		. replace("\n", "")
	)
	if body.length() != 392 or not valid_base64(body):
		return null
	var der := Marshalls.base64_to_raw(body)
	if (
		der.size() != 294
		or (
			der.slice(0, 33).hex_encode()
			!= "30820122300d06092a864886f70d01010105000382010f003082010a0282010100"
		)
		or der.slice(289).hex_encode() != "0203010001"
	):
		return null
	if der[33] < 128 or (der[288] & 1) == 0:
		return null
	var result := CryptoKey.new()
	return result if result.load_from_string(text, true) == OK else null
