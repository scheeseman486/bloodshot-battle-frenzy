class_name CdActorPool
extends RefCounted


## Ascending first-empty allocation, source $0335A4. The original pool has 180
## usable records; vacant trailing slots need not be materialized in Godot.
static func allocate(actors: Array, empty: Callable) -> int:
	for index: int in range(actors.size()):
		if int(actors[index].kind) == 0:
			return index
	if actors.size() >= 180:
		return -1
	actors.append(empty.call())
	return actors.size() - 1
