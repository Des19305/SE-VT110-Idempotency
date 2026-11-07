extends Node
## Run Management: starts runs, retains seed + config for replay and stores the
## run record (AC-SEED-01). Public API follows docs/architecture.md §7.3.
##
## Owns the run rules (one run at a time, retry default, retention period).
## Input checks live in RunConfigValidator, file storage in RunRecordRepository.

signal run_started(seed: int, dungeon: Dictionary)
signal run_ended(won: bool, reason: String)

const DungeonGenerator := preload("res://scripts/generation/dungeon_generator.gd")
const RunConfigValidator := preload("res://scripts/run_management/run_config_validator.gd")
const RunRecordRepository := preload("res://scripts/run_management/run_record_repository.gd")

const RECORD_RETENTION_DAYS := 70
const SECONDS_PER_DAY := 86400
const GENERATION_VERSION := 1

var records_dir := "user://runs"
## Returns the current Unix time in seconds; replaceable in tests.
var clock: Callable = func() -> int: return int(Time.get_unix_time_from_system())
var current_run := {}
var last_run := {}
## Successful start results are cached only for this RunManager/game session.
var _request_cache: Dictionary = {}
var _run_id_sequence := 0
var _replay_request_sequence := 0


func start_new_run(request_id: String, seed: int, config: Dictionary) -> Dictionary:
	if request_id.strip_edges().is_empty():
		return _rejected(seed, "Request ID must not be empty")

	# Copy and normalize before comparing so caller mutations cannot change the
	# payload associated with a successful request.
	var run_config := _with_defaults(config)
	var payload := {"seed": seed, "config": run_config.duplicate(true)}
	if _request_cache.has(request_id):
		var cached: Dictionary = _request_cache[request_id]
		if cached["payload"] == payload:
			return cached["result"].duplicate(true)
		return _rejected(seed, "Request ID already used with a different payload")

	if current_run.get("status", "") == "in_progress":
		return _rejected(seed, "A run is already in progress")
	var config_error := RunConfigValidator.validate(seed, config)
	if config_error != "":
		return _rejected(seed, config_error)

	var generated := _generate_valid_dungeon(seed, run_config)
	if generated["error"] != "":
		return _rejected(seed, generated["error"])

	var record := _new_record(seed, run_config, clock.call())
	var save_error := _repository().save_new_run(record)
	if save_error != "":
		return _rejected(seed, save_error)

	var result := {"ok": true, "error": "", "seed": seed, "dungeon": generated["dungeon"]}
	_request_cache[request_id] = {
		"payload": payload.duplicate(true),
		"result": result.duplicate(true),
	}
	current_run = record
	last_run = record
	run_started.emit(seed, generated["dungeon"].duplicate(true))
	return result.duplicate(true)


## Starts a fresh run with the previous run's seed and configuration.
## Does not restore health, inventory, enemies or combat progress.
func replay_last_run() -> Dictionary:
	if last_run.is_empty():
		return {"ok": false, "error": "No previous run to replay", "seed": 0, "dungeon": {}}
	return start_new_run(_next_replay_request_id(), last_run["seed"], last_run["config"])


func end_run(won: bool, reason: String) -> void:
	if current_run.is_empty():
		return
	current_run["status"] = "completed"
	current_run["won"] = won
	current_run["reason"] = reason
	_repository().update(current_run)
	current_run = {}
	run_ended.emit(won, reason)


func _with_defaults(config: Dictionary) -> Dictionary:
	var run_config := config.duplicate(true)
	if not run_config.has("max_attempts"):
		run_config["max_attempts"] = DungeonGenerator.DEFAULT_MAX_ATTEMPTS
	return run_config


## Returns {"dungeon": Dictionary, "error": String}; error is empty on success.
func _generate_valid_dungeon(seed: int, run_config: Dictionary) -> Dictionary:
	var dungeon := DungeonGenerator.generate_dungeon(seed, run_config)
	if not dungeon["ok"]:
		return {"dungeon": {}, "error": "Generation failed: %s" % dungeon["error_message"]}
	var check := DungeonGenerator.validate_dungeon(dungeon, run_config)
	if not check["valid"]:
		return {"dungeon": {}, "error": "Generated dungeon is invalid: %s" % ", ".join(check["errors"])}
	return {"dungeon": dungeon, "error": ""}


func _new_record(seed: int, run_config: Dictionary, now: int) -> Dictionary:
	return {
		"run_id": _next_run_id(now, seed),
		"seed": seed,
		"config": run_config,
		"generation_version": GENERATION_VERSION,
		"created_at": now,
		"expires_at": now + RECORD_RETENTION_DAYS * SECONDS_PER_DAY,
		"status": "in_progress",
		"won": false,
		"reason": "",
	}


func _next_run_id(now: int, seed: int) -> String:
	var candidate := ""
	while true:
		_run_id_sequence += 1
		candidate = "%d_%d_%d" % [now, seed, _run_id_sequence]
		if not FileAccess.file_exists(records_dir.path_join(candidate + ".json")):
			return candidate
	return candidate


func _next_replay_request_id() -> String:
	var candidate := ""
	while true:
		_replay_request_sequence += 1
		candidate = "__replay__%d" % _replay_request_sequence
		if not _request_cache.has(candidate):
			return candidate
	return candidate


func _repository() -> RunRecordRepository:
	return RunRecordRepository.new(records_dir)


func _rejected(seed: int, error: String) -> Dictionary:
	return {"ok": false, "error": error, "seed": seed, "dungeon": {}}
