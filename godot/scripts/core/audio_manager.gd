extends Node

var music_player: AudioStreamPlayer
var sfx_players: Array[AudioStreamPlayer] = []
const MAX_SFX_PLAYERS := 10
var _current_sfx_player := 0

var _sfx_cache: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_buses()
	_setup_players()
	_init_procedural_sounds()
	_connect_to_gamestore()


func _setup_buses() -> void:
	if AudioServer.get_bus_index("SFX") == -1:
		var sfx_idx := AudioServer.get_bus_count()
		AudioServer.add_bus(sfx_idx)
		AudioServer.set_bus_name(sfx_idx, "SFX")
		AudioServer.set_bus_send(sfx_idx, "Master")

	if AudioServer.get_bus_index("Music") == -1:
		var mus_idx := AudioServer.get_bus_count()
		AudioServer.add_bus(mus_idx)
		AudioServer.set_bus_name(mus_idx, "Music")
		AudioServer.set_bus_send(mus_idx, "Master")


func _setup_players() -> void:
	for i in range(MAX_SFX_PLAYERS):
		var p := AudioStreamPlayer.new()
		p.name = "SFXPlayer_%d" % i
		p.bus = "SFX"
		add_child(p)
		sfx_players.append(p)

	music_player = AudioStreamPlayer.new()
	music_player.name = "MusicPlayer"
	music_player.bus = "Music"
	add_child(music_player)


func _init_procedural_sounds() -> void:
	_sfx_cache["click"] = _generate_tone(520.0, 0.04, 0.7, 1)
	_sfx_cache["select"] = _generate_tone(659.0, 0.05, 0.8, 1)
	_sfx_cache["build"] = _generate_tone(220.0, 0.12, 0.9, 2)
	_sfx_cache["cash"] = _generate_arp([880.0, 1174.0, 1760.0], 0.06, 0.8)
	_sfx_cache["error"] = _generate_tone(160.0, 0.22, 0.9, 3)
	_sfx_cache["upgrade"] = _generate_arp([523.0, 659.0, 784.0, 1046.0], 0.05, 0.8)


func _generate_tone(freq: float, duration: float, volume: float = 1.0, shape: int = 1) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	var sample_rate := 22050
	stream.mix_rate = sample_rate

	var length := int(sample_rate * duration)
	var data := PackedByteArray()
	data.resize(length)

	for i in range(length):
		var t := float(i) / float(sample_rate)
		var env := 1.0 - (float(i) / float(length))
		var wave := 0.0

		match shape:
			1: # sine
				wave = sin(t * freq * TAU)
			2: # triangle
				var phase := fmod(t * freq, 1.0)
				wave = 4.0 * absf(phase - 0.5) - 1.0
			3: # saw
				var phase := fmod(t * freq, 1.0)
				wave = 2.0 * phase - 1.0

		var sample_val := int((wave * env * volume + 1.0) * 127.5)
		data[i] = clampi(sample_val, 0, 255)

	stream.data = data
	return stream


func _generate_arp(frequencies: Array[float], note_duration: float, volume: float = 1.0) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_8_BITS
	var sample_rate := 22050
	stream.mix_rate = sample_rate

	var total_duration := note_duration * frequencies.size()
	var total_length := int(sample_rate * total_duration)
	var note_samples := int(sample_rate * note_duration)
	var data := PackedByteArray()
	data.resize(total_length)

	for i in range(total_length):
		var note_idx := clampi(int(i / note_samples), 0, frequencies.size() - 1)
		var freq: float = frequencies[note_idx]
		var sample_in_note := i % note_samples
		var t := float(sample_in_note) / float(sample_rate)
		var env := 1.0 - (float(sample_in_note) / float(note_samples))

		var wave := sin(t * freq * TAU)
		var sample_val := int((wave * env * volume + 1.0) * 127.5)
		data[i] = clampi(sample_val, 0, 255)

	stream.data = data
	return stream


func play_sfx(sound_name: String) -> void:
	if not _sfx_cache.has(sound_name):
		return
	if sfx_players.is_empty():
		return
	var player := sfx_players[_current_sfx_player]
	player.stream = _sfx_cache[sound_name]
	player.play()
	_current_sfx_player = (_current_sfx_player + 1) % sfx_players.size()


func _connect_to_gamestore() -> void:
	var store := get_node_or_null("/root/GameStore")
	if is_instance_valid(store):
		store.toast_requested.connect(func(msg: String):
			var low := msg.to_lower()
			if low.contains("error") or low.contains("cannot") or low.contains("nie można") or low.contains("not enough") or low.contains("brak"):
				play_sfx("error")
			elif low.contains("purchased") or low.contains("bought") or low.contains("built") or low.contains("kupiono") or low.contains("zbudowano"):
				play_sfx("build")
			elif low.contains("unlocked") or low.contains("odblokowano") or low.contains("upgraded") or low.contains("ulepszono"):
				play_sfx("upgrade")
			else:
				play_sfx("select")
		)
