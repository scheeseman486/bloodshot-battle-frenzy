extends RefCounted
## Pure decisions over permitted observations and the bot's private memory.
const REACTION := [500000, 300000, 180000]
const MEMORY := [2000000, 3000000, 4000000]
const TURN := [4096.0, 6371.5555556, 8192.0]


static func random(row: Dictionary) -> int:
	row.seed = (int(row.seed) * 1664525 + 1013904223) & 0xffffffff
	return row.seed


static func decide(
	row: Dictionary, view: Dictionary, now: int, difficulty: int, coop: bool
) -> Dictionary:
	var level := 1 if coop else difficulty
	var here: Vector2i = view.position
	var previous_visible: Array = (
		row
		. memory
		. filter(func(old): return old.visible)
		. map(func(old): return [old.id, old.generation])
	)
	# Refresh only visible targets; absence never updates a remembered position.
	for old: Dictionary in row.memory:
		old.visible = false
	for target: Dictionary in view.targets:
		var found: int = row.memory.find_custom(
			func(old): return old.id == target.id and old.generation == target.generation
		)
		if found < 0:
			if row.memory.size() >= 32:
				row.memory.pop_front()
			row.memory.append(
				{
					"id": target.id,
					"generation": target.generation,
					"point": target.point,
					"seen": now,
					"ready": now + REACTION[level] + random(row) % 100001,
					"visible": true
				}
			)
		else:
			var old: Dictionary = row.memory[found]
			if [old.id, old.generation] not in previous_visible:
				old.ready = now + REACTION[level] + random(row) % 100001
			old.point = target.point
			old.seen = now
			old.visible = true
	row.memory = row.memory.filter(func(old): return now - int(old.seen) <= MEMORY[level])
	row.cues = row.cues.filter(func(cue): return now - int(cue.at) <= 1500000)
	var target := {}
	var best := INF
	for candidate: Dictionary in row.memory:
		var score := Vector2(here).distance_squared_to(Vector2(candidate.point))
		if candidate.id==row.focus_id and candidate.generation==row.focus_generation: score*=0.65
		if not candidate.visible:
			score += 10000000.0
		if score < best:
			best = score
			target = candidate
	var goal: Vector2i = row.goal
	var fire := false
	var strafe := 0
	if not target.is_empty():
		goal = target.point
		fire = target.visible and now >= int(target.ready)
		if target.visible and Vector2(here).distance_squared_to(Vector2(goal)) < 1400.0 * 1400.0:
			if level > 0 or int(now / 1000000) % 3 == 0:
				strafe = -1 if int(now / 1800000 + row.reference.id) % 2 == 0 else 1
	elif coop and not view.friends.is_empty():
		var friend: Dictionary = view.friends[0]
		var heading := float(friend.get("angle", 0)) * TAU / 16384.0
		var forward := Vector2(sin(heading), cos(heading))
		var side := float(clampi(int(view.get("seat", 1)) - 1, 0, 2) - 1) * 220.0
		goal = friend.point + Vector2i(-forward * 420.0 + forward.orthogonal() * side)
		if view.escape and view.exit != here:
			goal = view.exit
		elif Vector2(here).distance_to(Vector2(friend.point)) < 240:
			# Back away/yield when a human reverses into the companion.
			goal = here + (here - Vector2i(friend.point)).sign() * 256
		elif Vector2(here).distance_to(Vector2(goal)) < 180:
			goal = here
	elif not row.cues.is_empty():
		var cue: Dictionary = row.cues.back()
		goal = here + Vector2i(Vector2.from_angle(float(cue.bearing) * TAU / 8.0) * float(cue.band))
	if (
		coop
		and not view.friends.is_empty()
		and Vector2(here).distance_to(Vector2(view.friends[0].point)) > 1100
	):
		goal = view.friends[0].point
		fire = false
	# Visible supplies and remembered observed map weapons; never live hidden timers.
	if not coop:
		for item: Dictionary in view.items:
			var at: int = row.items.find_custom(func(old): return old.id == item.id)
			var present: bool = item.get("present", true)
			var due: int = 0 if present else now + 60000000
			if at >= 0 and not present and int(row.items[at].due) > now:
				due = row.items[at].due
			var remembered := {
				"id": item.id, "point": item.point, "kind": item.kind, "seen": now, "due": due
			}
			if at < 0:
				if row.items.size() >= 32:
					row.items.pop_front()
				row.items.append(remembered)
			else:
				row.items[at] = remembered
		row.items = row.items.filter(func(item): return now - int(item.seen) < 60000000)
		for item: Dictionary in row.items:
			var need: bool = (
				(int(item.kind) == 43 and view.health < 70)
				or (int(item.kind) in range(29, 39) and view.selected < 0)
			)
			if (
				need
				and now >= int(item.due)
				and (target.is_empty() or (level > 0 and view.health < 40))
			):
				goal = item.point
				break
	# Friendly lane safety includes unseen teammates; team position is allowed knowledge.
	if coop and fire:
		for friend: Dictionary in view.friends:
			var near := Geometry2D.get_closest_point_to_segment(
				Vector2(friend.point), Vector2(here), Vector2(goal)
			)
			if near.distance_to(Vector2(friend.point)) < 140:
				fire = false
	for hazard: Vector2i in view.hazards:
		if hazard not in row.hazards:
			if row.hazards.size()>=32: row.hazards.pop_front()
			row.hazards.append(hazard)
	for hazard: Vector2i in row.hazards:
		if (
			(
				Geometry2D
				. get_closest_point_to_segment(Vector2(hazard), Vector2(here), Vector2(goal))
				. distance_to(Vector2(hazard))
			)
			< 180
		):
			goal = here + Vector2i((Vector2(goal - here).orthogonal().normalized() * 320).round())
			break
	if level == 2:
		for projectile: Vector2i in view.projectiles:
			if Vector2(projectile).distance_to(Vector2(here)) < 400:
				strafe = 1 if (random(row) & 1) == 0 else -1
	row.focus_id = int(target.get("id", -1))
	row.focus_generation = int(target.get("generation", 0))
	row.goal = goal
	row.fire = fire
	row.strafe = strafe
	row.cycle=false
	if int(view.selected)>=0 or view.inventory.any(func(weapon): return int(weapon.kind)!=0 and int(weapon.ammo)>0):
		var preferred: int = -1
		var quality := -INF
		for slot: int in range(view.inventory.size()):
			var weapon: Dictionary = view.inventory[slot]
			if int(weapon.kind)==0 or int(weapon.ammo)<=0: continue
			var score := float(weapon.ammo)
			if int(weapon.kind)==2 and not target.is_empty() and Vector2(here).distance_to(Vector2(target.point))>1000: score+=0x150000
			if slot==int(view.selected): score*=1.1
			if score>quality:
				quality=score
				preferred=slot
		row.cycle=preferred!=int(view.selected)
	# Slowly varying error, independent of the render clock.
	if now >= int(row.error_at):
		row.error = (
			(float(random(row) % 20001) / 10000.0 - 1.0) * [4.0, 2.0, 1.0][level] * 16384.0 / 360.0
		)
		row.error_at = now + 400000
	return {"goal": goal, "fire": fire, "strafe": strafe, "turn_limit": TURN[level]}
