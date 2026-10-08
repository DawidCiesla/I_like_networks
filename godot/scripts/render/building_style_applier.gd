extends Node3D

var tint := Color.WHITE

func _ready() -> void:
	var local_materials: Dictionary = {}
	_apply_node_style(self, local_materials)

func _apply_node_style(node: Node, local_materials: Dictionary) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.material_override is StandardMaterial3D:
			mesh_instance.material_override = _local_tinted_material(
				mesh_instance.material_override as StandardMaterial3D,
				local_materials
			)
		elif mesh_instance.mesh != null:
			for surface_index in range(mesh_instance.mesh.get_surface_count()):
				var active_material := mesh_instance.get_active_material(surface_index)
				if active_material is StandardMaterial3D:
					mesh_instance.set_surface_override_material(
						surface_index,
						_local_tinted_material(active_material as StandardMaterial3D, local_materials)
					)
	for child in node.get_children():
		_apply_node_style(child, local_materials)

func _local_tinted_material(source: StandardMaterial3D, local_materials: Dictionary) -> StandardMaterial3D:
	var source_id := source.get_instance_id()
	if local_materials.has(source_id):
		return local_materials[source_id] as StandardMaterial3D
	# Shallow duplication preserves shared PBR textures while isolating editable
	# material properties to this one building instance.
	var local_material := source.duplicate() as StandardMaterial3D
	if local_material == null:
		return source
	var base := source.albedo_color
	local_material.albedo_color = Color(
		base.r * tint.r,
		base.g * tint.g,
		base.b * tint.b,
		base.a
	)
	local_materials[source_id] = local_material
	return local_material
