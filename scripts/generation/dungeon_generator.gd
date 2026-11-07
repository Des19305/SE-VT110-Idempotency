extends RefCounted
## Seeded BSP dungeon generator.
##
## Produces pure data (no scenes or nodes) so the layout can be validated and
## tested headlessly. Public API follows docs/architecture.md §7.2.

const WALL := 0
const FLOOR := 1
const DEFAULT_MAX_ATTEMPTS := 10
## Bump when a change can alter the layout produced for an existing seed + config.
const GENERATOR_VERSION := 1
## Retry k (0-based) seeds its RNG with seed + k * ATTEMPT_SEED_STRIDE, so every
## attempt is reproducible from the run seed alone.
const ATTEMPT_SEED_STRIDE := 1_000_003

## Stable error codes (architecture.md §7.2); details go in error_message.
const ERR_INVALID_CONFIG := "INVALID_CONFIG"
const ERR_GENERATION_FAILED := "GENERATION_FAILED"
const ERR_INVALID_DUNGEON := "INVALID_DUNGEON"

const CONFIG_KEYS := ["width", "height", "min_rooms", "max_rooms", "min_room_size", "max_room_size"]
const RESULT_KEYS := ["width", "height", "tiles", "rooms", "start_cell", "boss_cell"]


## Generates a dungeon for [param dungeon_seed] and [param config].
## On failure returns [code]ok = false[/code], a stable [code]error[/code] code
## and a human-readable [code]error_message[/code]; the layout fields are empty.
static func generate_dungeon(dungeon_seed: int, config: Dictionary) -> Dictionary:
	var config_error := check_config(config)
	if config_error != "":
		return _failure(dungeon_seed, config, ERR_INVALID_CONFIG, config_error)

	var max_attempts: int = config.get("max_attempts", DEFAULT_MAX_ATTEMPTS)
	var attempt_errors: Array[String] = []
	for attempt in max_attempts:
		var rng := RandomNumberGenerator.new()
		rng.seed = dungeon_seed + attempt * ATTEMPT_SEED_STRIDE
		var dungeon := _generate_once(rng, dungeon_seed, config)
		if not dungeon["ok"]:
			attempt_errors.append("attempt %d: %s" % [attempt, dungeon["error_message"]])
			continue
		var check := validate_dungeon(dungeon, config)
		if check["valid"]:
			dungeon["attempts"] = attempt + 1
			return dungeon
		attempt_errors.append("attempt %d: %s" % [attempt, "; ".join(check["errors"])])
	return _failure(dungeon_seed, config, ERR_GENERATION_FAILED,
		"No valid dungeon after %d attempts (%s)" % [max_attempts, " | ".join(attempt_errors)])


## Returns an empty string when [param config] satisfies the agreed contract,
## otherwise the first problem found. Never raises on malformed input.
static func check_config(config: Dictionary) -> String:
	for key in CONFIG_KEYS:
		if not config.has(key):
			return "missing config key: %s" % key
		if typeof(config[key]) != TYPE_INT:
			return "config key %s must be an integer" % key
		if config[key] <= 0:
			return "config key %s must be positive" % key
	if config["min_rooms"] > config["max_rooms"]:
		return "min_rooms must not exceed max_rooms"
	if config["min_room_size"] > config["max_room_size"]:
		return "min_room_size must not exceed max_room_size"
	if config["max_room_size"] > mini(config["width"], config["height"]):
		return "max_room_size must not exceed the map dimensions"
	if config.has("max_attempts") and (typeof(config["max_attempts"]) != TYPE_INT or config["max_attempts"] <= 0):
		return "max_attempts must be a positive integer"
	return ""


## Checks the dungeon against the validity rules of architecture.md §5.3.
## Room count and room size limits are only checked when [param config] is given.
## Malformed input produces errors instead of runtime failures.
static func validate_dungeon(dungeon: Dictionary, config: Dictionary = {}) -> Dictionary:
	var errors: Array[String] = []
	for key in RESULT_KEYS:
		if not dungeon.has(key):
			errors.append("missing key: %s" % key)
	if not errors.is_empty():
		return {"valid": false, "errors": errors}
	if not config.is_empty():
		var config_error := check_config(config)
		if config_error != "":
			return {"valid": false, "errors": ["invalid config: %s" % config_error]}

	if typeof(dungeon["width"]) != TYPE_INT or typeof(dungeon["height"]) != TYPE_INT \
			or dungeon["width"] <= 0 or dungeon["height"] <= 0:
		return {"valid": false, "errors": ["width and height must be positive integers"]}
	var width: int = dungeon["width"]
	var height: int = dungeon["height"]
	if not config.is_empty() and (width != config["width"] or height != config["height"]):
		errors.append("grid size %dx%d does not match config %dx%d" % [width, height, config["width"], config["height"]])

	errors.append_array(_check_tiles(dungeon["tiles"], width, height))
	if not errors.is_empty():
		return {"valid": false, "errors": errors}
	var tiles: Array = dungeon["tiles"]

	errors.append_array(_check_rooms(dungeon["rooms"], tiles, config))

	# Reachability needs usable start/boss cells; room errors do not block it.
	var cell_errors: Array[String] = []
	for cell_name in ["start_cell", "boss_cell"]:
		var cell: Variant = dungeon[cell_name]
		if typeof(cell) != TYPE_VECTOR2I:
			cell_errors.append("%s must be a Vector2i" % cell_name)
		elif not Rect2i(0, 0, width, height).has_point(cell):
			cell_errors.append("%s %s is out of bounds" % [cell_name, cell])
		elif tiles[cell.y][cell.x] != FLOOR:
			cell_errors.append("%s %s is not walkable" % [cell_name, cell])
	if not cell_errors.is_empty():
		errors.append_array(cell_errors)
		return {"valid": false, "errors": errors}

	var start: Vector2i = dungeon["start_cell"]
	var boss: Vector2i = dungeon["boss_cell"]
	if start == boss:
		errors.append("start_cell and boss_cell are the same cell")
	else:
		var reached := _flood_fill(tiles, start)
		if not reached.has(boss):
			errors.append("boss_cell is not reachable from start_cell")
		var walkable := 0
		for row in tiles:
			walkable += row.count(FLOOR)
		if reached.size() != walkable:
			errors.append("%d walkable tiles are disconnected from start_cell" % (walkable - reached.size()))

	return {"valid": errors.is_empty(), "errors": errors}


## Grid must have [param height] rows of [param width] integer tiles, each 0 or 1.
static func _check_tiles(tiles: Variant, width: int, height: int) -> Array[String]:
	if not (tiles is Array):
		return ["tiles must be an Array"]
	if tiles.size() != height:
		return ["grid has %d rows, expected %d" % [tiles.size(), height]]
	for y in height:
		var row: Variant = tiles[y]
		if not (row is Array) or row.size() != width:
			return ["row %d must be an Array of %d tiles" % [y, width]]
		for x in width:
			if typeof(row[x]) != TYPE_INT or (row[x] != WALL and row[x] != FLOOR):
				return ["tile (%d, %d) must be 0 or 1, got %s" % [x, y, row[x]]]
	return []


## Rooms must be well-formed, in bounds, walkable, non-overlapping and, when a
## config is given, within the configured count and size limits.
static func _check_rooms(rooms: Variant, tiles: Array, config: Dictionary) -> Array[String]:
	if not (rooms is Array):
		return ["rooms must be an Array"]
	var errors: Array[String] = []
	if not config.is_empty() and (rooms.size() < config["min_rooms"] or rooms.size() > config["max_rooms"]):
		errors.append("room count %d is outside %d-%d" % [rooms.size(), config["min_rooms"], config["max_rooms"]])
	var bounds := Rect2i(0, 0, tiles[0].size(), tiles.size())
	var rects: Array[Rect2i] = []
	for i in rooms.size():
		var room: Variant = rooms[i]
		if not (room is Dictionary) or typeof(room.get("position")) != TYPE_VECTOR2I \
				or typeof(room.get("size")) != TYPE_VECTOR2I:
			errors.append("room %d must have Vector2i position and size" % i)
			continue
		var rect := Rect2i(room["position"], room["size"])
		if rect.size.x <= 0 or rect.size.y <= 0:
			errors.append("room %d has a non-positive size" % i)
			continue
		if not config.is_empty() and (mini(rect.size.x, rect.size.y) < config["min_room_size"]
				or maxi(rect.size.x, rect.size.y) > config["max_room_size"]):
			errors.append("room %d size %s is outside %d-%d" % [i, rect.size, config["min_room_size"], config["max_room_size"]])
		if not bounds.encloses(rect):
			errors.append("room %d is out of bounds" % i)
			continue
		if not _is_all_floor(tiles, rect):
			errors.append("room %d contains wall tiles" % i)
		for j in rects.size():
			if rects[j].intersects(rect):
				errors.append("room %d overlaps another room" % i)
				break
		rects.append(rect)
	return errors


static func _is_all_floor(tiles: Array, rect: Rect2i) -> bool:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if tiles[y][x] != FLOOR:
				return false
	return true


static func _failure(dungeon_seed: int, config: Dictionary, code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"error": code,
		"error_message": message,
		"seed": dungeon_seed,
		"width": config.get("width", 0) if typeof(config.get("width")) == TYPE_INT else 0,
		"height": config.get("height", 0) if typeof(config.get("height")) == TYPE_INT else 0,
		"tiles": [],
		"rooms": [],
		"start_cell": Vector2i.ZERO,
		"boss_cell": Vector2i.ZERO,
		"generator_version": GENERATOR_VERSION,
	}


static func _generate_once(rng: RandomNumberGenerator, dungeon_seed: int, config: Dictionary) -> Dictionary:
	var width: int = config["width"]
	var height: int = config["height"]
	var min_rooms: int = config["min_rooms"]
	var max_rooms: int = config["max_rooms"]
	var min_size: int = config["min_room_size"]
	var max_size: int = config["max_room_size"]

	var tiles := []
	for y in height:
		var row := []
		row.resize(width)
		row.fill(WALL)
		tiles.append(row)

	# Leave a one-tile wall border; every leaf can hold a max-size room plus walls.
	var leaves: Array[Rect2i] = []
	_split(Rect2i(1, 1, width - 2, height - 2), max_size + 2, rng, leaves)

	var rooms := []
	for leaf in leaves:
		if rooms.size() >= max_rooms:
			break
		# Only an unsplit, undersized map produces such a leaf; skipping it draws
		# no random numbers, so layouts of workable configs are unchanged.
		if leaf.size.x - 2 < min_size or leaf.size.y - 2 < min_size:
			continue
		var size := Vector2i(
			rng.randi_range(min_size, mini(max_size, leaf.size.x - 2)),
			rng.randi_range(min_size, mini(max_size, leaf.size.y - 2)))
		var position := Vector2i(
			rng.randi_range(leaf.position.x + 1, leaf.end.x - 1 - size.x),
			rng.randi_range(leaf.position.y + 1, leaf.end.y - 1 - size.y))
		rooms.append({"position": position, "size": size})
		_carve_rect(tiles, position, size)

	if rooms.size() < min_rooms:
		return {"ok": false, "error_message": "only %d rooms fit, need at least %d" % [rooms.size(), min_rooms]}

	# BSP leaf order keeps consecutive rooms spatially close, so a chain of
	# L-shaped corridors connects every room.
	for i in range(1, rooms.size()):
		_carve_corridor(tiles, _center(rooms[i - 1]), _center(rooms[i]), rng.randi() % 2 == 0)

	var start_cell := _center(rooms[0])
	var boss_cell := start_cell
	var best_distance := -1
	for room in rooms:
		var center := _center(room)
		var distance := absi(center.x - start_cell.x) + absi(center.y - start_cell.y)
		if distance > best_distance:
			best_distance = distance
			boss_cell = center

	return {
		"ok": true,
		"error": "",
		"seed": dungeon_seed,
		"width": width,
		"height": height,
		"tiles": tiles,
		"rooms": rooms,
		"start_cell": start_cell,
		"boss_cell": boss_cell,
		"generator_version": GENERATOR_VERSION,
	}


static func _split(rect: Rect2i, min_leaf: int, rng: RandomNumberGenerator, leaves: Array[Rect2i]) -> void:
	var can_split_x := rect.size.x >= min_leaf * 2
	var can_split_y := rect.size.y >= min_leaf * 2
	if not can_split_x and not can_split_y:
		leaves.append(rect)
		return
	var split_x := can_split_x
	if can_split_x and can_split_y:
		split_x = rng.randf() < 0.5
	if split_x:
		var cut := rng.randi_range(min_leaf, rect.size.x - min_leaf)
		_split(Rect2i(rect.position, Vector2i(cut, rect.size.y)), min_leaf, rng, leaves)
		_split(Rect2i(rect.position + Vector2i(cut, 0), Vector2i(rect.size.x - cut, rect.size.y)), min_leaf, rng, leaves)
	else:
		var cut := rng.randi_range(min_leaf, rect.size.y - min_leaf)
		_split(Rect2i(rect.position, Vector2i(rect.size.x, cut)), min_leaf, rng, leaves)
		_split(Rect2i(rect.position + Vector2i(0, cut), Vector2i(rect.size.x, rect.size.y - cut)), min_leaf, rng, leaves)


static func _carve_rect(tiles: Array, position: Vector2i, size: Vector2i) -> void:
	for y in range(position.y, position.y + size.y):
		for x in range(position.x, position.x + size.x):
			tiles[y][x] = FLOOR


static func _carve_corridor(tiles: Array, from: Vector2i, to: Vector2i, horizontal_first: bool) -> void:
	var corner := Vector2i(to.x, from.y) if horizontal_first else Vector2i(from.x, to.y)
	_carve_line(tiles, from, corner)
	_carve_line(tiles, corner, to)


static func _carve_line(tiles: Array, from: Vector2i, to: Vector2i) -> void:
	for y in range(mini(from.y, to.y), maxi(from.y, to.y) + 1):
		for x in range(mini(from.x, to.x), maxi(from.x, to.x) + 1):
			tiles[y][x] = FLOOR


static func _center(room: Dictionary) -> Vector2i:
	return room["position"] + room["size"] / 2


static func _flood_fill(tiles: Array, start: Vector2i) -> Dictionary:
	var reached := {start: true}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size():
		var cell := queue[head]
		head += 1
		for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = cell + step
			if next.y < 0 or next.y >= tiles.size() or next.x < 0 or next.x >= tiles[next.y].size():
				continue
			if tiles[next.y][next.x] == FLOOR and not reached.has(next):
				reached[next] = true
				queue.append(next)
	return reached
