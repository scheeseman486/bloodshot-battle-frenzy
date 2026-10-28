class_name CdEnetTransport
extends Node
## Explicit ENet endpoint with DTLS on every socket. Certificate discovery has
## no application access; credentials require a second, strictly verified link.
signal connected(peer: int)
signal disconnected(peer: int)
signal failed(reason: String)
const Settings = preload("res://scripts/network/network_settings.gd")
const Auth = preload("res://scripts/network/network_auth.gd")
const CHANNELS := 5
const MAX_PACKET := 1000
const AUTH_CHANNEL := 6
const AUTH_MAX := 2048
const HANDSHAKE_MS := 10000
var peer: ENetConnection
var received: Array = []
var _connections: Dictionary = {}
var identities: Dictionary = {}
var bans := preload("res://scripts/network/player_bans.gd").new()
var admin_acl := preload("res://scripts/network/admin_acl.gd").new()
var purpose := "play"
var verified_servers: Dictionary = {} # Explicitly imported pins, distinct from ordinary TOFU.
var admin_enabled := false
var admin_secure := false
var _auth_window := {"at": 0, "count": 0}
var _pending: Dictionary = {}
var _native_ids: Dictionary = {}
var _next_id := 2
var _server := false
var _address := ""
var _port := 0
var _pin := ""
var _certificate_text := ""
var _restart := false
var _started := 0
var _attempts: Dictionary = {}
# Production supplies profile credentials; tests receive isolated ephemeral keys.
var identity_key: CryptoKey
var host_certificate: X509Certificate
var player_name := ""
var password := ""
var trusted_servers: Dictionary = {}
var trust_saved: Callable
static var _test_host_key: CryptoKey
static var _test_host_certificate: X509Certificate
var sent_bytes := 0
var received_bytes := 0
var largest_packet := 0
var last_error := ""
var rejected_channels := 0
var oversized_packets := 0
var largest_received_packet := 0


func supports_background_encoding() -> bool:
	return true


func listen(number: int, address: String = "127.0.0.1") -> bool:
	if peer != null or number < 0 or number > 65535: return false
	if not bans.load_list():
		last_error = bans.last_error
		return false
	admin_acl.reload() # Invalid ACL disables admin, but local recovery/gameplay remain.
	if host_certificate == null:
		if _test_host_key == null:
			_test_host_key = Crypto.new().generate_rsa(2048)
			_test_host_certificate = Settings.make_certificate(_test_host_key)
		identity_key = _test_host_key
		host_certificate = _test_host_certificate
	if identity_key == null or host_certificate == null: return false
	_certificate_text = Settings.certificate_text(host_certificate)
	if _certificate_text.is_empty(): return false
	_server = true
	peer = ENetConnection.new()
	var error := peer.create_host_bound(address, number, 8, CHANNELS + 2)
	admin_secure = hardened_engine(peer)
	if error == OK: error = peer.dtls_server_setup(TLSOptions.server(identity_key, host_certificate))
	return _opened(error)


func connect_to(address: String, number: int) -> bool:
	if peer != null or number < 1 or number > 65535 or not Settings.valid_name(player_name) or not Settings.valid_password(password): return false
	_address = address.to_lower().strip_edges()
	_port = number
	_pin = str(trusted_servers.get(_trust_address(), ""))
	admin_enabled = verified_servers.has(_trust_address()) and verified_servers[_trust_address()] == _pin and not _pin.is_empty()
	if not hardened_engine(ENetConnection.new()):
		admin_enabled = false
		if purpose == "manage":
			last_error = "Administration requires the hardened Bloodshot engine"
			return false
	if purpose not in ["play", "manage"] or (purpose == "manage" and not admin_enabled):
		last_error = "Administration requires an explicitly trusted server profile"
		return false
	if identity_key == null: identity_key = Crypto.new().generate_rsa(2048)
	_started = Time.get_ticks_msec()
	return _client_socket()


func _client_socket() -> bool:
	_server = false
	peer = ENetConnection.new()
	var error := peer.create_host(1, CHANNELS + 2)
	admin_secure = hardened_engine(peer)
	var options := TLSOptions.client_unsafe()  # Discovery ONLY. Never send credentials here.
	if not _pin.is_empty():
		var certificate := X509Certificate.new()
		if certificate.load_from_string(_pin) != OK:
			last_error = "Invalid saved server certificate"
			close()
			return false
		options = TLSOptions.client(certificate, "bloodshot")
	if error == OK: error = peer.dtls_client_setup("bloodshot", options)
	if not _opened(error): return false
	var remote := peer.connect_to_host(_address, _port, CHANNELS + 2)
	if remote == null:
		last_error = "Cannot connect encrypted endpoint"
		close()
		return false
	return true


func _opened(error: int) -> bool:
	if error == OK: return true
	last_error = "Encrypted endpoint failed: %s" % error_string(error)
	close()
	return false


func _trust_address() -> String:
	return "%s:%d" % [_address, _port]


func _raw_connected(remote: ENetPacketPeer) -> void:
	if remote.get_channels() < CHANNELS + 2:
		rejected_channels += 1
		remote.peer_disconnect_now()
		return
	var id := _next_id if _server else 1
	if _server: _next_id += 1
	_native_ids[remote.get_instance_id()] = id
	var nonce := Crypto.new().generate_random_bytes(32).hex_encode()
	_pending[id] = {"remote": remote, "nonce": nonce, "at": Time.get_ticks_msec(), "stage": "auth", "messages": 0}
	if _server:
		_raw_send(remote, {"type": "certificate", "certificate": _certificate_text, "nonce": nonce, "version": 2})


func _raw_send(remote: ENetPacketPeer, value: Dictionary) -> void:
	var bytes := JSON.stringify(value).to_utf8_buffer()
	if bytes.size() <= AUTH_MAX: remote.send(AUTH_CHANNEL, bytes, ENetPacketPeer.FLAG_RELIABLE)


func _authentication(id: int, bytes: PackedByteArray) -> void:
	if not _pending.has(id) or bytes.size() > AUTH_MAX: return
	var pending: Dictionary = _pending[id]
	pending.messages += 1
	if pending.messages > 16:
		disconnect_peer(id)
		return
	var message: Variant = preload("res://scripts/network/bounded_json.gd").decode(bytes, AUTH_MAX)
	if not message is Dictionary or not message.get("type") is String: return
	var row: Dictionary = _pending[id]
	var remote: ENetPacketPeer = row.remote
	if _server:
		if row.stage == "begin" and message == {"type": "begin"}:
			if bans.contains(str(identities.get(id, {}).get("key", ""))):
				reject_peer(id, "Player banned")
				return
			var principal: Dictionary = identities.get(id, {})
			if principal.get("purpose") == "manage" and (not admin_secure or not admin_acl.allows(principal.key)):
				reject_peer(id, "Join denied")
				return
			row.stage = "live"
			_connections[id] = remote
			connected.emit(id)
		elif row.stage == "auth":
			# Rate-limit before public-key parsing/verification. Discovery is cheap.
			for old_address: String in _attempts.keys():
				if Time.get_ticks_msec() - int(_attempts[old_address].at) >= 10000: _attempts.erase(old_address)
			var address := remote.get_remote_address()
			var window: Dictionary = _attempts.get(address, {"at": Time.get_ticks_msec(), "count": 0})
			if Time.get_ticks_msec() - int(window.at) >= 10000: window = {"at": Time.get_ticks_msec(), "count": 0}
			window.count += 1
			if _attempts.size() < 128 or _attempts.has(address): _attempts[address] = window
			var principal := {}
			var now := Time.get_ticks_msec()
			if now - int(_auth_window.at) >= 1000: _auth_window = {"at": now, "count": 0}
			_auth_window.count += 1
			if _attempts.has(address) and int(window.count) <= 16 and int(_auth_window.count) <= 8:
				principal = Auth.verify(message, row.nonce, _certificate_text, password, 2)
			if not principal.is_empty() and bans.contains(principal.key):
				reject_peer(id, "Player banned")
				return
			# One play and one management link per identity. Claimed purpose only
			# affects admission AFTER signed proof, password, ban and ACL checks.
			var duplicate := not principal.is_empty() and identities.values().any(func(value): return value.key == principal.key and value.purpose == principal.purpose)
			var management: bool = principal.get("purpose", "") == "manage"
			var count := identities.values().filter(func(value): return (value.purpose == "manage") == management).size()
			var allowed: bool = not management or (admin_secure and admin_acl.allows(principal.get("key", "")))
			if principal.is_empty() or duplicate or count >= (2 if management else 4) or not allowed:
				_raw_send(remote, {"type": "rejected", "reason": "Player already connected" if duplicate else "Join denied: password, identity or player limit"})
				row.stage = "rejected"
				remote.peer_disconnect_later()
				return
			identities[id] = principal
			row.stage = "begin"
			_raw_send(remote, {"type": "accepted"})
		return
	if message.get("type") == "certificate" and row.stage == "auth":
		if message.size() != 4 or not (message.get("version") is float or message.get("version") is int) or message.version != 2 or not message.get("certificate") is String or message.certificate.length() > 4096 or not message.get("nonce") is String or not preload("res://scripts/network/player_bans.gd").valid_key(message.nonce): return
		if _pin.is_empty():
			var certificate := X509Certificate.new()
			if certificate.load_from_string(message.certificate) != OK:
				_fatal("Invalid server certificate")
				return
			_pin = message.certificate
			_restart = true
			return  # Nothing private may leave the discovery connection.
		if message.certificate != _pin:
			_fatal("Server certificate changed")
			return
		_raw_send(remote, Auth.response(identity_key, message.nonce, _pin, player_name, password, purpose, admin_enabled))
		row.stage = "accepted"
	elif message == {"type": "accepted"} and row.stage == "accepted":
		if trusted_servers.size() >= 128 and not trusted_servers.has(_trust_address()):
			_fatal("Server trust list is full")
			return
		trusted_servers[_trust_address()] = _pin
		if trust_saved.is_valid() and not trust_saved.call():
			_fatal("Cannot save server certificate")
			return
		row.stage = "live"
		_connections[id] = remote
		_raw_send(remote, {"type": "begin"})
		connected.emit(id)
	elif message.get("type") == "rejected":
		var reason: String = {"Player already connected": "Player already connected", "Player banned": "You are banned from this host", "Player kicked": "You were kicked from this host"}.get(message.get("reason"), "Join denied: check password and available player slots")
		_fatal(reason)


func port() -> int:
	return peer.get_local_port() if peer != null else 0


func connection_status() -> int:
	if peer == null: return MultiplayerPeer.CONNECTION_DISCONNECTED
	return MultiplayerPeer.CONNECTION_CONNECTED if not _connections.is_empty() else MultiplayerPeer.CONNECTION_CONNECTING


func poll() -> void:
	if peer == null: return
	for budget: int in range(256):
		var event := peer.service(0)
		var kind: int = event[0]
		if kind == ENetConnection.EVENT_NONE: break
		if kind == ENetConnection.EVENT_ERROR:
			_fatal("Encrypted connection failed; the server certificate may have changed")
			return
		var remote: ENetPacketPeer = event[1]
		if kind == ENetConnection.EVENT_CONNECT:
			var rejected_before := rejected_channels
			_raw_connected(remote)
			if rejected_channels != rejected_before: return
		elif kind == ENetConnection.EVENT_DISCONNECT:
			var id := int(_native_ids.get(remote.get_instance_id(), 0))
			_native_ids.erase(remote.get_instance_id())
			_pending.erase(id)
			identities.erase(id)
			var was_live := _connections.has(id)
			_connections.erase(id)
			if was_live: disconnected.emit(id)
			if not _server:
				close()
				return
		elif kind == ENetConnection.EVENT_RECEIVE:
			var id := int(_native_ids.get(remote.get_instance_id(), 0))
			var channel: int = event[3]
			var bytes := remote.get_packet()
			largest_received_packet = maxi(largest_received_packet, bytes.size())
			if bytes.size() > (AUTH_MAX if channel == AUTH_CHANNEL else MAX_PACKET):
				oversized_packets += 1
				reject_peer(id, "Invalid packet size")
				continue
			if channel == AUTH_CHANNEL: _authentication(id, bytes)
			elif _connections.has(id) and channel <= CHANNELS:
				if _server and identities.get(id, {}).get("purpose") == "manage" and channel != 5: continue
				received_bytes += bytes.size()
				if bytes.size() <= MAX_PACKET and received.size() < 512:
					received.append({"peer": id, "channel": channel, "bytes": bytes})
		if peer == null: return
		if _restart:
			_restart = false
			close()
			if not _client_socket(): _fatal(last_error)
			return
	if peer == null: return
	var now := Time.get_ticks_msec()
	for id: int in _pending.keys():
		if _pending[id].stage != "live" and now - int(_pending[id].at) > HANDSHAKE_MS: disconnect_peer(id)
	if not _server and _connections.is_empty() and now - _started > HANDSHAKE_MS:
		_fatal("Encrypted join timed out; check address, password and server certificate")
	if peer != null: peer.flush()


func send_to(target: int, channel: int, bytes: PackedByteArray, reliable: bool) -> bool:
	if peer == null or bytes.size() > MAX_PACKET or channel < 0 or channel > CHANNELS: return false
	var destination: ENetPacketPeer = _connections.get(target)
	if destination == null or not destination.is_active() or destination.get_state() != ENetPacketPeer.STATE_CONNECTED: return false
	# Preserve the old MultiplayerPeer mode: unordered unreliable packets must
	# not discard older multipart chunks merely because another chunk arrived.
	var flags := ENetPacketPeer.FLAG_RELIABLE if reliable else (ENetPacketPeer.FLAG_UNSEQUENCED | ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT)
	if destination.send(channel, bytes, flags) != OK: return false
	peer.flush()  # Same immediate send policy as the previous MultiplayerPeer.
	sent_bytes += bytes.size()
	largest_packet = maxi(largest_packet, bytes.size())
	return true


func reject_peer(id: int, reason: String) -> void:
	var row: Dictionary = _pending.get(id, {})
	if row.is_empty(): return
	_raw_send(row.remote, {"type": "rejected", "reason": reason})
	row.stage = "rejected"
	identities.erase(id)
	var was_live := _connections.has(id)
	_connections.erase(id)
	row.remote.peer_disconnect_later()
	peer.flush()
	if was_live: disconnected.emit(id)


func disconnect_peer(id: int) -> void:
	var row: Dictionary = _pending.get(id, {})
	if row.is_empty(): return
	row.remote.peer_disconnect_now()
	_native_ids.erase(row.remote.get_instance_id())
	_pending.erase(id)
	identities.erase(id)
	var was_live := _connections.has(id)
	_connections.erase(id)
	if was_live: disconnected.emit(id)


func close() -> void:
	_dispose(true)


func _dispose(graceful: bool) -> void:
	if peer != null:
		if graceful:
			for remote: ENetPacketPeer in peer.get_peers():
				if remote.is_active(): remote.peer_disconnect_now()
			peer.flush()
		peer.destroy()
		peer = null
	received.clear()
	_connections.clear()
	_pending.clear()
	_native_ids.clear()
	identities.clear()


func _fatal(reason: String) -> void:
	last_error = reason
	_dispose(false)  # A failed TLS socket must never start another handshake on close.
	failed.emit(reason)


func latency_ms(id: int) -> int:
	var remote: ENetPacketPeer = _connections.get(id)
	if remote == null or not remote.is_active() or remote.get_state() != ENetPacketPeer.STATE_CONNECTED: return -1
	return clampi(roundi(remote.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)), 0, 60000)


## Host-local console metadata. Never included in public player snapshots.
func remote_endpoint(id: int) -> Dictionary:
	var remote: ENetPacketPeer = _connections.get(id)
	if remote == null or not remote.is_active(): return {}
	return {"address": remote.get_remote_address(), "port": remote.get_remote_port()}


func _exit_tree() -> void:
	close()


static func hardened_engine(connection: ENetConnection) -> bool:
	if not connection.has_method("get_security_limits"): return false
	var limits: Dictionary = connection.call("get_security_limits")
	return limits.get("version") == 1 and limits.get("packet") == AUTH_MAX and limits.get("waiting") == 262144 and limits.get("overhead") == 256 and limits.get("unreliable_guard", false) and limits.get("dtls_guard", false)
