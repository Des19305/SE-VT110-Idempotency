extends "res://tests/test_case.gd"
## Unit, property and determinism tests for the generator (architecture.md §6.5, §8).

const DungeonGenerator := preload("res://scripts/generation/dungeon_generator.gd")

const CONFIG := {
	"width": 50,
	"height": 50,
	"min_rooms": 8,
	"max_rooms": 12,
	"min_room_size": 5,
	"max_room_size": 10,
}
## 30 x 30 map for debugging; BSP fits only a few rooms at this size.
const DEBUG_CONFIG := {
	"width": 30,
	"height": 30,
	"min_rooms": 2,
	"max_rooms": 4,
	"min_room_size": 3,
	"max_room_size": 6,
}
## Layout of seed 12345 with CONFIG, recorded from generator version 1 (commit 4f92e44).
const PINNED_ROOM_COUNT := 9
const PINNED_START := Vector2i(8, 9)
const PINNED_BOSS := Vector2i(43, 41)
const PINNED_TILES_HASH := 2385262456


func test_same_seed_and_config_produce_identical_layout() -> void:
	var first := DungeonGenerator.generate_dungeon(12345, CONFIG)
	var second := DungeonGenerator.generate_dungeon(12345, CONFIG)
	check(first["ok"], "first generation failed: %s" % first["error"])
	check_eq(second["tiles"], first["tiles"], "tiles")
	check_eq(second["rooms"], first["rooms"], "rooms")
	check_eq(second["start_cell"], first["start_cell"], "start_cell")
	check_eq(second["boss_cell"], first["boss_cell"], "boss_cell")


func test_result_respects_config() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(7, CONFIG)
	check(dungeon["ok"], "generation failed: %s" % dungeon["error"])
	check_eq(dungeon["seed"], 7, "seed")
	check_eq(dungeon["tiles"].size(), CONFIG["height"], "row count")
	check_eq(dungeon["tiles"][0].size(), CONFIG["width"], "column count")
	var room_count: int = dungeon["rooms"].size()
	check(room_count >= CONFIG["min_rooms"] and room_count <= CONFIG["max_rooms"], "room count %d out of range" % room_count)
	for room in dungeon["rooms"]:
		var size: Vector2i = room["size"]
		check(size.x >= CONFIG["min_room_size"] and size.x <= CONFIG["max_room_size"], "room width %d out of range" % size.x)
		check(size.y >= CONFIG["min_room_size"] and size.y <= CONFIG["max_room_size"], "room height %d out of range" % size.y)


func test_many_seeds_produce_valid_dungeons() -> void:
	for seed_value in range(0, 200):
		var dungeon := DungeonGenerator.generate_dungeon(seed_value, CONFIG)
		if not dungeon["ok"]:
			failures.append("seed %d config %s: %s" % [seed_value, CONFIG, dungeon["error"]])
			continue
		var check_result := DungeonGenerator.validate_dungeon(dungeon)
		check(check_result["valid"], "seed %d config %s: %s" % [seed_value, CONFIG, check_result["errors"]])


func test_impossible_config_returns_explicit_failure() -> void:
	var config := CONFIG.duplicate()
	config["width"] = 20
	config["height"] = 20
	config["min_rooms"] = 12
	config["max_room_size"] = 5
	var dungeon := DungeonGenerator.generate_dungeon(1, config)
	check(not dungeon["ok"], "expected failure")
	check_eq(dungeon["error"], "GENERATION_FAILED", "error code")
	check(dungeon["error_message"].begins_with("No valid dungeon after 10 attempts"), "message was: %s" % dungeon["error_message"])
	check(dungeon["tiles"].is_empty(), "failed result must not carry a layout")


func test_validator_rejects_unreachable_boss() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	var tiles: Array = dungeon["tiles"]
	var boss: Vector2i = dungeon["boss_cell"]
	# Wall off the boss cell completely.
	for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var cell: Vector2i = boss + step
		tiles[cell.y][cell.x] = DungeonGenerator.WALL
	var result := DungeonGenerator.validate_dungeon(dungeon)
	check(not result["valid"], "expected invalid dungeon")
	check(result["errors"].has("boss_cell is not reachable from start_cell"), "errors were: %s" % [result["errors"]])


func test_validator_rejects_wrong_grid_size() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	dungeon["tiles"].pop_back()
	var result := DungeonGenerator.validate_dungeon(dungeon)
	check(not result["valid"], "expected invalid dungeon")
	check_eq(result["errors"], ["grid has 49 rows, expected 50"], "errors")


func test_result_carries_generator_version() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(7, CONFIG)
	check_eq(dungeon["generator_version"], DungeonGenerator.GENERATOR_VERSION, "generator_version")


func test_known_seed_layout_is_unchanged() -> void:
	# Pins the layout for one seed so an accidental change to the RNG call order
	# fails here; update the expected values together with GENERATOR_VERSION.
	var dungeon := DungeonGenerator.generate_dungeon(12345, CONFIG)
	check_eq(dungeon["rooms"].size(), PINNED_ROOM_COUNT, "room count")
	check_eq(dungeon["start_cell"], PINNED_START, "start_cell")
	check_eq(dungeon["boss_cell"], PINNED_BOSS, "boss_cell")
	check_eq(hash(dungeon["tiles"]), PINNED_TILES_HASH, "tiles hash")


func test_small_debug_config_produces_valid_dungeons() -> void:
	for seed_value in range(0, 100):
		var dungeon := DungeonGenerator.generate_dungeon(seed_value, DEBUG_CONFIG)
		if not dungeon["ok"]:
			failures.append("seed %d config %s: %s" % [seed_value, DEBUG_CONFIG, dungeon["error_message"]])
			continue
		var result := DungeonGenerator.validate_dungeon(dungeon, DEBUG_CONFIG)
		check(result["valid"], "seed %d config %s: %s" % [seed_value, DEBUG_CONFIG, result["errors"]])


# --- config validation ------------------------------------------------------

func test_invalid_configs_are_rejected_without_crashing() -> void:
	var cases := {
		"missing key": _without(CONFIG, "height"),
		"non-integer": _with(CONFIG, "width", 50.0),
		"string value": _with(CONFIG, "min_rooms", "8"),
		"zero": _with(CONFIG, "min_room_size", 0),
		"negative": _with(CONFIG, "width", -50),
		"min_rooms > max_rooms": _with(CONFIG, "min_rooms", 13),
		"min_room_size > max_room_size": _with(CONFIG, "min_room_size", 11),
		"room larger than map": _with(_with(CONFIG, "width", 9), "min_room_size", 3),
		"bad max_attempts": _with(CONFIG, "max_attempts", 0),
		"empty": {},
	}
	for name in cases:
		var dungeon := DungeonGenerator.generate_dungeon(1, cases[name])
		check(not dungeon["ok"], "%s: expected failure" % name)
		check_eq(dungeon["error"], "INVALID_CONFIG", "%s: error code" % name)
		check(dungeon["error_message"] != "", "%s: error_message must explain the problem" % name)
		check(dungeon["tiles"].is_empty(), "%s: no layout on failure" % name)


func test_failure_result_keeps_contract_keys() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, {})
	for key in ["ok", "error", "error_message", "seed", "width", "height", "tiles", "rooms", "start_cell", "boss_cell"]:
		check(dungeon.has(key), "missing key on failure: %s" % key)
	check_eq(dungeon["seed"], 3, "seed")


# --- validator --------------------------------------------------------------

func test_validator_accepts_generated_dungeon_with_config() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(11, CONFIG)
	var result := DungeonGenerator.validate_dungeon(dungeon, CONFIG)
	check(result["valid"], "errors: %s" % [result["errors"]])


func test_validator_rejects_tile_values_other_than_0_and_1() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	dungeon["tiles"][0][0] = 2
	_expect_invalid(DungeonGenerator.validate_dungeon(dungeon), "tile (0, 0) must be 0 or 1")


func test_validator_rejects_overlapping_rooms() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	dungeon["rooms"].append(dungeon["rooms"][0].duplicate())
	_expect_invalid(DungeonGenerator.validate_dungeon(dungeon), "overlaps another room")


func test_validator_checks_room_count_against_config() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	var config := _with(CONFIG, "min_rooms", dungeon["rooms"].size() + 1)
	config["max_rooms"] = 20
	_expect_invalid(DungeonGenerator.validate_dungeon(dungeon, config), "room count")


func test_validator_checks_room_size_against_config() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	var config := _with(CONFIG, "max_room_size", 5)
	_expect_invalid(DungeonGenerator.validate_dungeon(dungeon, config), "is outside 5-5")


func test_validator_rejects_disconnected_walkable_tile() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	dungeon["tiles"][0][0] = DungeonGenerator.FLOOR  # border tile, never connected
	_expect_invalid(DungeonGenerator.validate_dungeon(dungeon), "disconnected from start_cell")


func test_validator_rejects_start_equal_to_boss() -> void:
	var dungeon := DungeonGenerator.generate_dungeon(3, CONFIG)
	dungeon["boss_cell"] = dungeon["start_cell"]
	_expect_invalid(DungeonGenerator.validate_dungeon(dungeon), "start_cell and boss_cell are the same cell")


func test_validator_survives_malformed_input() -> void:
	var cases := {
		"empty": {},
		"string sizes": {"width": "2", "height": 1, "tiles": [], "rooms": [], "start_cell": Vector2i.ZERO, "boss_cell": Vector2i.ONE},
		"tiles not array": {"width": 2, "height": 1, "tiles": "xx", "rooms": [], "start_cell": Vector2i.ZERO, "boss_cell": Vector2i.ONE},
		"row not array": {"width": 2, "height": 1, "tiles": [7], "rooms": [], "start_cell": Vector2i.ZERO, "boss_cell": Vector2i.ONE},
		"string tile": {"width": 2, "height": 1, "tiles": [[1, "x"]], "rooms": [], "start_cell": Vector2i.ZERO, "boss_cell": Vector2i.ONE},
		"room not dict": {"width": 2, "height": 1, "tiles": [[1, 1]], "rooms": ["bad"], "start_cell": Vector2i.ZERO, "boss_cell": Vector2i(1, 0)},
		"room wrong types": {"width": 2, "height": 1, "tiles": [[1, 1]], "rooms": [{"position": [0, 0], "size": 3}], "start_cell": Vector2i.ZERO, "boss_cell": Vector2i(1, 0)},
		"cell not Vector2i": {"width": 2, "height": 1, "tiles": [[1, 1]], "rooms": [], "start_cell": 3, "boss_cell": Vector2i(1, 0)},
		"rooms not array": {"width": 2, "height": 1, "tiles": [[1, 1]], "rooms": null, "start_cell": Vector2i.ZERO, "boss_cell": Vector2i(1, 0)},
	}
	for name in cases:
		var result := DungeonGenerator.validate_dungeon(cases[name])
		check(not result["valid"], "%s: expected invalid" % name)
		check(not result["errors"].is_empty(), "%s: expected an error message" % name)


# --- helpers ----------------------------------------------------------------

func _expect_invalid(result: Dictionary, expected_fragment: String) -> void:
	check(not result["valid"], "expected invalid: %s" % expected_fragment)
	check(result["errors"].any(func(e): return e.contains(expected_fragment)),
		"no error containing '%s' in %s" % [expected_fragment, result["errors"]])


func _with(config: Dictionary, key: String, value: Variant) -> Dictionary:
	var copy := config.duplicate()
	copy[key] = value
	return copy


func _without(config: Dictionary, key: String) -> Dictionary:
	var copy := config.duplicate()
	copy.erase(key)
	return copy
