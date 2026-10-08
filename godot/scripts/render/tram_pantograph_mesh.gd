extends RefCounted
class_name TramPantographMesh


static func append_surfaces(mesh: ArrayMesh) -> void:
	var frame := SurfaceTool.new()
	frame.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pan_x := -7.0
	var roof_y := 4.5
	var lower_left := Vector2(pan_x - 1.5, roof_y)
	var lower_right := Vector2(pan_x + 1.5, roof_y)
	var upper_left := Vector2(pan_x - 0.45, roof_y + 0.72)
	var upper_right := Vector2(pan_x + 0.40, roof_y + 1.16)
	var head_left := Vector2(pan_x - 1.25, roof_y + 1.36)
	var head_right := Vector2(pan_x + 1.25, roof_y + 1.36)
	_append_member(frame, lower_left, upper_right, 0.18)
	_append_member(frame, lower_right, upper_left, 0.18)
	_append_member(frame, upper_left, head_left, 0.14)
	_append_member(frame, upper_right, head_right, 0.14)
	_append_member(frame, lower_left, lower_right, 0.16)
	_append_member(frame, upper_left, upper_right, 0.12)
	frame.generate_normals()
	frame.commit(mesh)

	var collector := SurfaceTool.new()
	collector.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bar := BoxMesh.new()
	bar.size = Vector3(2.9, 0.14, 0.25)
	collector.append_from(
		bar,
		0,
		Transform3D(Basis.IDENTITY, Vector3(pan_x, roof_y + 1.47, 0.0))
	)
	collector.generate_normals()
	collector.commit(mesh)


static func _append_member(
	surface: SurfaceTool,
	start: Vector2,
	finish: Vector2,
	thickness: float
) -> void:
	var direction := finish - start
	var length := direction.length()
	if length <= 0.000001:
		return
	var member := BoxMesh.new()
	member.size = Vector3(length, thickness, 0.16)
	var rotation := Basis(Vector3.BACK, direction.angle())
	var center := (start + finish) * 0.5
	surface.append_from(
		member,
		0,
		Transform3D(rotation, Vector3(center.x, center.y, 0.0))
	)
