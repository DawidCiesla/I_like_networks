extends SceneTree

const TerrainEditData = preload("res://scripts/world/terrain_edit_data.gd")
const TerrainModel = preload("res://scripts/world/terrain_model.gd")
const TerrainSurface = preload("res://scripts/world/terrain_surface.gd")

var _failures := 0


func _init() -> void:
	_run_tests()
	if _failures == 0:
		print("TERRAIN EDIT DATA TEST: PASS")
		quit(0)
		return
	push_error("TERRAIN EDIT DATA TEST: FAIL (%d checks)" % _failures)
	quit(1)


func _run_tests() -> void:
	var data := TerrainEditData.new(9142, 10.0, TerrainEditData.SOURCE_TERRAIN_MODEL)
	var center := Vector2(20.0, -10.0)
	var base_height := TerrainModel.height(data.seed, center.x, center.y)
	_expect(is_equal_approx(data.height_at(center.x, center.y), base_height), "new edit data queries its seeded base terrain")
	_expect(is_equal_approx(data.edit_delta_at(center.x, center.y), 0.0), "new edit data has a zero terrain delta")

	var raised := data.raise_brush(center, 20.0, 12.0)
	_expect(bool(raised.get("ok", false)), "raise brush accepts a bounded brush")
	_expect(data.edit_count() > 0, "raise brush stores sparse lattice edits")
	_expect(is_equal_approx(data.height_at(center.x, center.y), base_height + 12.0), "raise brush applies full strength at its center")
	_expect(data.height_at(center.x + 10.0, center.y) > base_height, "point query interpolates edits between lattice samples")
	var lowered := data.lower_brush(center, 20.0, 4.0)
	_expect(bool(lowered.get("ok", false)), "lower brush accepts a bounded brush")
	_expect(is_equal_approx(data.height_at(center.x, center.y), base_height + 8.0), "lower brush subtracts height deterministically")

	var target := 77.25
	var flattened := data.flatten_to_target(center, 20.0, target)
	_expect(bool(flattened.get("ok", false)), "target flatten succeeds")
	_expect(is_equal_approx(data.height_at(center.x, center.y), target), "target flatten reaches its target at the brush center")
	var terrain_flattened := data.flatten_to_terrain_sample(center, 20.0)
	_expect(bool(terrain_flattened.get("ok", false)), "terrain sample flatten succeeds")
	_expect(is_equal_approx(data.height_at(center.x, center.y), base_height), "terrain sample flatten uses the center's seeded terrain height")

	data.raise_brush(center, 10.0, 18.0)
	var peak := data.height_at(center.x, center.y)
	var smoothed := data.smooth_brush(center, 10.0)
	_expect(bool(smoothed.get("ok", false)), "smooth brush succeeds")
	_expect(data.height_at(center.x, center.y) < peak, "smooth brush reduces a local peak")
	var deterministic_a := TerrainEditData.new(9142, 10.0, TerrainEditData.SOURCE_TERRAIN_MODEL)
	var deterministic_b := TerrainEditData.new(9142, 10.0, TerrainEditData.SOURCE_TERRAIN_MODEL)
	deterministic_a.raise_brush(center, 20.0, 12.0)
	deterministic_a.smooth_brush(center, 20.0, 0.65)
	deterministic_b.raise_brush(center, 20.0, 12.0)
	deterministic_b.smooth_brush(center, 20.0, 0.65)
	_expect(deterministic_a.to_dict() == deterministic_b.to_dict(), "same seed and brush sequence produce identical data")

	var payload := data.to_dict()
	var json_round_trip: Variant = JSON.parse_string(JSON.stringify(payload))
	_expect(typeof(json_round_trip) == TYPE_DICTIONARY, "serialized edits are plain JSON-compatible data")
	if typeof(json_round_trip) == TYPE_DICTIONARY:
		var imported := TerrainEditData.from_dict(json_round_trip)
		_expect(bool(imported.get("ok", false)), "serialized edits import: %s" % str(imported.get("error", "")))
		if bool(imported.get("ok", false)):
			var restored: TerrainEditData = imported["data"]
			_expect(is_equal_approx(restored.height_at(center.x, center.y), data.height_at(center.x, center.y)), "serialization round-trip retains point queries")
	var direct_import := TerrainEditData.from_dict(payload)
	_expect(bool(direct_import.get("ok", false)), "plain dictionary imports: %s" % str(direct_import.get("error", "")))
	if bool(direct_import.get("ok", false)):
		var direct_restored: TerrainEditData = direct_import["data"]
		_expect(direct_restored.to_dict() == payload, "plain dictionary round-trip retains canonical sparse edits")

	var surface_data := TerrainEditData.new(9142, 58.0, TerrainEditData.SOURCE_TERRAIN_SURFACE)
	_expect(is_equal_approx(
		surface_data.terrain_height_at(100.0, 100.0),
		TerrainSurface.height(9142, 100.0, 100.0)
	), "surface source follows the rendered terrain sampler")

	_expect(not bool(data.raise_brush(center, 100000.0, 1.0).get("ok", false)), "oversized brushes are rejected")
	_expect(not bool(data.flatten_to_target(center, 10.0, INF).get("ok", false)), "non-finite flatten targets are rejected")
	var invalid_payload := payload.duplicate(true)
	invalid_payload["version"] = TerrainEditData.FORMAT_VERSION + 1
	_expect(not bool(TerrainEditData.from_dict(invalid_payload).get("ok", false)), "unknown serialization versions are rejected")
	var duplicate_payload := {
		"version": TerrainEditData.FORMAT_VERSION,
		"seed": 1,
		"grid_step": 10.0,
		"source": TerrainEditData.SOURCE_TERRAIN_MODEL,
		"edits": [[0, 0, 1.0], [0, 0, 2.0]],
	}
	_expect(not bool(TerrainEditData.from_dict(duplicate_payload).get("ok", false)), "duplicate sparse samples are rejected")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("TerrainEditData: %s" % message)
