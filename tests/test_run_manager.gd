extends "res://tests/test_case.gd"
## Characterization tests for RunManager.start_new_run / replay_last_run / end_run.
## They pin the observable behavior (result dictionary, error messages, signals,
## files written) so the start_new_run refactoring can be checked against them.

const RunManager := preload("res://scripts/run_management/run_manager.gd")

const CONFIG := {
	"width": 50,
	"height": 50,
	"min_rooms": 8,
	"max_rooms": 12,
	"min_room_size": 5,
	"max_room_size": 10,
}
const RETENTION_SECONDS := 70 * 86400

var manager: Node
var records_dir: String
var started_events: Array = []
var ended_events: Array = []
var signal_mutation_listener_called := false


func before_each() -> void:
	records_dir = "user://test_runs/%d" % Time.get_ticks_usec()
	signal_mutation_listener_called = false
	manager = RunManager.new()
	manager.records_dir = records_dir
	manager.run_started.connect(func(seed_value, dungeon): started_events.append([seed_value, dungeon]))
	manager.run_ended.connect(func(won, reason): ended_events.append([won, reason]))


func after_each() -> void:
	manager.free()
	_remove_dir("user://test_runs")



class FaultInjectionRepository:
	extends "res://scripts/run_management/run_record_repository.gd"
	var failure_stage := ""
	var failure_injected := false
	var record_existed_at_failure := false
	var partial_write_observed := false
	var staged_pointer_complete := false
	var expected_old_pointer := ""
	var old_pointer_backed_up := false

	func _write(file_name: String, record: Dictionary) -> String:
		if failure_stage == "temp_write" and file_name.begins_with("last_run"):
			failure_injected = true
			record_existed_at_failure = FileAccess.file_exists(records_dir.path_join(record["run_id"] + ".json"))
			var file := FileAccess.open(records_dir.path_join(file_name), FileAccess.WRITE)
			if file == null:
				return "Fixture could not open staged pointer"
			file.store_string("{\"run_id\":")
			file.flush()
			var write_error := file.get_error()
			file.close()
			var staged_content := FileAccess.get_file_as_string(records_dir.path_join(file_name))
			partial_write_observed = staged_content == "{\"run_id\":"
			staged_pointer_complete = staged_content.begins_with("{") and staged_content.ends_with("}")
			return "Injected staged pointer write failure"
		return super._write(file_name, record)

	func _replace_pointer_file(temp_path: String, pointer_path: String) -> String:
		if failure_stage == "replace":
			failure_injected = true
			record_existed_at_failure = _record_file_exists_for_test()
			var staged_content := FileAccess.get_file_as_string(temp_path)
			staged_pointer_complete = FileAccess.file_exists(temp_path) and staged_content.begins_with("{") and staged_content.ends_with("}")
			var backup_path := pointer_path + ".bak"
			old_pointer_backed_up = FileAccess.file_exists(backup_path) and FileAccess.get_file_as_string(backup_path) == expected_old_pointer
			return "Injected pointer replacement failure"
		return super._replace_pointer_file(temp_path, pointer_path)

	func _record_file_exists_for_test() -> bool:
		var dir := DirAccess.open(records_dir)
		if dir == null:
			return false
		for file_name in dir.get_files():
			if file_name.ends_with(".json") and file_name != LAST_RUN_FILE:
				return true
		return false


class FaultInjectionRunManager:
	extends "res://scripts/run_management/run_manager.gd"
	var repository_override

	func _repository() -> RunRecordRepository:
		return repository_override
# --- happy path -------------------------------------------------------------

func test_start_returns_valid_dungeon_and_emits_signal() -> void:
	var result: Dictionary = manager.start_new_run("legacy-happy-start", 42, CONFIG)
	check(result["ok"], "start failed: %s" % result["error"])
	check_eq(result["error"], "", "error")
	check_eq(result["seed"], 42, "seed")
	check(result["dungeon"]["ok"], "dungeon not ok")
	check_eq(started_events.size(), 1, "run_started count")
	check_eq(started_events[0][0], 42, "run_started seed")


func test_start_writes_run_record_with_70_day_retention() -> void:
	manager.start_new_run("legacy-persist-record", 42, CONFIG)
	var record: Dictionary = manager.current_run
	var path := records_dir.path_join(record["run_id"] + ".json")
	check(FileAccess.file_exists(path), "run record file missing")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	check_eq(int(saved["seed"]), 42, "saved seed")
	check_eq(saved["status"], "in_progress", "saved status")
	check_eq(int(saved["generation_version"]), 1, "generation_version")
	check_eq(int(saved["expires_at"]) - int(saved["created_at"]), RETENTION_SECONDS, "retention")
	check_eq(int(saved["config"]["max_attempts"]), 10, "default max_attempts stored")
	check(FileAccess.file_exists(records_dir.path_join("last_run.json")), "last_run.json missing")


func test_caller_config_is_not_mutated() -> void:
	var config := CONFIG.duplicate()
	manager.start_new_run("legacy-copy-config", 42, config)
	check(not config.has("max_attempts"), "start_new_run must copy the config")


# --- validation -------------------------------------------------------------

func test_rejects_negative_seed() -> void:
	_expect_rejected(manager.start_new_run("legacy-negative-seed", -1, CONFIG), "Seed must be non-negative")


func test_rejects_missing_config_key() -> void:
	var config := CONFIG.duplicate()
	config.erase("min_rooms")
	_expect_rejected(manager.start_new_run("legacy-missing-key", 1, config), "Missing config key: min_rooms")


func test_rejects_non_integer_config_value() -> void:
	var config := CONFIG.duplicate()
	config["width"] = 50.0
	_expect_rejected(manager.start_new_run("legacy-non-integer", 1, config), "Config key width must be an integer")


func test_rejects_out_of_range_size() -> void:
	var config := CONFIG.duplicate()
	config["height"] = 201
	_expect_rejected(manager.start_new_run("legacy-out-of-range-size", 1, config), "Dungeon size must be between 20 and 200 tiles")


func test_rejects_invalid_room_count_range() -> void:
	var config := CONFIG.duplicate()
	config["min_rooms"] = 13
	_expect_rejected(manager.start_new_run("legacy-invalid-room-count", 1, config), "Room count range is invalid")


func test_rejects_fewer_than_two_rooms() -> void:
	var config := CONFIG.duplicate()
	config["min_rooms"] = 1
	_expect_rejected(manager.start_new_run("legacy-fewer-than-two-rooms", 1, config), "Room count range is invalid")


func test_rejects_rooms_smaller_than_three_tiles() -> void:
	var config := CONFIG.duplicate()
	config["min_room_size"] = 2
	_expect_rejected(manager.start_new_run("legacy-room-too-small", 1, config), "Room size range is invalid")


func test_accepts_smallest_supported_dungeon() -> void:
	var config := {"width": 20, "height": 20, "min_rooms": 2, "max_rooms": 4, "min_room_size": 3, "max_room_size": 5}
	var result: Dictionary = manager.start_new_run("legacy-smallest-dungeon", 1, config)
	check(result["ok"], "20x20 should be accepted: %s" % result["error"])


func test_rejects_invalid_room_size_range() -> void:
	var config := CONFIG.duplicate()
	config["min_room_size"] = 11
	_expect_rejected(manager.start_new_run("legacy-invalid-room-size", 1, config), "Room size range is invalid")


func test_rejects_rooms_that_do_not_fit() -> void:
	var config := CONFIG.duplicate()
	config["width"] = 20
	config["max_room_size"] = 11
	_expect_rejected(manager.start_new_run("legacy-rooms-do-not-fit", 1, config), "Rooms do not fit in the dungeon")


func test_rejects_start_while_run_in_progress() -> void:
	manager.start_new_run("legacy-active-run", 1, CONFIG)
	var result: Dictionary = manager.start_new_run("legacy-second-run", 2, CONFIG)
	check(not result["ok"], "second start should fail")
	check_eq(result["error"], "A run is already in progress", "error")
	check_eq(started_events.size(), 1, "run_started count")


# --- business rules ---------------------------------------------------------

func test_generation_failure_starts_no_run() -> void:
	var config := CONFIG.duplicate()
	config["width"] = 20
	config["height"] = 20
	config["min_rooms"] = 12
	config["max_room_size"] = 5
	var result: Dictionary = manager.start_new_run("legacy-generation-failure", 1, config)
	check(not result["ok"], "expected failure")
	check(result["error"].begins_with("Generation failed: No valid dungeon after 10 attempts"), "error was: %s" % result["error"])
	check(manager.current_run.is_empty(), "current_run must stay empty")
	check(not DirAccess.dir_exists_absolute(records_dir), "no record may be written")
	check_eq(started_events.size(), 0, "run_started count")


func test_replay_regenerates_identical_layout() -> void:
	var first: Dictionary = manager.start_new_run("legacy-replay-first", 99, CONFIG)
	manager.end_run(false, "player died")
	var replay: Dictionary = manager.replay_last_run()
	check(replay["ok"], "replay failed: %s" % replay["error"])
	check_eq(replay["seed"], 99, "replay seed")
	check_eq(replay["dungeon"]["tiles"], first["dungeon"]["tiles"], "replay tiles")
	check_eq(replay["dungeon"]["boss_cell"], first["dungeon"]["boss_cell"], "replay boss_cell")


func test_replay_without_previous_run_fails() -> void:
	var result: Dictionary = manager.replay_last_run()
	check(not result["ok"], "expected failure")
	check_eq(result["error"], "No previous run to replay", "error")


func test_end_run_updates_record_and_emits_signal() -> void:
	manager.start_new_run("legacy-end-run", 5, CONFIG)
	var run_id: String = manager.current_run["run_id"]
	manager.end_run(true, "boss defeated")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(records_dir.path_join(run_id + ".json")))
	check_eq(saved["status"], "completed", "status")
	check_eq(saved["won"], true, "won")
	check_eq(saved["reason"], "boss defeated", "reason")
	check(manager.current_run.is_empty(), "current_run cleared")
	check_eq(ended_events, [[true, "boss defeated"]], "run_ended events")


# --- persistence ------------------------------------------------------------

func test_expired_records_are_pruned_and_fresh_ones_kept() -> void:
	DirAccess.make_dir_recursive_absolute(records_dir)
	var now := int(Time.get_unix_time_from_system())
	_write_json(records_dir.path_join("old.json"), {"run_id": "old", "expires_at": now - 1})
	_write_json(records_dir.path_join("fresh.json"), {"run_id": "fresh", "expires_at": now + 3600})
	manager.start_new_run("legacy-pruning", 8, CONFIG)
	check(not FileAccess.file_exists(records_dir.path_join("old.json")), "expired record should be removed")
	check(FileAccess.file_exists(records_dir.path_join("fresh.json")), "fresh record should be kept")


func test_storage_failure_blocks_run_start() -> void:
	# A file where the records directory should be makes the directory unwritable.
	DirAccess.make_dir_recursive_absolute("user://test_runs")
	_write_json("user://test_runs/blocker", {})
	manager.records_dir = "user://test_runs/blocker/runs"
	expect_error("Could not create directory")
	var result: Dictionary = manager.start_new_run("legacy-storage-failure", 8, CONFIG)
	check(not result["ok"], "current behavior: storage failure rejects the run")
	check(result["error"].begins_with("Cannot save run record"), "error was: %s" % result["error"])
	check(manager.current_run.is_empty(), "current_run must stay empty")
	check_eq(started_events.size(), 0, "run_started count")



func test_persistence_temp_pointer_write_failure_rolls_back_record_and_keeps_old_pointer() -> void:
	var repo = _use_failure_injection("temp_write")
	var pointer_path := records_dir.path_join("last_run.json")
	var old_pointer := "{\"run_id\":\"previous\",\"marker\":\"preserve-me\"}"
	_write_text(pointer_path, old_pointer)
	var result: Dictionary = manager.start_new_run("request-temp-write-failure", 31, CONFIG)
	check(repo.failure_injected, "fixture must fail while writing the staged pointer")
	check(repo.record_existed_at_failure, "record must already be written when staged-pointer failure is injected")
	check(repo.partial_write_observed, "fixture must write partial pointer bytes before returning the injected error")
	check(not repo.staged_pointer_complete, "fixture must stop the staged-pointer write before completion")
	check(not result.get("ok", false), "staged-pointer write failure must reject run start")
	check_eq(_record_ids().size(), 0, "failed request record rollback")
	check_eq(FileAccess.get_file_as_string(pointer_path), old_pointer, "old pointer content after staged-write failure")
	check_eq(started_events.size(), 0, "run_started after staged-write failure")
	repo.failure_stage = ""
	var retry: Dictionary = manager.start_new_run("request-temp-write-failure", 31, CONFIG)
	check(retry.get("ok", false), "retry must be accepted after persistence failure: %s" % retry.get("error", "missing result"))
	check_eq(_record_ids().size(), 1, "record count after retry")
	check_eq(started_events.size(), 1, "run_started after retry")


func test_persistence_pointer_replacement_failure_rolls_back_record_and_keeps_old_pointer() -> void:
	var repo = _use_failure_injection("replace")
	var pointer_path := records_dir.path_join("last_run.json")
	var old_pointer := "{\"run_id\":\"previous\",\"marker\":\"preserve-me\"}"
	_write_text(pointer_path, old_pointer)
	repo.expected_old_pointer = old_pointer
	var result: Dictionary = manager.start_new_run("request-replace-failure", 32, CONFIG)
	check(repo.failure_injected, "fixture must fail at the pointer replacement step")
	check(repo.record_existed_at_failure, "record must already be written when replacement failure is injected")
	check(repo.staged_pointer_complete, "a complete staged pointer must exist before replacement failure")
	check(repo.old_pointer_backed_up, "old pointer must be moved to backup before promotion failure is injected")
	check(not result.get("ok", false), "pointer replacement failure must reject run start")
	check_eq(_record_ids().size(), 0, "failed request record rollback")
	check_eq(FileAccess.get_file_as_string(pointer_path), old_pointer, "old pointer content after replacement failure")
	check_eq(started_events.size(), 0, "run_started after replacement failure")
	repo.failure_stage = ""
	var retry: Dictionary = manager.start_new_run("request-replace-failure", 32, CONFIG)
	check(retry.get("ok", false), "retry must be accepted after persistence failure: %s" % retry.get("error", "missing result"))
	check_eq(_record_ids().size(), 1, "record count after retry")
	check_eq(started_events.size(), 1, "run_started after retry")


func test_signal_listener_and_caller_mutations_do_not_change_cached_result() -> void:
	manager.run_started.connect(_mutate_signal_dungeon)
	var first: Dictionary = manager.start_new_run("request-signal-mutation", 33, CONFIG)
	var original_snapshot: Dictionary = first.duplicate(true)
	check(first.get("ok", false), "first request should start")
	check(signal_mutation_listener_called, "mutating signal listener must run")
	check(not first["dungeon"].has("listener_mutation_probe"), "listener must not mutate caller result dictionary")
	check(not first["dungeon"]["tiles"].has("listener_nested_probe"), "listener must not mutate nested caller result data")
	first["dungeon"]["caller_mutation_probe"] = true
	first["dungeon"]["tiles"].append("caller_nested_probe")
	var retry: Dictionary = manager.start_new_run("request-signal-mutation", 33, CONFIG)
	check(retry == original_snapshot, "retry result must match pre-caller-mutation snapshot")
	check(not retry["dungeon"].has("caller_mutation_probe"), "caller dictionary mutation must not reach cache")
	check(not retry["dungeon"]["tiles"].has("caller_nested_probe"), "caller nested mutation must not reach cache")
	check_eq(_record_ids().size(), 1, "record count after retry")
	check_eq(started_events.size(), 1, "run_started count after retry")


func test_run_ids_are_unique_for_sequential_runs_with_fixed_clock_and_seed() -> void:
	manager.clock = func() -> int: return 123456789
	var run_ids: Array[String] = []
	for index in range(3):
		var result: Dictionary = manager.start_new_run("request-fixed-clock-%d" % index, 34, CONFIG)
		check(result.get("ok", false), "sequential run %d should start: %s" % [index, result.get("error", "missing result")])
		run_ids.append(str(manager.current_run["run_id"]))
		if index < 2:
			manager.end_run(false, "fixed-clock sequence")
	check_eq(run_ids.size(), 3, "run ID sample count")
	check(run_ids[0] != run_ids[1] and run_ids[1] != run_ids[2] and run_ids[0] != run_ids[2], "same clock and seed must produce distinct sequential run IDs")
	check_eq(_record_ids().size(), 3, "record count for fixed-clock sequence")
# --- request idempotency contract (expected to fail until RunManager supports it) ---

func test_idempotency_new_request_creates_run() -> void:
	if not _require_request_api():
		return
	var result: Dictionary = _start_request("request-new", 21, CONFIG)
	check(result.get("ok", false), "new request should start: %s" % result.get("error", "missing result"))
	check_eq(result.get("seed", -1), 21, "result seed")
	check_eq(started_events.size(), 1, "run_started count")
	check_eq(_record_ids().size(), 1, "record count")
	check_eq(manager.current_run.get("run_id", ""), _record_ids()[0], "record identity")


func test_idempotency_same_request_and_payload_returns_previous_result() -> void:
	if not _require_request_api():
		return
	var first: Dictionary = _start_request("request-retry", 22, CONFIG)
	var first_id: String = manager.current_run.get("run_id", "")
	check_eq(manager.current_run.get("status", ""), "in_progress", "first run remains active before retry")
	var retry: Dictionary = _start_request("request-retry", 22, CONFIG)
	check_eq(retry, first, "retry result")
	check_eq(manager.current_run.get("run_id", ""), first_id, "run identity")
	check_eq(manager.current_run.get("status", ""), "in_progress", "retry leaves first run active")
	check_eq(_record_ids().size(), 1, "record count")
	check_eq(started_events.size(), 1, "run_started count")


func test_idempotency_different_requests_create_independent_runs() -> void:
	if not _require_request_api():
		return
	var first: Dictionary = _start_request("request-a", 23, CONFIG)
	var first_id: String = manager.current_run.get("run_id", "")
	# Mark the returned dictionary so the second key cannot accidentally reuse it.
	first["request_a_probe"] = true
	manager.end_run(false, "first complete")
	var second: Dictionary = _start_request("request-b", 23, CONFIG)
	check(first.get("ok", false) and second.get("ok", false), "both requests should start")
	check(manager.current_run.get("run_id", "") != first_id, "independent requests need distinct records")
	check(not second.has("request_a_probe"), "different request must receive its own result")
	check_eq(_record_ids().size(), 2, "record count")
	check_eq(started_events.size(), 2, "run_started count")


func test_idempotency_same_request_with_different_payload_is_rejected_and_preserves_result() -> void:
	if not _require_request_api():
		return
	var first: Dictionary = _start_request("request-conflict", 24, CONFIG)
	var first_id: String = manager.current_run.get("run_id", "")
	var changed_config := CONFIG.duplicate(true)
	changed_config["width"] = 60
	var conflict: Dictionary = _start_request("request-conflict", 24, changed_config)
	check(not conflict.get("ok", false), "changed payload must be rejected")
	check_eq(manager.current_run.get("run_id", ""), first_id, "original run identity")
	check_eq(_record_ids().size(), 1, "record count")
	check_eq(started_events.size(), 1, "run_started count")
	var retry: Dictionary = _start_request("request-conflict", 24, CONFIG)
	check_eq(retry, first, "original result remains available")


func test_idempotency_replay_uses_a_fresh_request_and_creates_new_run() -> void:
	if not _require_request_api():
		return
	var first: Dictionary = _start_request("request-before-replay", 25, CONFIG)
	var first_id: String = manager.current_run.get("run_id", "")
	manager.end_run(false, "replay setup")
	var replay: Dictionary = manager.replay_last_run()
	check(replay.get("ok", false), "replay should start: %s" % replay.get("error", "missing result"))
	check_eq(replay.get("seed", -1), first.get("seed", -2), "replay seed")
	check_eq(replay.get("dungeon", {}).get("tiles", []), first.get("dungeon", {}).get("tiles", []), "replay layout")
	check(manager.current_run.get("run_id", "") != first_id, "replay should create a fresh run")
	check_eq(_record_ids().size(), 2, "record count")
	check_eq(started_events.size(), 2, "run_started count")
	var replay_id: String = manager.current_run.get("run_id", "")
	var original_retry: Dictionary = _start_request("request-before-replay", 25, CONFIG)
	check_eq(original_retry, first, "replay must not replace the original request result")
	check_eq(manager.current_run.get("run_id", ""), replay_id, "retry leaves replay run current")
	check_eq(started_events.size(), 2, "retrying original request must not emit another signal")


func test_idempotency_rejects_empty_request_id_without_side_effects() -> void:
	if not _require_request_api():
		return
	var result: Dictionary = _start_request("", 26, CONFIG)
	check(not result.get("ok", false), "empty request ID should be rejected")
	check(manager.current_run.is_empty(), "current_run must stay empty")
	check_eq(_record_ids().size(), 0, "record count")
	check_eq(started_events.size(), 0, "run_started count")


func test_idempotency_rejects_invalid_payload_without_claiming_request_id() -> void:
	if not _require_request_api():
		return
	var invalid_config := CONFIG.duplicate(true)
	invalid_config.erase("min_rooms")
	var rejected: Dictionary = _start_request("request-invalid", 27, invalid_config)
	check(not rejected.get("ok", false), "invalid payload should be rejected")
	check(manager.current_run.is_empty(), "current_run must stay empty")
	check_eq(_record_ids().size(), 0, "record count")
	check_eq(started_events.size(), 0, "run_started count")
	var valid_retry: Dictionary = _start_request("request-invalid", 27, CONFIG)
	check(valid_retry.get("ok", false), "valid retry should be accepted: %s" % valid_retry.get("error", "missing result"))
	check_eq(_record_ids().size(), 1, "record count after valid retry")
	check_eq(started_events.size(), 1, "run_started count after valid retry")



func _mutate_signal_dungeon(_seed: int, dungeon: Dictionary) -> void:
	signal_mutation_listener_called = true
	dungeon["listener_mutation_probe"] = true
	if dungeon.get("tiles") is Array:
		dungeon["tiles"].append("listener_nested_probe")


func _use_failure_injection(stage: String):
	manager.free()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(records_dir))
	var fault_manager := FaultInjectionRunManager.new()
	fault_manager.records_dir = records_dir
	var repo := FaultInjectionRepository.new(records_dir)
	repo.failure_stage = stage
	fault_manager.repository_override = repo
	manager = fault_manager
	manager.run_started.connect(func(seed_value, dungeon): started_events.append([seed_value, dungeon]))
	manager.run_ended.connect(func(won, reason): ended_events.append([won, reason]))
	return repo


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.flush()
	file.close()
# --- helpers ----------------------------------------------------------------

func _expect_rejected(result: Dictionary, expected_error: String) -> void:
	check(not result["ok"], "expected rejection: %s" % expected_error)
	check_eq(result["error"], expected_error, "error")
	check(manager.current_run.is_empty(), "current_run must stay empty")
	check(not DirAccess.dir_exists_absolute(records_dir), "no record may be written")
	check_eq(started_events.size(), 0, "run_started count")


func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()


func _require_request_api() -> bool:
	for method in manager.get_method_list():
		if method["name"] != "start_new_run":
			continue
		var argument_names: Array[String] = []
		for argument in method["args"]:
			argument_names.append(argument.get("name", ""))
		if argument_names == ["request_id", "seed", "config"]:
			return true
	check(false, "RunManager API must be start_new_run(request_id, seed, config) in that order")
	return false


func _start_request(request_id: String, seed: int, config: Dictionary) -> Dictionary:
	return manager.call("start_new_run", request_id, seed, config)


func _record_ids() -> Array[String]:
	var ids: Array[String] = []
	var dir := DirAccess.open(records_dir)
	if dir == null:
		return ids
	for file_name in dir.get_files():
		if file_name.ends_with(".json") and file_name != "last_run.json":
			ids.append(file_name.trim_suffix(".json"))
	ids.sort()
	return ids


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_dir(path.path_join(sub))
	for file_name in dir.get_files():
		dir.remove(file_name)
	DirAccess.remove_absolute(path)
