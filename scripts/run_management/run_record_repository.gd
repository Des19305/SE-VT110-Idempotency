extends RefCounted
## Stores run records as JSON files and removes records past their expires_at.
## Knows nothing about seeds, configs or run rules beyond the record fields it
## reads (run_id, created_at, expires_at).

const LAST_RUN_FILE := "last_run.json"

var records_dir: String


func _init(dir: String) -> void:
	records_dir = dir


## Prunes expired records, then writes the new record and last_run.json.
## Returns an empty string on success, otherwise an error message.
func save_new_run(record: Dictionary) -> String:
	var err := DirAccess.make_dir_recursive_absolute(records_dir)
	if err != OK:
		return "Cannot save run record: %s" % error_string(err)
	prune_expired(record["created_at"])
	var write_error := _write(record["run_id"] + ".json", record)
	if write_error != "":
		return write_error
	return _write(LAST_RUN_FILE, record)


## Overwrites an existing run record. Best-effort: a failed write is ignored.
func update(record: Dictionary) -> void:
	_write(record["run_id"] + ".json", record)


func prune_expired(now: int) -> void:
	var dir := DirAccess.open(records_dir)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not file_name.ends_with(".json") or file_name == LAST_RUN_FILE:
			continue
		var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(records_dir.path_join(file_name)))
		if old is Dictionary and int(old.get("expires_at", 0)) <= now:
			dir.remove(file_name)


func _write(file_name: String, record: Dictionary) -> String:
	var file := FileAccess.open(records_dir.path_join(file_name), FileAccess.WRITE)
	if file == null:
		return "Cannot save run record: %s" % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(record, "\t"))
	file.close()
	return ""
