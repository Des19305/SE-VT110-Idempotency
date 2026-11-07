extends RefCounted
## Stores run records as JSON files and removes records past their expires_at.
## Knows nothing about seeds, configs or run rules beyond the record fields it
## reads (run_id, created_at, expires_at).

const LAST_RUN_FILE := "last_run.json"

var records_dir: String


func _init(dir: String) -> void:
	records_dir = dir


## Writes the new record and last_run.json, then prunes expired records.
## Returns an empty string on success, otherwise an error message.
func save_new_run(record: Dictionary) -> String:
	var err := DirAccess.make_dir_recursive_absolute(records_dir)
	if err != OK:
		return "Cannot save run record: %s" % error_string(err)
	var record_file: String = record["run_id"] + ".json"
	var write_error := _write(record_file, record)
	if write_error != "":
		var dir := DirAccess.open(records_dir)
		if dir != null:
			dir.remove(record_file)
		return write_error
	write_error = _write(LAST_RUN_FILE, record)
	if write_error != "":
		# A failed last-run pointer must not leave behind a record for a start
		# that RunManager reports as unsuccessful.
		var dir := DirAccess.open(records_dir)
		if dir != null:
			dir.remove(record_file)
		return write_error
	prune_expired(record["created_at"])
	return ""


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
	var path := records_dir.path_join(file_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot save run record: %s" % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(record, "\t"))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return "Cannot save run record: %s" % error_string(write_error)
	return ""
