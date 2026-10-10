extends SceneTree

const RegionalEconomy = preload("res://scripts/simulation/regional_economy.gd")

class EconomyStore:
	extends Node
	var money := 1000.0
	var stats: Dictionary = {
		"lifetime_revenue": 250.0,
		"lifetime_operating_costs": 100.0,
	}
	var city: Dictionary = {}
	var transit_network: Dictionary = {}


var _failures := 0


func _init() -> void:
	_test_forecast_breakdown()
	_test_historic_roads_are_not_charged()
	_test_strategic_road_uses_explicit_maintenance()
	_test_advance_charges_only_new_road_maintenance()
	_test_runway_statuses()
	if _failures > 0:
		push_error("REGIONAL ECONOMY TEST: FAIL (%d checks)" % _failures)
		quit(1)
		return
	print("REGIONAL ECONOMY TEST: PASS")
	quit(0)


func _test_forecast_breakdown() -> void:
	var store := _base_store()
	var snapshot := RegionalEconomy.evaluate(store)
	_expect(is_equal_approx(float(snapshot.get("fare_revenue_per_minute", 0.0)), 24.0), "2 pax/min at $12 produces $24/min current fare revenue")
	_expect(is_equal_approx(float(snapshot.get("transit_opex_per_minute", 0.0)), 3.0), "two active buses cost $3/min")
	_expect(is_equal_approx(float(snapshot.get("service_opex_per_minute", 0.0)), 0.5), "player service upkeep is included")
	_expect(float(snapshot.get("road_maintenance_per_minute", 0.0)) > 0.0, "player-built roads create maintenance OPEX")
	_expect(float(snapshot.get("net_per_minute", 0.0)) > 0.0, "healthy ridership produces an operating surplus")
	_expect(str(snapshot.get("status", "")) == "surplus", "positive current cashflow is classified as surplus")
	store.free()


func _test_historic_roads_are_not_charged() -> void:
	var city := {
		"roads": [
			_road("historic", "regional-existing", "arterial", 2000.0),
			_road("local-growth", "organic_growth", "local", 1800.0),
		],
	}
	_expect(is_equal_approx(RegionalEconomy.road_maintenance_per_minute(city), 0.0), "pre-existing and autonomous roads do not charge the player")


func _test_strategic_road_uses_explicit_maintenance() -> void:
	var strategic := _road("relief", "player", "arterial", 5000.0)
	strategic["maintenanceCostPerMinute"] = 1.75
	strategic["proposalId"] = "relief-a"
	var city := {"roads": [strategic]}
	_expect(is_equal_approx(RegionalEconomy.road_maintenance_per_minute(city), 1.75), "completed strategic roads charge the exact maintenance estimate shown by the proposal")
	strategic["status"] = "planned"
	city["roads"] = [strategic]
	_expect(is_equal_approx(RegionalEconomy.road_maintenance_per_minute(city), 0.0), "planned strategic roads do not charge maintenance before completion")


func _test_advance_charges_only_new_road_maintenance() -> void:
	var store := _base_store()
	store.transit_network["lines"].clear()
	store.city["service_buildings"].clear()
	var rate := RegionalEconomy.road_maintenance_per_minute(store.city)
	var money_before := store.money
	var costs_before := float(store.stats.get("lifetime_operating_costs", 0.0))
	RegionalEconomy.advance(store, 10.0)
	var expected := rate * 10.0
	_expect(is_equal_approx(money_before - store.money, expected), "advance deducts exactly player-road maintenance and does not duplicate transit/service OPEX")
	_expect(is_equal_approx(float(store.stats.get("lifetime_road_maintenance_costs", 0.0)), expected), "road maintenance receives its own lifetime counter")
	_expect(is_equal_approx(float(store.stats.get("lifetime_operating_costs", 0.0)) - costs_before, expected), "road maintenance is also part of aggregate operating costs")
	_expect(typeof(store.city.get("economy", null)) == TYPE_DICTIONARY, "advance stores a canonical economy snapshot in city state")
	store.free()


func _test_runway_statuses() -> void:
	var store := _base_store()
	var line: Dictionary = store.transit_network["lines"]["line-a"]
	line["last_delivered_ppm"] = 0.0
	line["fleet_count"] = 8
	store.transit_network["lines"]["line-a"] = line
	store.money = 200.0
	var short_runway := RegionalEconomy.evaluate(store)
	_expect(float(short_runway.get("net_per_minute", 0.0)) < 0.0, "low revenue creates negative projected cashflow")
	_expect(str(short_runway.get("status", "")) in ["stressed", "critical"], "short negative runway is surfaced as financial pressure")

	store.money = -1.0
	var soft_debt := RegionalEconomy.evaluate(store)
	_expect(str(soft_debt.get("status", "")) == "stressed", "negative treasury inside the soft-credit band is stressed rather than an instant failure")
	_expect(bool(soft_debt.get("in_debt", false)), "soft-credit snapshot marks negative treasury as debt")
	_expect(not bool(soft_debt.get("large_investment_blocked", true)), "large strategic investment remains available before the soft-credit floor is reached")

	store.money = RegionalEconomy.SOFT_CREDIT_LIMIT
	var credit_floor := RegionalEconomy.evaluate(store)
	_expect(str(credit_floor.get("status", "")) == "critical", "reaching the soft-credit floor is critical")
	_expect(bool(credit_floor.get("large_investment_blocked", false)), "large strategic investment is blocked at the soft-credit floor")
	_expect(is_equal_approx(float(credit_floor.get("credit_headroom", -1.0)), 0.0), "credit headroom reaches zero at the configured floor")
	store.free()


func _base_store() -> EconomyStore:
	var store := EconomyStore.new()
	store.city = {
		"roads": [
			_road("player-road", "player", "collector", 2000.0),
			_road("historic-road", "regional-existing", "arterial", 6000.0),
		],
		"service_buildings": [{
			"id": "clinic-a",
			"source": "player",
			"status": "operational",
			"operatingCostPerMinute": 0.5,
		}],
	}
	store.transit_network = {
		"lines": {
			"line-a": {
				"id": "line-a",
				"source": "custom",
				"status": "active",
				"mode": "bus",
				"fleet_count": 2,
				"last_delivered_ppm": 2.0,
			},
		},
	}
	return store


func _road(id: String, source: String, road_class: String, length: float) -> Dictionary:
	return {
		"id": id,
		"source": source,
		"status": "built",
		"class": road_class,
		"points": [Vector2(0.0, 0.0), Vector2(length, 0.0)],
	}


func _expect(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Regional economy: %s" % description)
