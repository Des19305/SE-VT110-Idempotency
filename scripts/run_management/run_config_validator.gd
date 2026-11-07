extends RefCounted
## Validates the seed and generation config of a run before any generation or
## storage happens. Pure functions: no state, no I/O.

const REQUIRED_KEYS := ["width", "height", "min_rooms", "max_rooms", "min_room_size", "max_room_size"]
const MIN_DUNGEON_SIZE := 20
const MAX_DUNGEON_SIZE := 200
const MIN_ROOMS := 2
const MIN_ROOM_SIZE := 3


## Returns an empty string when the input is valid, otherwise the first error.
static func validate(seed: int, config: Dictionary) -> String:
	if seed < 0:
		return "Seed must be non-negative"
	for key in REQUIRED_KEYS:
		if not config.has(key):
			return "Missing config key: %s" % key
		if typeof(config[key]) != TYPE_INT:
			return "Config key %s must be an integer" % key
	if not _in_range(config["width"]) or not _in_range(config["height"]):
		return "Dungeon size must be between %d and %d tiles" % [MIN_DUNGEON_SIZE, MAX_DUNGEON_SIZE]
	if config["min_rooms"] < MIN_ROOMS or config["min_rooms"] > config["max_rooms"]:
		return "Room count range is invalid"
	if config["min_room_size"] < MIN_ROOM_SIZE or config["min_room_size"] > config["max_room_size"]:
		return "Room size range is invalid"
	if config["max_room_size"] * 2 > mini(config["width"], config["height"]):
		return "Rooms do not fit in the dungeon"
	return ""


static func _in_range(size: int) -> bool:
	return size >= MIN_DUNGEON_SIZE and size <= MAX_DUNGEON_SIZE
