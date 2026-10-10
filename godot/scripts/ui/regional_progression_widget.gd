extends CanvasLayer
class_name RegionalProgressionWidget

const REFRESH_SECONDS := 0.6

var _panel: PanelContainer
var _title: Label
var _body: Label
var _progress: ProgressBar
var _refresh_remaining := 0.0
var _signature := ""


func _ready() -> void:
	layer = 34
	_build_ui()
	_refresh(true)


func _process(delta: float) -> void:
	_refresh_remaining -= delta
	if _refresh_remaining <= 0.0:
		_refresh_remaining = REFRESH_SECONDS
		_refresh(false)


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "RegionalNextObjective"
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 18.0
	_panel.offset_right = 388.0
	_panel.offset_top = 86.0
	_panel.offset_bottom = 194.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_bottom", 9)
	_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 5)
	margin.add_child(stack)

	var eyebrow := Label.new()
	eyebrow.text = "NEXT OBJECTIVE"
	eyebrow.add_theme_font_size_override("font_size", 10)
	stack.add_child(eyebrow)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 13)
	stack.add_child(_title)

	_body = Label.new()
	_body.add_theme_font_size_override("font_size", 10)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.max_lines_visible = 2
	stack.add_child(_body)

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 100.0
	_progress.show_percentage = false
	_progress.custom_minimum_size.y = 5.0
	stack.add_child(_progress)

	_panel.visible = false


func _refresh(force: bool) -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store) or not store.has_method("is_sandbox") or not bool(store.call("is_sandbox")):
		_panel.visible = false
		return
	var snapshot_value: Variant = store.city.get("progression_v2", {})
	if typeof(snapshot_value) != TYPE_DICTIONARY:
		_panel.visible = false
		return
	var snapshot: Dictionary = snapshot_value
	var objective_value: Variant = snapshot.get("next_objective", {})
	if typeof(objective_value) != TYPE_DICTIONARY or (objective_value as Dictionary).is_empty():
		_panel.visible = false
		return
	var objective: Dictionary = objective_value
	var signature := "%s|%s|%s|%s" % [
		str(objective.get("kind", "")),
		str(objective.get("id", "")),
		str(objective.get("label", "")),
		str(objective.get("feedback", "")),
	]
	if not force and signature == _signature:
		_update_progress(snapshot, objective)
		return
	_signature = signature
	_panel.visible = true
	_title.text = str(objective.get("label", "Continue developing the region")).to_upper()
	_body.text = str(objective.get("feedback", ""))
	_update_progress(snapshot, objective)


func _update_progress(snapshot: Dictionary, objective: Dictionary) -> void:
	var kind := str(objective.get("kind", ""))
	if kind == "milestone":
		var goal := _goal_by_id(snapshot.get("goals", []), str(objective.get("id", "")))
		_progress.visible = not goal.is_empty()
		_progress.value = clampf(float(goal.get("progress", 0.0)), 0.0, 1.0) * 100.0
		return
	if kind == "infrastructure_unlock":
		var unlocks_value: Variant = snapshot.get("mode_unlocks", {})
		var unlocks: Dictionary = unlocks_value if typeof(unlocks_value) == TYPE_DICTIONARY else {}
		var unlock_value: Variant = unlocks.get(str(objective.get("id", "")), {})
		if typeof(unlock_value) != TYPE_DICTIONARY:
			_progress.visible = false
			return
		var unlock: Dictionary = unlock_value
		var population: Dictionary = unlock.get("population", {})
		var treasury: Dictionary = unlock.get("treasury", {})
		var population_progress := _ratio(
			float(population.get("current", 0.0)),
			float(population.get("target", 0.0))
		)
		var treasury_progress := _ratio(
			float(treasury.get("current", 0.0)),
			float(treasury.get("target", 0.0))
		)
		_progress.visible = true
		_progress.value = minf(population_progress, treasury_progress) * 100.0
		return
	_progress.visible = false


static func _goal_by_id(goals_value: Variant, goal_id: String) -> Dictionary:
	if typeof(goals_value) != TYPE_ARRAY:
		return {}
	for goal_value in goals_value:
		if typeof(goal_value) != TYPE_DICTIONARY:
			continue
		var goal: Dictionary = goal_value
		if str(goal.get("id", "")) == goal_id:
			return goal
	return {}


static func _ratio(current: float, target: float) -> float:
	if target <= 0.000001:
		return 1.0
	return clampf(current / target, 0.0, 1.0)
