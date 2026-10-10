extends "res://scripts/ui/hud.gd"

## Regional sandbox HUD adapter.
##
## The base HUD predates the regional soft-credit policy and still contains a
## few cash-only `money < cost` button guards. GameStore remains authoritative:
## this adapter only removes those stale UI guards for operations that the
## regional GameStore explicitly bridges through basic soft credit.


func refresh() -> void:
	super.refresh()
	_apply_regional_funding_guards()


func _process(delta: float) -> void:
	super._process(delta)
	# Base HUD can rebuild inspector buttons from several state-change paths.
	# Re-apply the regional funding policy after those renders without owning
	# any simulation or financial state here.
	_apply_regional_funding_guards()


func _apply_regional_funding_guards() -> void:
	if not GameStore.is_sandbox() or not is_instance_valid(primary_button) or not primary_button.visible:
		return

	match _primary_action:
		"commit_route":
			_apply_route_credit_guard()
		"build_regional_road":
			_apply_regional_road_credit_guard()
		"upgrade_free_stop", "build_depot":
			# These base-HUD actions are disabled only by the legacy cash guard
			# once their normal render-time structural checks have passed.
			primary_button.disabled = false


func _apply_route_credit_guard() -> void:
	if not GameStore.route_editor_active():
		return
	var points: Array = GameStore.route_editor_points()
	if points.size() < 2:
		primary_button.disabled = true
		return

	# Do not bypass higher-tier unlock/capital requirements. The regional
	# GameStore bridges only an already-unlocked route's construction cost.
	var transit_mode := str(GameStore.route_editor.get("transit_mode", "bus"))
	if str(GameStore.route_editor.get("mode", "")) == "edit":
		transit_mode = str(GameStore.transit_line(str(GameStore.route_editor.get("line_id", ""))).get("mode", "bus"))
	if transit_mode != "bus":
		var status: Dictionary = GameStore.transit_mode_status(transit_mode)
		if not bool(status.get("unlocked", false)):
			return
	primary_button.disabled = false


func _apply_regional_road_credit_guard() -> void:
	var road_id := _primary_payload
	if road_id.is_empty():
		return
	var status: Dictionary = GameStore.regional_road_build_status(road_id)
	primary_button.disabled = not bool(status.get("available", false))
