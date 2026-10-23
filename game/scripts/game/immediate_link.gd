class_name CdImmediateLink
extends RefCounted
## Local transport endpoint. Credentials live on the authority, not in submitted
## commands. All payloads are copied; no sockets or delivery timers are involved.
var _authority: WeakRef
var _endpoint := 0
var _sequence := 0


func submit(controls: Dictionary, rate: float, aim: Array) -> bool:
	var server: RefCounted = _authority.get_ref()
	if server == null:
		return false
	var next := _sequence + 1
	if not server.receive_command(_endpoint, next, controls.duplicate(true), rate, aim.duplicate()):
		return false
	_sequence = next
	return true
