extends AudioStreamPlayer
## Seamlessly looping background sound (the hiss of isolation in the suit).
## Keeps playing while the game is paused (rest screen, pop-ups).
## Also used for the main menu music. Plays on the "Music" bus (Settings > Music volume).

@export var loop_bus: StringName = &"Music"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	bus = loop_bus
	var wav := stream as AudioStreamWAV
	if wav:
		# Loop inside the sample itself: no gap or click at the seam.
		wav = wav.duplicate() as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * wav.mix_rate)
		stream = wav
	else:
		finished.connect(play)
	play()
