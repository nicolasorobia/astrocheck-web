class_name ExpeditionLog
extends RefCounted
## Every completed expedition, saved to user://expeditions.json so it survives
## restarts (debug runs from the editor and exported builds alike).
## On Windows that file is in %APPDATA%\Godot\app_userdata\BioBeacon\ (or the
## exported game's own user data folder on each tester's PC).

const PATH := "user://expeditions.json"


## All logged expeditions, oldest first. Each is a Dictionary:
## number, date, days, rescues, heat_rescues, samples, rover_samples, player_samples,
## steps, game_seconds, play_seconds, dose_msv, playtest
static func load_all() -> Array:
	if not FileAccess.file_exists(PATH):
		return []
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return []
	var data: Variant = JSON.parse_string(f.get_as_text())
	return data if data is Array else []


## Adds a finished expedition and returns its number (1, 2, 3...).
static func record(entry: Dictionary) -> int:
	var all := load_all()
	entry["number"] = all.size() + 1
	var d := Time.get_datetime_dict_from_system()
	entry["date"] = "%04d-%02d-%02d" % [d.year, d.month, d.day]
	all.append(entry)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(all, "  "))
	return int(entry["number"])
