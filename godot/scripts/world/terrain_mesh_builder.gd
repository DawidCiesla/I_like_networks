extends RefCounted

const Sampler = preload("res://scripts/world/terrain_sampler.gd")
const EditData = preload("res://scripts/world/terrain_edit_data.gd")
const MAX_WORKERS := 4
const MAIN_THREAD_SLICE_USEC := 2500

var _jobs: Array = []
var _tasks: Array[int] = []
var worker_count := 0
var _cancelled := false


class RowJob extends RefCounted:
	var seed: int
	var bounds: Rect2
	var steps: Vector2i
	var first_row: int
	var last_row: int
	var regional: bool
	var edit_payload: Dictionary
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()
	var _sampler: RefCounted
	var _edits: RefCounted
	var _mutex := Mutex.new()
	var _progress := 0.0
	var _cancelled := false

	func cancel() -> void:
		_mutex.lock()
		_cancelled = true
		_mutex.unlock()

	func progress() -> float:
		_mutex.lock()
		var value := _progress
		_mutex.unlock()
		return value

	func run() -> void:
		# Every task owns its sampler and edits. No shared TerrainModel caches,
		# active map, scene nodes, or rendering resources are touched here.
		_sampler = Sampler.new()
		if int(edit_payload.get("seed", 0)) == seed:
			var imported := EditData.from_dict(edit_payload)
			if bool(imported.get("ok", false)):
				_edits = imported["data"]
		var stride := steps.x + 1
		var count := (last_row - first_row) * stride
		vertices.resize(count)
		colors.resize(count)
		uv2.resize(count)
		for row in range(first_row, last_row):
			_mutex.lock()
			var cancelled := _cancelled
			_mutex.unlock()
			if cancelled:
				return
			var z := bounds.position.y + bounds.size.y * float(row) / float(steps.y)
			for column in range(stride):
				var x := bounds.position.x + bounds.size.x * float(column) / float(steps.x)
				var index := (row - first_row) * stride + column
				var sample: Dictionary = _sampler.call("regional_surface_sample", seed, x, z) if regional else {}
				# x/z are exact terrain grid vertices. regional_surface_sample() already
				# computed their analytic height, so do not run a second height sampler.
				var base_height := (
					float(sample["height"])
					if regional
					else float(_sampler.call("height", seed, x, z))
				)
				var edit_delta := float(_edits.call("edit_delta_at", x, z)) if _edits != null else 0.0
				vertices[index] = Vector3(x, base_height + edit_delta, z)
				colors[index] = sample["color"] if regional else _sampler.call("terrain_color", seed, x, z)
				uv2[index] = Vector2(float(sample["moisture"]), float(sample["ground_cover"])) if regional else Vector2(0.45, 0.5)
			_mutex.lock()
			_progress = float(row - first_row + 1) / float(last_row - first_row)
			_mutex.unlock()


func build(seed: int, bounds: Rect2, steps: Vector2i, regional: bool, edits: Dictionary, owner: Node = null) -> ArrayMesh:
	_cancelled = false
	_jobs.clear()
	_tasks.clear()
	worker_count = mini(MAX_WORKERS, mini(maxi(1, OS.get_processor_count() - 1), steps.y + 1))
	var frame_tree: SceneTree = owner.get_tree() if owner != null else null
	for index in range(worker_count):
		var job := RowJob.new()
		job.seed = seed
		job.bounds = bounds
		job.steps = steps
		job.first_row = int(index * (steps.y + 1) / worker_count)
		job.last_row = int((index + 1) * (steps.y + 1) / worker_count)
		job.regional = regional
		job.edit_payload = edits.duplicate(true)
		_jobs.append(job)
		_tasks.append(WorkerThreadPool.add_task(job.run, false, "Region terrain rows"))
	while not _complete():
		if frame_tree == null:
			break
		var progress := 0.0
		for job in _jobs:
			progress += job.progress()
		owner.set("startup_progress", progress / float(worker_count) * 0.88)
		await frame_tree.process_frame
		if _cancelled or not is_instance_valid(owner):
			cancel_and_wait()
			return ArrayMesh.new()
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
	if _cancelled:
		return ArrayMesh.new()

	# Build the rendering arrays directly. The old SurfaceTool path performed a
	# virtual method call per vertex/index and generated normals in another pass.
	# Here the worker data is copied into packed arrays once, normals are derived
	# from neighboring already-sampled heights, and ArrayMesh consumes them as-is.
	var stride := steps.x + 1
	var row_count := steps.y + 1
	var vertex_count := stride * row_count
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()
	var normals := PackedVector3Array()
	vertices.resize(vertex_count)
	colors.resize(vertex_count)
	uv2.resize(vertex_count)
	normals.resize(vertex_count)
	var slice_started := Time.get_ticks_usec()

	for job in _jobs:
		var destination_start := job.first_row * stride
		for local_index in range(job.vertices.size()):
			var destination := destination_start + local_index
			vertices[destination] = job.vertices[local_index]
			colors[destination] = job.colors[local_index]
			uv2[destination] = job.uv2[local_index]
			if frame_tree != null and Time.get_ticks_usec() - slice_started >= MAIN_THREAD_SLICE_USEC:
				owner.set("startup_progress", 0.88 + float(destination + 1) / float(vertex_count) * 0.035)
				await frame_tree.process_frame
				if _cancelled or not is_instance_valid(owner):
					return ArrayMesh.new()
				slice_started = Time.get_ticks_usec()

	for row in range(row_count):
		var up_row := maxi(0, row - 1)
		var down_row := mini(steps.y, row + 1)
		for column in range(stride):
			var left_column := maxi(0, column - 1)
			var right_column := mini(steps.x, column + 1)
			var center_index := row * stride + column
			var left := vertices[row * stride + left_column]
			var right := vertices[row * stride + right_column]
			var up := vertices[up_row * stride + column]
			var down := vertices[down_row * stride + column]
			var tangent_x := right - left
			var tangent_z := down - up
			var normal := tangent_z.cross(tangent_x)
			if normal.length_squared() <= 0.000001:
				normal = Vector3.UP
			else:
				normal = normal.normalized()
				if normal.y < 0.0:
					normal = -normal
			normals[center_index] = normal
			if frame_tree != null and Time.get_ticks_usec() - slice_started >= MAIN_THREAD_SLICE_USEC:
				owner.set("startup_progress", 0.915 + float(center_index + 1) / float(vertex_count) * 0.035)
				await frame_tree.process_frame
				if _cancelled or not is_instance_valid(owner):
					return ArrayMesh.new()
				slice_started = Time.get_ticks_usec()

	var index_count := steps.x * steps.y * 6
	var indices := PackedInt32Array()
	indices.resize(index_count)
	var write_index := 0
	for row in range(steps.y):
		for column in range(steps.x):
			var top_left := row * stride + column
			var top_right := top_left + 1
			var bottom_left := top_left + stride
			var bottom_right := bottom_left + 1
			indices[write_index] = top_left
			indices[write_index + 1] = top_right
			indices[write_index + 2] = bottom_right
			indices[write_index + 3] = top_left
			indices[write_index + 4] = bottom_right
			indices[write_index + 5] = bottom_left
			write_index += 6
		if frame_tree != null and Time.get_ticks_usec() - slice_started >= MAIN_THREAD_SLICE_USEC:
			owner.set("startup_progress", 0.95 + float(row + 1) / float(maxi(1, steps.y)) * 0.045)
			await frame_tree.process_frame
			if _cancelled or not is_instance_valid(owner):
				return ArrayMesh.new()
			slice_started = Time.get_ticks_usec()

	_jobs.clear()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func _complete() -> bool:
	for task in _tasks:
		if not WorkerThreadPool.is_task_completed(task):
			return false
	return true


func cancel_and_wait() -> void:
	_cancelled = true
	for job in _jobs:
		job.cancel()
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
