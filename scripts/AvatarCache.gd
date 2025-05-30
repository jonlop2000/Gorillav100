extends Node

signal avatar_ready(player_id)

var _cache = {}  # player_id → Texture

func has(player_id: String) -> bool:
	return _cache.has(player_id)

func get(player_id: String) -> Texture:
	return _cache.get(player_id, null)

func fetch(player_id: String, url: String) -> void:
	if has(player_id):
		emit_signal("avatar_ready", player_id)
		return

	var http = HTTPRequest.new()
	add_child(http)
	http.connect("request_completed", self, "_on_request", [player_id, http])
	http.request(url)

func _on_request(result, code, headers, body, player_id, http: HTTPRequest) -> void:
	http.queue_free()
	if result != OK or code != 200:
		push_warning("Avatar download failed for %s" % player_id)
		return

	var img = Image.new()
	var ok = img.load_png_from_buffer(body)
	if ok != OK:
		ok = img.load_jpg_from_buffer(body)
	if ok != OK:
		push_warning("Unrecognized avatar data for %s" % player_id)
		return

	img.resize(40, 40, Image.INTERPOLATE_LANCZOS)
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	_cache[player_id] = tex
	emit_signal("avatar_ready", player_id)
