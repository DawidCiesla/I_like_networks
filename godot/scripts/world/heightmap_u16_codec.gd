extends RefCounted
class_name HeightmapU16Codec

const MAGIC := "ILNH16\n"
const FORMAT_VERSION := 1
const MAX_HEADER_BYTES := 4096
const MAX_DIMENSION := 65535
const MAX_SAMPLE_COUNT := 16777216


## Encodes row-major integer samples in [0, 65535]. The UTF-8 JSON header
## declares dimensions and elevation range; each payload sample is little-endian U16.
static func export_binary(
	samples: PackedInt32Array,
	width: int,
	height: int,
	elevation_min: float,
	elevation_max: float
) -> Dictionary:
	var validation_error := _validate_metadata(width, height, elevation_min, elevation_max)
	if not validation_error.is_empty():
		return _failure(validation_error)
	var expected_count := width * height
	if samples.size() != expected_count:
		return _failure("Sample count must equal width multiplied by height.")
	for sample in samples:
		if sample < 0 or sample > 65535:
			return _failure("Every sample must be an unsigned 16-bit integer.")

	var header := JSON.stringify({
		"version": FORMAT_VERSION,
		"width": width,
		"height": height,
		"elevation_min": elevation_min,
		"elevation_max": elevation_max,
	})
	var bytes := MAGIC.to_utf8_buffer()
	bytes.append_array(header.to_utf8_buffer())
	bytes.append(10)
	for sample in samples:
		bytes.append(sample & 0xff)
		bytes.append((sample >> 8) & 0xff)
	return {"ok": true, "data": bytes}


## Decodes the complete container and rejects unknown versions, invalid metadata,
## truncated payloads, and trailing bytes.
static func import_binary(bytes: PackedByteArray) -> Dictionary:
	var magic_bytes := MAGIC.to_utf8_buffer()
	if bytes.size() < magic_bytes.size() + 2:
		return _failure("File is shorter than the format header.")
	for index in range(magic_bytes.size()):
		if bytes[index] != magic_bytes[index]:
			return _failure("Magic signature is invalid.")

	var header_start := magic_bytes.size()
	var header_end := -1
	var header_limit := mini(bytes.size(), header_start + MAX_HEADER_BYTES + 1)
	for index in range(header_start, header_limit):
		if bytes[index] == 10:
			header_end = index
			break
	if header_end < 0:
		return _failure("Metadata header is missing or exceeds the size limit.")
	if header_end == header_start:
		return _failure("Metadata header is empty.")

	var parser := JSON.new()
	var parse_status := parser.parse(bytes.slice(header_start, header_end).get_string_from_utf8())
	if parse_status != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return _failure("Metadata header is not a JSON object.")
	var metadata: Dictionary = parser.data
	if not _is_integer(metadata.get("version")) or int(metadata["version"]) != FORMAT_VERSION:
		return _failure("Format version is missing or unsupported.")
	if not _is_integer(metadata.get("width")) or not _is_integer(metadata.get("height")):
		return _failure("Width and height must be integers.")
	if not _is_number(metadata.get("elevation_min")) or not _is_number(metadata.get("elevation_max")):
		return _failure("Elevation range must contain numeric minimum and maximum values.")

	var width := int(metadata["width"])
	var height := int(metadata["height"])
	var elevation_min := float(metadata["elevation_min"])
	var elevation_max := float(metadata["elevation_max"])
	var validation_error := _validate_metadata(width, height, elevation_min, elevation_max)
	if not validation_error.is_empty():
		return _failure(validation_error)
	var sample_count := width * height
	var payload_start := header_end + 1
	var payload_bytes := sample_count * 2
	var available_bytes := bytes.size() - payload_start
	if available_bytes < payload_bytes:
		return _failure("U16 sample payload is truncated.")
	if available_bytes > payload_bytes:
		return _failure("File has unexpected trailing bytes.")

	var samples := PackedInt32Array()
	samples.resize(sample_count)
	for sample_index in range(sample_count):
		var byte_index := payload_start + sample_index * 2
		samples[sample_index] = int(bytes[byte_index]) | (int(bytes[byte_index + 1]) << 8)
	return {
		"ok": true,
		"width": width,
		"height": height,
		"elevation_min": elevation_min,
		"elevation_max": elevation_max,
		"samples": samples,
	}


static func _validate_metadata(
	width: int,
	height: int,
	elevation_min: float,
	elevation_max: float
) -> String:
	if width <= 0 or height <= 0 or width > MAX_DIMENSION or height > MAX_DIMENSION:
		return "Width and height must be positive and within the supported dimension limit."
	if width * height > MAX_SAMPLE_COUNT:
		return "Heightmap exceeds the supported sample-count limit."
	if not is_finite(elevation_min) or not is_finite(elevation_max) or elevation_min > elevation_max:
		return "Elevation range must be finite and minimum must not exceed maximum."
	return ""


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _is_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT or not is_finite(float(value)):
		return false
	return float(value) == floorf(float(value))


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
