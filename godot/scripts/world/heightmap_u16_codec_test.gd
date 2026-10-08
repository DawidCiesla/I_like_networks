extends SceneTree

const HeightmapU16Codec = preload("res://scripts/world/heightmap_u16_codec.gd")

var _failures := 0


func _init() -> void:
	_run_tests()
	if _failures == 0:
		print("HEIGHTMAP U16 CODEC TEST: PASS")
		quit(0)
		return
	push_error("HEIGHTMAP U16 CODEC TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests() -> void:
	var source := PackedInt32Array([0, 1, 255, 256, 32767, 32768, 65534, 65535])
	var encoded := HeightmapU16Codec.export_binary(source, 4, 2, -120.5, 2048.25)
	_expect(bool(encoded.get("ok", false)), "valid U16 map exports")
	if not bool(encoded.get("ok", false)):
		return
	var bytes: PackedByteArray = encoded["data"]
	var payload_offset := HeightmapU16Codec.MAGIC.to_utf8_buffer().size()
	while payload_offset < bytes.size() and bytes[payload_offset] != 10:
		payload_offset += 1
	payload_offset += 1
	var expected_payload := PackedByteArray([
		0, 0,
		1, 0,
		255, 0,
		0, 1,
		255, 127,
		0, 128,
		254, 255,
		255, 255,
	])
	_expect(bytes.slice(payload_offset) == expected_payload, "payload stores exact little-endian U16 values")
	var decoded := HeightmapU16Codec.import_binary(bytes)
	_expect(bool(decoded.get("ok", false)), "exported map imports: %s" % str(decoded.get("error", "")))
	if bool(decoded.get("ok", false)):
		_expect(int(decoded["width"]) == 4, "width is retained")
		_expect(int(decoded["height"]) == 2, "height is retained")
		_expect(is_equal_approx(float(decoded["elevation_min"]), -120.5), "minimum elevation is retained")
		_expect(is_equal_approx(float(decoded["elevation_max"]), 2048.25), "maximum elevation is retained")
		_expect(decoded["samples"] == source, "all 16-bit samples round-trip exactly")

	var truncated_header := PackedByteArray([73, 76, 78])
	_expect(not bool(HeightmapU16Codec.import_binary(truncated_header).get("ok", false)), "truncated header is rejected")
	_expect(
		not bool(HeightmapU16Codec.import_binary(bytes.slice(0, bytes.size() - 1)).get("ok", false)),
		"truncated sample payload is rejected"
	)
	var trailing_bytes := bytes.duplicate()
	trailing_bytes.append(0)
	_expect(not bool(HeightmapU16Codec.import_binary(trailing_bytes).get("ok", false)), "trailing data is rejected")
	var bad_magic := bytes.duplicate()
	bad_magic[0] = 0
	_expect(not bool(HeightmapU16Codec.import_binary(bad_magic).get("ok", false)), "bad magic is rejected")
	var malformed_header := HeightmapU16Codec.MAGIC.to_utf8_buffer()
	malformed_header.append_array("{broken}\n".to_utf8_buffer())
	_expect(
		not bool(HeightmapU16Codec.import_binary(malformed_header).get("ok", false)),
		"malformed metadata is rejected"
	)
	var unsupported_version := HeightmapU16Codec.MAGIC.to_utf8_buffer()
	unsupported_version.append_array(JSON.stringify({
		"version": 99,
		"width": 1,
		"height": 1,
		"elevation_min": 0.0,
		"elevation_max": 1.0,
	}).to_utf8_buffer())
	unsupported_version.append(10)
	unsupported_version.append_array(PackedByteArray([0, 0]))
	_expect(
		not bool(HeightmapU16Codec.import_binary(unsupported_version).get("ok", false)),
		"unsupported format version is rejected"
	)

	_expect(
		not bool(HeightmapU16Codec.export_binary(PackedInt32Array([0]), 2, 1, 0.0, 1.0).get("ok", false)),
		"sample-count mismatch is rejected"
	)
	_expect(
		not bool(HeightmapU16Codec.export_binary(PackedInt32Array([-1]), 1, 1, 0.0, 1.0).get("ok", false)),
		"negative U16 sample is rejected"
	)
	_expect(
		not bool(HeightmapU16Codec.export_binary(PackedInt32Array([65536]), 1, 1, 0.0, 1.0).get("ok", false)),
		"overflow U16 sample is rejected"
	)
	_expect(
		not bool(HeightmapU16Codec.export_binary(PackedInt32Array([0]), 1, 1, 2.0, 1.0).get("ok", false)),
		"reversed elevation range is rejected"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("HeightmapU16Codec: %s" % message)
