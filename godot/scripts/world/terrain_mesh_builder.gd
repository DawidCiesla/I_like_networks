extends RefCounted

const Sampler = preload("res://scripts/world/terrain_sampler.gd")
const EditData = preload("res://scripts/world/terrain_edit_data.gd")
const MAX_WORKERS := 4

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
				# computed their analytic height, so do not run the previous four-sample
				# triangulated height path again. Terrain edits remain an additive delta.
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
		owner.set("startup_progress", progress / float(worker_count) * 0.9)
		await frame_tree.process_frame
		if _cancelled or not is_instance_valid(owner):
			cancel_and_wait()
			return ArrayMesh.new()
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
	# Rendering resources are assembled only on the calling/main thread.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var slice_start := Time.get_ticks_msec()
	for job in _jobs:
		for index in range(job.vertices.size()):
			tool.set_color(job.colors[index])
			tool.set_uv2(job.uv2[index])
			tool.add_vertex(job.vertices[index])
			if frame_tree != null and Time.get_ticks_msec() - slice_start >= 8:
				await frame_tree.process_frame
				if _cancelled or not is_instance_valid(owner):
					return ArrayMesh.new()
				slice_start = Time.get_ticks_msec()
	var stride := steps.x + 1
	for row in range(steps.y):
		for column in range(steps.x):
			var top_left := row * stride + column
			tool.add_index(top_left)
			tool.add_index(top_left + 1)
			tool.add_index(top_left + stride + 1)
			tool.add_index(top_left)
			tool.add_index(top_left + stride + 1)
			tool.add_index(top_left + stride)
		if frame_tree != null and Time.get_ticks_msec() - slice_start >= 8:
			owner.set("startup_progress", 0.9 + float(row + 1) / float(steps.y) * 0.09)
			await frame_tree.process_frame
			if _cancelled or not is_instance_valid(owner):
				return ArrayMesh.new()
			slice_start = Time.get_ticks_msec()
	_jobs.clear()
	tool.generate_normals()
	return tool.commit()


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
