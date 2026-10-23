class_name CdProjectileFactory
extends RefCounted


## Projectile initialization $039718..$039816. Caller owns original pool order.
static func create(
	before: Dictionary, arguments: Dictionary, weapon: Dictionary, context: Dictionary
) -> Dictionary:
	var result := before.duplicate(true)
	result.x = int(arguments.x)
	result.y = int(arguments.y)
	var speed := _word(int(arguments.speed_offset) + int(weapon.speed))
	result.vx = _word(_divide(int(arguments.dx) * speed, 16384))
	result.vy = _word(_divide(int(arguments.dy) * speed, 16384))
	var damage := int(weapon.damage)
	if int(arguments.owner) == -2 or int(arguments.owner) == -3:
		if int(context.demo_flag) == 0 and int(context.control_scheme) != 1:
			var scratch := (int(arguments.get("scratch7", 0)) & 0xffff0000) | (damage & 65535)
			if scratch >= 0x80000000:
				scratch -= 0x100000000
			damage = _word(scratch + (scratch >> 2))
		var quarter := _divide(int(weapon.damage), 4)
		damage = _word(damage - quarter)
		for index: int in range(int(context.targeting_owner)):
			damage = _word(damage + quarter)
		damage = maxi(damage, int(weapon.damage))
		if int(context.resolution) == 2 and int(context.multiplayer) == 0:
			damage = _word(damage - _divide(damage, 4))
	elif int(context.resolution) == 2 and int(context.multiplayer) == 0:
		damage = _word(damage + _divide(damage, 4))
	result.damage = damage
	result.age = 0
	result.owner = arguments.owner
	result.wall_cursor = arguments.wall_cursor
	result.frame = weapon.frame_address
	result.height = arguments.height
	result.gravity = -6
	result.kind = weapon.projectile_kind
	return result


static func _divide(value: int, divisor: int) -> int:
	@warning_ignore("integer_division")
	return value / divisor


static func _word(value: int) -> int:
	return ((value + 32768) & 65535) - 32768
