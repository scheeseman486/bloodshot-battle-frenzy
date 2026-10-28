class_name SharpBilinearUi
extends RefCounted
## Scope the shared RGBA material to UI trees. Keep native Control transforms,
## input/focus and explicit indexed/procedural materials in their original owners.
const MATERIAL := preload("res://resources/ui/sharp_bilinear.tres")


static func apply(root: Node) -> void:
	if root is CanvasItem and root.material == null and not root.use_parent_material:
		root.material = MATERIAL
	if root is HSlider:
		# Source rails tile horizontally; boundary taps must read the next tile.
		root.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# Dynamic binding rows, text fields, tally entries and popups follow the same
	# policy. Per-node signals disappear with the UI; no scene-tree/global hooks.
	if not root.child_entered_tree.is_connected(apply):
		root.child_entered_tree.connect(apply)
	for child: Node in root.get_children():
		apply(child)
