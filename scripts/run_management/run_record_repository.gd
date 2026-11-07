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
		return _append_cleanup_errors(write_error, _remove_file(record_file))

	var temp_pointer_file := LAST_RUN_FILE + ".tmp"
	write_error = _write(temp_pointer_file, record)
	if write_error != "":
		var cleanup_error := _remove_file(temp_pointer_file)
		cleanup_error = _append_cleanup_errors(cleanup_error, _remove_file(record_file))
		return _append_cleanup_errors(write_error, cleanup_error)

	var pointer_path := records_dir.path_join(LAST_RUN_FILE)
	var temp_pointer_path := records_dir.path_join(temp_pointer_file)
	var pointer_error := _commit_pointer(temp_pointer_path, pointer_path)
	if pointer_error != "":
		var cleanup_error := _remove_file(temp_pointer_file)
		cleanup_error = _append_cleanup_errors(cleanup_error, _remove_file(record_file))
		return _append_cleanup_errors(pointer_error, cleanup_error)

	prune_expired(record["created_at"])
	return ""


## Replaces the last-run pointer only after the staged file has been verified.
## The old pointer remains in a backup until the new pointer is confirmed.
func _commit_pointer(temp_path: String, pointer_path: String) -> String:
	if not FileAccess.file_exists(temp_path):
		return "Cannot replace last-run pointer: staged file is missing"
	var staged_contents := FileAccess.get_file_as_string(temp_path)
	if staged_contents.is_empty():
		return "Cannot replace last-run pointer: staged file is empty"

	var had_previous_pointer := FileAccess.file_exists(pointer_path)
	var backup_path := ""
	if had_previous_pointer:
		backup_path = _next_backup_path(pointer_path)
		var backup_error := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(pointer_path),
			ProjectSettings.globalize_path(backup_path)
		)
		if backup_error != OK:
			return "Cannot back up previous last-run pointer: %s" % error_string(backup_error)

	var replace_error := _replace_pointer_file(temp_path, pointer_path)
	if replace_error != "":
		if had_previous_pointer:
			var restore_error := _restore_pointer_backup(backup_path, pointer_path)
			if restore_error != "":
				return "%s; previous pointer remains in backup '%s' because restore failed: %s" % [replace_error, backup_path, restore_error]
		return replace_error

	if not FileAccess.file_exists(pointer_path) or FileAccess.get_file_as_string(pointer_path) != staged_contents:
		var verify_error := "Cannot confirm the new last-run pointer after replacement"
		if had_previous_pointer:
			var restore_error := _restore_pointer_backup(backup_path, pointer_path)
			if restore_error != "":
				return "%s; previous pointer remains in backup '%s' because restore failed: %s" % [verify_error, backup_path, restore_error]
		else:
			var cleanup_pointer_error := _remove_absolute_file(pointer_path)
			if cleanup_pointer_error != "":
				return "%s; invalid pointer cleanup failed: %s" % [verify_error, cleanup_pointer_error]
		return verify_error

	if had_previous_pointer:
		var backup_cleanup_error := _remove_absolute_file(backup_path)
		if backup_cleanup_error != "":
			push_warning("New last-run pointer is valid, but backup cleanup failed for '%s': %s" % [backup_path, backup_cleanup_error])
	return ""


## This narrow operation is overridable so tests can inject a promotion failure
## while exercising the real backup restoration path around it.
func _replace_pointer_file(temp_path: String, pointer_path: String) -> String:
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temp_path),
		ProjectSettings.globalize_path(pointer_path)
	)
	if err != OK:
		return "Cannot promote staged last-run pointer: %s" % error_string(err)
	return ""


func _restore_pointer_backup(backup_path: String, pointer_path: String) -> String:
	if FileAccess.file_exists(pointer_path):
		var remove_error := _remove_absolute_file(pointer_path)
		if remove_error != "":
			return "Cannot remove failed replacement before restoring backup: %s" % remove_error
	var restore_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(backup_path),
		ProjectSettings.globalize_path(pointer_path)
	)
	if restore_error != OK:
		return error_string(restore_error)
	if not FileAccess.file_exists(pointer_path):
		return "Restore reported success but the previous pointer is missing"
	return ""


func _next_backup_path(pointer_path: String) -> String:
	var suffix := 0
	var candidate := pointer_path + ".bak"
	while FileAccess.file_exists(candidate) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate)):
		suffix += 1
		candidate = pointer_path + ".bak.%d" % suffix
	return candidate


func _remove_file(file_name: String) -> String:
	var dir := DirAccess.open(records_dir)
	if dir == null:
		return "Cannot open run-record directory for cleanup"
	if not dir.file_exists(file_name):
		return ""
	var err := dir.remove(file_name)
	if err != OK:
		return "Cannot remove '%s': %s" % [file_name, error_string(err)]
	return ""


func _remove_absolute_file(path: String) -> String:
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		return error_string(err)
	return ""


func _append_cleanup_errors(primary: String, cleanup: String) -> String:
	if cleanup == "":
		return primary
	return "%s; cleanup also failed: %s" % [primary, cleanup]


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
