extends RefCounted
## $367EC consumes the contiguous wall range retained by the preceding view.
## Occluded walls inside that range remain eligible; there is no extra ray test.
var session: RefCounted


func visible(index: int) -> bool:
	var span: Array = session.actor_visibility.door_range()
	return index >= int(span[0]) and index <= int(span[1])
