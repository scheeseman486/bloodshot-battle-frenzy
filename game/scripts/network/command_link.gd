extends RefCounted
## Client-side bounded redundant queue. Each mouse event is quantized once here;
## packets carry fixed integers, never an untrusted simulation duration/PlayerRef.
var endpoint: WeakRef


func submit(controls: Dictionary, rate: float, aim: Array) -> bool:
	var owner: Node = endpoint.get_ref()
	return owner != null and owner.submit(controls, rate, aim)
