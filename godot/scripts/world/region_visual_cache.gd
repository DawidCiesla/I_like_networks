extends RefCounted
class_name RegionVisualCache

## Bounded, disposable on-disk cache for generated world-region visuals.
## Mesh files contain only ArrayMesh surface arrays; materials and other
## Objects are intentionally left to the renderer and are never deserialized.

const FORMAT_VERSION: int = 1
const FORMAT_MAGIC: String = "ILN_REGION_VISUAL_CACHE"
const DEFAULT_CACHE_DIRECTORY: String = "user://region_visual_cache"
const MAX_CACHE_ENTRY_BYTES: int = 64 * 1024 * 1024
const MAX_CACHE_ENTRIES: int = 8
const MAX_CACHE_DIRECTORY_BYTES: int = 256 * 1024 * 1024
const MAX_VALUE_DEPTH: int = 64
const MAX_VALUE_NODES: int = 1_000_000

const REQUIRED_CONTEXT_FIELDS: Array[String] = [
	"geometry_revision",
	"terrain_edits",
	"seed",
	"bounds",
	"resolution",
]


## Hashes all supplied context, including artifact-specific settings. Set
## geometry_revision per artifact and increment it whenever that renderer's
## geometry algorithm changes; terrain_edits, seed, map identity, bounds, and
## resolution invalidate entries when source geometry or sampling changes.
static func create_key(kind: String, context: Dictionary) -> String:
	if kind.is_empty() or kind.length() > 128 or not _has_required_context(context):
		return ""
	if not context.has("map_identity") and not context.has("map"):
		return ""
	if _safe_value_count(context, 0) < 0:
		return ""
	var canonical_context: Variant = _canonicalize(context)
	var bytes: PackedByteArray = var_to_bytes([FORMAT_VERSION, kind, canonical_context])
	if bytes.is_empty():
		return ""
	return _sha256_hex(bytes)


## Returns null on a cache miss, corrupt entry, or mesh reconstruction failure.
## The caller should assign its current material after loading.
static func load_mesh(key: String, directory_override: String = "") -> ArrayMesh:
	var entry: Dictionary = _read_entry(key, directory_override)
	if not bool(entry.get("ok", false)) or str(entry.get("payload_type", "")) != "mesh":
		return null
	return _mesh_from_payload(entry.get("payload", null))


## Stores only typed surface arrays; mesh surface materials are not persisted.
static func save_mesh(key: String, mesh: ArrayMesh, directory_override: String = "") -> bool:
	if mesh == null:
		return false
	var surfaces: Array = []
	for surface_index in range(mesh.get_surface_count()):
		var surface_arrays: Array = mesh.surface_get_arrays(surface_index)
		if surface_arrays.size() != Mesh.ARRAY_MAX or _safe_value_count(surface_arrays, 0) < 0:
			return false
		surfaces.append({
			"primitive": mesh.surface_get_primitive_type(surface_index),
			"arrays": surface_arrays,
		})
	return _write_entry(key, "mesh", {"surfaces": surfaces}, directory_override)


## Generic data path for tree/foliage arrays and dictionaries. Object-bearing
## values are rejected on write and object deserialization stays disabled.
static func load_data(key: String, directory_override: String = "") -> Variant:
	var entry: Dictionary = _read_entry(key, directory_override)
	if not bool(entry.get("ok", false)) or str(entry.get("payload_type", "")) != "data":
		return null
	return entry.get("payload", null)


static func save_data(key: String, data: Variant, directory_override: String = "") -> bool:
	if data == null or _safe_value_count(data, 0) < 0:
		return false
	return _write_entry(key, "data", data, directory_override)


## Exposed for diagnostics and tests. Invalid inputs return an empty path.
static func get_entry_path(key: String, directory_override: String = "") -> String:
	if not _valid_key(key):
		return ""
	var directory: String = _resolve_directory(directory_override)
	if directory.is_empty():
		return ""
	return directory.path_join(key + ".cache")


static func _has_required_context(context: Dictionary) -> bool:
	for field in REQUIRED_CONTEXT_FIELDS:
		if not context.has(field) or context[field] == null:
			return false
	return true


static func _valid_key(key: String) -> bool:
	if key.length() != 64:
		return false
	for index in range(key.length()):
		var codepoint: int = key.unicode_at(index)
		if not ((codepoint >= 48 and codepoint <= 57) or (codepoint >= 97 and codepoint <= 102)):
			return false
	return true


static func _canonicalize(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var source: Dictionary = value
		var keys: Array = source.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool:
			return _sort_token(left) < _sort_token(right)
		)
		var result: Dictionary = {}
		for key in keys:
			result[_canonicalize(key)] = _canonicalize(source[key])
		return result
	if typeof(value) == TYPE_ARRAY:
		var result_array: Array = []
		for item in value:
			result_array.append(_canonicalize(item))
		return result_array
	return value


static func _sort_token(value: Variant) -> String:
	return "%d:%s" % [typeof(value), var_to_str(value)]


static func _safe_value_count(value: Variant, depth: int) -> int:
	if depth > MAX_VALUE_DEPTH:
		return -1
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return -1
		TYPE_DICTIONARY:
			var total: int = 1
			var dictionary: Dictionary = value
			for key in dictionary:
				var key_count: int = _safe_value_count(key, depth + 1)
				var value_count: int = _safe_value_count(dictionary[key], depth + 1)
				if key_count < 0 or value_count < 0:
					return -1
				total += key_count + value_count
				if total > MAX_VALUE_NODES:
					return -1
			return total
		TYPE_ARRAY:
			var total: int = 1
			var array_value: Array = value
			for item in array_value:
				var item_count: int = _safe_value_count(item, depth + 1)
				if item_count < 0:
					return -1
				total += item_count
				if total > MAX_VALUE_NODES:
					return -1
			return total
		_:
			return 1


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var hasher: HashingContext = HashingContext.new()
	if hasher.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if hasher.update(bytes) != OK:
		return ""
	return hasher.finish().hex_encode()


static func _resolve_directory(directory_override: String) -> String:
	if directory_override.is_empty():
		return ProjectSettings.globalize_path(DEFAULT_CACHE_DIRECTORY)
	if directory_override.begins_with("user://"):
		return ProjectSettings.globalize_path(directory_override)
	if not directory_override.is_absolute_path():
		return ""
	return directory_override.simplify_path()


static func _write_entry(key: String, payload_type: String, payload: Variant, directory_override: String) -> bool:
	if not _valid_key(key) or _safe_value_count(payload, 0) < 0:
		return false
	var payload_bytes: PackedByteArray = var_to_bytes(payload)
	if payload_bytes.is_empty() or payload_bytes.size() > MAX_CACHE_ENTRY_BYTES:
		return false
	var directory: String = _resolve_directory(directory_override)
	if directory.is_empty():
		return false
	var make_directory_error: Error = DirAccess.make_dir_recursive_absolute(directory)
	if make_directory_error != OK and make_directory_error != ERR_ALREADY_EXISTS:
		return false
	var destination: String = directory.path_join(key + ".cache")
	var existing: Dictionary = _read_entry_path(destination, key)
	if bool(existing.get("ok", false)) and str(existing.get("payload_type", "")) == payload_type:
		_prune_directory(directory, destination)
		return true
	var temporary: String = destination + "." + str(OS.get_process_id()) + "." + str(Time.get_ticks_usec()) + ".tmp"
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(_file_magic_prefix())
	var header: Dictionary = {
		"magic": FORMAT_MAGIC,
		"version": FORMAT_VERSION,
		"key": key,
		"payload_type": payload_type,
		"payload_size": payload_bytes.size(),
		"sha256": _sha256_hex(payload_bytes),
	}
	var header_bytes: PackedByteArray = JSON.stringify(header).to_utf8_buffer()
	file.store_32(header_bytes.size())
	file.store_buffer(header_bytes)
	file.store_buffer(payload_bytes)
	file.flush()
	var file_error: Error = file.get_error()
	file.close()
	if file_error != OK:
		DirAccess.remove_absolute(temporary)
		return false
	var verified: Dictionary = _read_entry_path(temporary, key)
	if not bool(verified.get("ok", false)) or str(verified.get("payload_type", "")) != payload_type:
		DirAccess.remove_absolute(temporary)
		return false
	if not _commit_temporary_file(temporary, destination):
		DirAccess.remove_absolute(temporary)
		return false
	_prune_directory(directory, destination)
	return true


static func _read_entry(key: String, directory_override: String) -> Dictionary:
	if not _valid_key(key):
		return {"ok": false}
	var directory: String = _resolve_directory(directory_override)
	if directory.is_empty():
		return {"ok": false}
	return _read_entry_path(directory.path_join(key + ".cache"), key)


static func _read_entry_path(path: String, expected_key: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false}
	var file_size: int = file.get_length()
	if file_size <= 0 or file_size > MAX_CACHE_ENTRY_BYTES:
		file.close()
		return {"ok": false}
	var magic_prefix: PackedByteArray = file.get_buffer(_file_magic_prefix().size())
	if magic_prefix != _file_magic_prefix():
		file.close()
		return {"ok": false}
	if file.get_length() - file.get_position() < 4:
		file.close()
		return {"ok": false}
	var header_size: int = int(file.get_32())
	var remaining_after_header_size: int = file_size - file.get_position()
	if header_size <= 0 or header_size > 4096 or header_size > remaining_after_header_size:
		file.close()
		return {"ok": false}
	var header_bytes: PackedByteArray = file.get_buffer(header_size)
	if header_bytes.size() != header_size:
		file.close()
		return {"ok": false}
	var header_value: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
	if typeof(header_value) != TYPE_DICTIONARY:
		file.close()
		return {"ok": false}
	var header: Dictionary = header_value
	if str(header.get("magic", "")) != FORMAT_MAGIC or int(header.get("version", -1)) != FORMAT_VERSION:
		file.close()
		return {"ok": false}
	if str(header.get("key", "")) != expected_key:
		file.close()
		return {"ok": false}
	var payload_size_value: Variant = header.get("payload_size", null)
	if typeof(payload_size_value) != TYPE_INT and typeof(payload_size_value) != TYPE_FLOAT:
		file.close()
		return {"ok": false}
	var payload_size_number: float = float(payload_size_value)
	if not is_finite(payload_size_number) or floorf(payload_size_number) != payload_size_number:
		file.close()
		return {"ok": false}
	var payload_size: int = int(payload_size_number)
	var remaining: int = file_size - file.get_position()
	if payload_size <= 0 or payload_size > MAX_CACHE_ENTRY_BYTES or payload_size != remaining:
		file.close()
		return {"ok": false}
	var payload_bytes: PackedByteArray = file.get_buffer(payload_size)
	var read_error: Error = file.get_error()
	file.close()
	if read_error != OK or payload_bytes.size() != payload_size:
		return {"ok": false}
	var expected_hash: String = str(header.get("sha256", ""))
	if expected_hash.length() != 64 or _sha256_hex(payload_bytes) != expected_hash:
		return {"ok": false}
	var payload: Variant = bytes_to_var(payload_bytes)
	if payload == null or _safe_value_count(payload, 0) < 0:
		return {"ok": false}
	var payload_type: String = str(header.get("payload_type", ""))
	if payload_type != "mesh" and payload_type != "data":
		return {"ok": false}
	return {"ok": true, "payload_type": payload_type, "payload": payload}


static func _mesh_from_payload(payload: Variant) -> ArrayMesh:
	if typeof(payload) != TYPE_DICTIONARY:
		return null
	var payload_dictionary: Dictionary = payload
	var surfaces_value: Variant = payload_dictionary.get("surfaces", null)
	if typeof(surfaces_value) != TYPE_ARRAY:
		return null
	var surfaces: Array = surfaces_value
	var mesh: ArrayMesh = ArrayMesh.new()
	for surface_value in surfaces:
		if typeof(surface_value) != TYPE_DICTIONARY:
			return null
		var surface: Dictionary = surface_value
		var primitive_value: Variant = surface.get("primitive", null)
		var arrays_value: Variant = surface.get("arrays", null)
		if typeof(primitive_value) != TYPE_INT or typeof(arrays_value) != TYPE_ARRAY:
			return null
		var arrays: Array = arrays_value
		if arrays.size() != Mesh.ARRAY_MAX or _safe_value_count(arrays, 0) < 0:
			return null
		var primitive: int = int(primitive_value)
		if primitive < Mesh.PRIMITIVE_POINTS or primitive > Mesh.PRIMITIVE_TRIANGLE_STRIP:
			return null
		mesh.add_surface_from_arrays(primitive, arrays)
	return mesh


static func _file_magic_prefix() -> PackedByteArray:
	var prefix: PackedByteArray = FORMAT_MAGIC.to_utf8_buffer()
	prefix.append(10)
	return prefix


static func _commit_temporary_file(temporary: String, destination: String) -> bool:
	var rename_error: Error = DirAccess.rename_absolute(temporary, destination)
	if rename_error == OK:
		return true
	if not FileAccess.file_exists(destination):
		return false
	var backup: String = destination + "." + str(OS.get_process_id()) + "." + str(Time.get_ticks_usec()) + ".bak"
	if DirAccess.rename_absolute(destination, backup) != OK:
		return false
	if DirAccess.rename_absolute(temporary, destination) != OK:
		DirAccess.rename_absolute(backup, destination)
		return false
	DirAccess.remove_absolute(backup)
	return true


static func _prune_directory(directory_path: String, protected_path: String) -> void:
	var directory: DirAccess = DirAccess.open(directory_path)
	if directory == null:
		return
	var cache_paths: Array[String] = []
	for file_name in directory.get_files():
		if str(file_name).ends_with(".cache"):
			cache_paths.append(directory_path.path_join(str(file_name)))
	var total_bytes: int = _cache_directory_size(cache_paths)
	while cache_paths.size() > MAX_CACHE_ENTRIES or total_bytes > MAX_CACHE_DIRECTORY_BYTES:
		var oldest_index: int = -1
		var oldest_time: int = 9223372036854775807
		for index in range(cache_paths.size()):
			if cache_paths[index] == protected_path:
				continue
			var modified_time: int = FileAccess.get_modified_time(cache_paths[index])
			if oldest_index < 0 or modified_time < oldest_time:
				oldest_index = index
				oldest_time = modified_time
		if oldest_index < 0:
			return
		var removed_path: String = cache_paths[oldest_index]
		var removed_file: FileAccess = FileAccess.open(removed_path, FileAccess.READ)
		if removed_file != null:
			total_bytes -= removed_file.get_length()
			removed_file.close()
		DirAccess.remove_absolute(removed_path)
		cache_paths.remove_at(oldest_index)


static func _cache_directory_size(cache_paths: Array[String]) -> int:
	var total_bytes: int = 0
	for cache_path in cache_paths:
		var file: FileAccess = FileAccess.open(cache_path, FileAccess.READ)
		if file == null:
			continue
		total_bytes += file.get_length()
		file.close()
	return total_bytes
