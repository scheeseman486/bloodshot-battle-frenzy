class_name CdControllerLatch
extends RefCounted
## Input windows cross interrupt/gameplay boundaries, sub-CPU $030C66/$035EDE.
var state := {"held": 0xffffffff, "edge": 0xffffffff, "previous": 0xffffffff}

func sample(held: int) -> int:
	held &= 0xffffffff
	var edge := (held | ~int(state.previous)) & 0xffffffff
	state.held = int(state.held) & held
	state.edge = int(state.edge) & edge
	state.previous = held
	return edge


func consume() -> Dictionary:
	var result := {"held": state.held, "edge": state.edge}
	state.held = 0xffffffff
	state.edge = 0xffffffff
	return result
