extends CanvasLayer
class_name RegionalInfrastructureProposalWidget

const REFRESH_SECONDS := 0.5

var _panel: PanelContainer
var _toggle_button: Button
var _title: Label
var _meta: Label
var _body: Label
var _build_button: Button
var _counter: Label
var _previous_button: Button
var _next_button: Button
var _open := false
var _index := 0
var _refresh_remaining := 0.0


func _ready() -> void:
	layer = 38
	_build_ui()
	_refresh()


func _process(delta: float) -> void:
	_refresh_remaining -= delta
	if _refresh_remaining <= 0.0:
		_refresh_remaining = REFRESH_SECONDS
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_P:
		set_open(not _open)
		get_viewport().set_input_as_handled()


func set_open(value: bool) -> void:
	_open = value
	if is_instance_valid(_panel):
		_panel.visible = value
	if is_instance_valid(_toggle_button):
		_toggle_button.button_pressed = value
	if value:
		_refresh_remaining = 0.0
	_refresh()


func is_open() -> bool:
	return _open


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_toggle_button = Button.new()
	_toggle_button.name = "InfrastructureStudiesToggle"
	_toggle_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_toggle_button.offset_left = -374.0
	_toggle_button.offset_right = -222.0
	_toggle_button.offset_top = 50.0
	_toggle_button.offset_bottom = 84.0
	_toggle_button.toggle_mode = true
	_toggle_button.text = "STUDIES [P]"
	_toggle_button.tooltip_text = "Open strategic road proposals and benefit estimates."
	_toggle_button.pressed.connect(func(): set_open(_toggle_button.button_pressed))
	root.add_child(_toggle_button)

	_panel = PanelContainer.new()
	_panel.name = "RegionalInfrastructureProposal"
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -230.0
	_panel.offset_right = 230.0
	_panel.offset_top = -206.0
	_panel.offset_bottom = 206.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	margin.add_child(stack)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_title)

	_meta = Label.new()
	_meta.add_theme_font_size_override("font_size", 10)
	_meta.modulate = Color(0.78, 0.82, 0.86)
	_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_meta)

	_body = Label.new()
	_body.add_theme_font_size_override("font_size", 11)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.add_child(_body)

	_build_button = Button.new()
	_build_button.text = "BUILD"
	_build_button.custom_minimum_size.y = 34.0
	_build_button.pressed.connect(_build_current)
	stack.add_child(_build_button)

	var navigation := HBoxContainer.new()
	navigation.add_theme_constant_override("separation", 8)
	stack.add_child(navigation)

	_previous_button = Button.new()
	_previous_button.text = "< PREV"
	_previous_button.pressed.connect(_show_previous)
	navigation.add_child(_previous_button)

	_counter = Label.new()
	_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	navigation.add_child(_counter)

	_next_button = Button.new()
	_next_button.text = "NEXT >"
	_next_button.pressed.connect(_show_next)
	navigation.add_child(_next_button)

	var hint := Label.new()
	hint.text = "P · close/open infrastructure studies"
	hint.add_theme_font_size_override("font_size", 9)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.modulate = Color(0.65, 0.69, 0.73)
	stack.add_child(hint)

	_panel.visible = false


func _refresh() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store) or not store.has_method("is_sandbox") or not bool(store.call("is_sandbox")):
		if is_instance_valid(_panel):
			_panel.visible = false
		if is_instance_valid(_toggle_button):
			_toggle_button.visible = false
		return
	if is_instance_valid(_toggle_button):
		_toggle_button.visible = true
	var proposals := _proposals(store.city)
	if is_instance_valid(_toggle_button):
		_toggle_button.text = "STUDIES %d [P]" % proposals.size()
	if not _open:
		return
	if proposals.is_empty():
		_index = 0
		_title.text = "INFRASTRUCTURE STUDIES"
		_meta.text = "No active or monitored proposals"
		_body.text = "The regional planner has not identified a strategic road project yet. Congestion, traffic composition and settlement growth will be evaluated automatically."
		_build_button.visible = false
		_counter.text = "0 / 0"
		_previous_button.disabled = true
		_next_button.disabled = true
		return
	_index = clampi(_index, 0, proposals.size() - 1)
	var proposal: Dictionary = proposals[_index]
	_render_proposal(store, proposal)
	_counter.text = "%d / %d" % [_index + 1, proposals.size()]
	_previous_button.disabled = proposals.size() <= 1
	_next_button.disabled = proposals.size() <= 1


func _render_proposal(store: Node, proposal: Dictionary) -> void:
	var label := str(proposal.get("label", proposal.get("id", "Infrastructure proposal")))
	var project_class := str(proposal.get("projectClass", "proposal")).replace("_", " ").to_upper()
	var status := str(proposal.get("status", "suggested")).replace("-", " ").replace("_", " ").to_upper()
	var pressure := float(proposal.get("pressure", 0.0))
	var pressure_source := str(proposal.get("pressureSource", "activity_proxy")).replace("_", " ")
	var strategic_fit := str(proposal.get("strategicFit", "unknown")).replace("_", " ")
	var recommendation := str(proposal.get("strategicRecommendation", "monitor")).replace("_", " ")
	var flow := maxf(0.0, float(proposal.get("trafficFlowVph", 0.0)))
	var local_share := clampf(float(proposal.get("trafficLocalShare", 0.0)), 0.0, 1.0)
	var regional_share := clampf(float(proposal.get("trafficRegionalShare", 0.0)), 0.0, 1.0)
	var through_share := clampf(float(proposal.get("trafficThroughShare", 0.0)), 0.0, 1.0)
	var composition_available := bool(proposal.get("trafficCompositionAvailable", false))
	var vc_now := maxf(0.0, float(proposal.get("trafficVcRatio", 0.0)))
	var vc_after := maxf(0.0, float(proposal.get("estimatedVcRatioAfter", 0.0)))
	var delay_now := maxf(0.0, float(proposal.get("trafficDelayMinutes", 0.0)))
	var delay_after := maxf(0.0, float(proposal.get("estimatedDelayMinutesAfter", 0.0)))
	var diverted := maxf(0.0, float(proposal.get("estimatedTrafficDivertedVph", 0.0)))
	var capex := maxf(0.0, float(proposal.get("estimatedConstructionCost", 0.0)))
	var opex := maxf(0.0, float(proposal.get("estimatedMaintenancePerMinute", 0.0)))
	var length_km := maxf(0.0, float(proposal.get("estimatedLengthKm", 0.0)))
	var benefit := clampf(float(proposal.get("estimatedBenefitScore", 0.0)), 0.0, 1.0)

	_title.text = "%s · %s" % [project_class, label]
	_meta.text = "%s · pressure %.2f (%s) · strategic fit: %s" % [
		status,
		pressure,
		pressure_source,
		strategic_fit,
	]
	var composition_text := "Traffic composition: waiting for OD snapshot"
	if composition_available:
		composition_text = "Traffic %.0f veh/h · local %.0f%% · regional %.0f%% · through %.0f%%" % [
			flow,
			local_share * 100.0,
			regional_share * 100.0,
			through_share * 100.0,
		]
	var benefit_text := "Benefit estimate: unavailable"
	if bool(proposal.get("estimatedBenefitAvailable", false)):
		benefit_text = "V/C %.2f -> %.2f · delay %.1f -> %.1f min · diversion %.0f veh/h · benefit %d/100" % [
			vc_now,
			vc_after,
			delay_now,
			delay_after,
			diverted,
			roundi(benefit * 100.0),
		]
	_body.text = "WHY\n%s\n\nESTIMATED EFFECT\n%s\n\nINVESTMENT\nLength %.1f km · CAPEX $%s · maintenance $%.2f/min\n\nRECOMMENDATION\n%s" % [
		composition_text,
		benefit_text,
		length_km,
		_format_money(capex),
		opex,
		recommendation.to_upper(),
	]
	_update_build_button(store, proposal)


func _update_build_button(store: Node, proposal: Dictionary) -> void:
	_build_button.visible = true
	if not store.has_method("infrastructure_proposal_build_status") or not store.has_method("build_infrastructure_proposal"):
		_build_button.disabled = true
		_build_button.text = "BUILD UNAVAILABLE"
		_build_button.tooltip_text = "This build does not expose proposal construction."
		return
	var build_status_value: Variant = store.call("infrastructure_proposal_build_status", str(proposal.get("id", "")))
	var build_status: Dictionary = build_status_value if typeof(build_status_value) == TYPE_DICTIONARY else {}
	var proposal_status := str(proposal.get("status", "suggested"))
	if proposal_status == "under-construction":
		_build_button.disabled = true
		_build_button.text = "CONSTRUCTION QUEUED"
		_build_button.tooltip_text = "This corridor is already in the construction queue."
		return
	var available := bool(build_status.get("available", false))
	var reason := str(build_status.get("reason", ""))
	var cost := maxf(0.0, float(build_status.get("cost", proposal.get("estimatedConstructionCost", 0.0))))
	_build_button.disabled = not available
	_build_button.text = "BUILD · $%s" % _format_money(cost) if available else "BUILD · %s" % reason.replace("_", " ").to_upper()
	_build_button.tooltip_text = (
		"Approve this relief corridor and place it in the normal road construction queue."
		if available
		else "Cannot start this project: %s." % reason.replace("_", " ")
	)


func _build_current() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store) or not store.has_method("build_infrastructure_proposal"):
		return
	var proposals := _proposals(store.city)
	if proposals.is_empty():
		return
	_index = clampi(_index, 0, proposals.size() - 1)
	var proposal: Dictionary = proposals[_index]
	store.call("build_infrastructure_proposal", str(proposal.get("id", "")))
	_refresh_remaining = 0.0
	_refresh()


func _show_previous() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store):
		return
	var proposals := _proposals(store.city)
	if proposals.is_empty():
		return
	_index = (_index - 1 + proposals.size()) % proposals.size()
	_refresh()


func _show_next() -> void:
	var store := get_node_or_null("/root/GameStore")
	if not is_instance_valid(store):
		return
	var proposals := _proposals(store.city)
	if proposals.is_empty():
		return
	_index = (_index + 1) % proposals.size()
	_refresh()


static func _proposals(city: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for proposal_value in city.get("infrastructure_proposals", []):
		if typeof(proposal_value) != TYPE_DICTIONARY:
			continue
		var proposal: Dictionary = proposal_value
		if str(proposal.get("status", "")) == "completed":
			continue
		result.append(proposal)
	result.sort_custom(func(a, b):
		var a_active := 1 if bool(a.get("activeNeed", false)) else 0
		var b_active := 1 if bool(b.get("activeNeed", false)) else 0
		if a_active != b_active:
			return a_active > b_active
		var a_benefit := float(a.get("estimatedBenefitScore", 0.0))
		var b_benefit := float(b.get("estimatedBenefitScore", 0.0))
		if not is_equal_approx(a_benefit, b_benefit):
			return a_benefit > b_benefit
		return float(a.get("pressure", 0.0)) > float(b.get("pressure", 0.0))
	)
	return result


static func _format_money(value: float) -> String:
	var rounded := roundi(value)
	var text := str(abs(rounded))
	var grouped := ""
	while text.length() > 3:
		grouped = "," + text.substr(text.length() - 3, 3) + grouped
		text = text.substr(0, text.length() - 3)
	grouped = text + grouped
	return ("-" if rounded < 0 else "") + grouped
