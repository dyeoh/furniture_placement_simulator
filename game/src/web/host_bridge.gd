class_name HostBridge
extends RefCounted

## The seam between the simulator and the page it is embedded in.
##
## On the web the simulator runs inside an <iframe> on the store's page. Data
## crosses that boundary with window.postMessage in both directions, always as
## a JSON *string* -- a structured-clone object would arrive as an opaque
## JavaScriptObject that GDScript cannot walk, and a string round-trips through
## JSON.parse_string with no surprises.
##
## Inbound (host -> sim):  {type:"catalog", finishes:{}, items:[...]}
##                         {type:"layout", ...Layout.capture() shape...}
##                         {type:"clear"}
## Outbound (sim -> host): {type:"ready"}
##                         {type:"layout", ...}          on every change
##                         {type:"add_to_cart", items:[{variant_id, quantity}]}
##
## Off the web every method is a no-op, so the scene never has to ask.

signal catalog_received(data: Dictionary)
signal layout_received(data: Dictionary)
signal clear_requested
signal model_received(bytes: PackedByteArray, filename: String)

var _on_message: JavaScriptObject
var _on_file: JavaScriptObject
var _allowed_origin := ""


static func is_web() -> bool:
	return OS.has_feature("web")


## A query-string value from the page URL (`?host=…&quality=low`); empty
## off the web or when absent.
static func query_param(name: String) -> String:
	if not is_web():
		return ""
	var search := str(JavaScriptBridge.eval("location.search", true))
	for part in search.trim_prefix("?").split("&"):
		if part.begins_with(name + "="):
			return part.substr(name.length() + 1).uri_decode()
	return ""


## [param ready_extra] rides along in the "ready" message, e.g. the quality
## tier chosen, so the page (or a smoke test) can see what it got.
func setup(ready_extra: Dictionary = {}) -> void:
	if not is_web():
		return
	# ?host=https://store.example pins the accepted message origin. Without it
	# any parent is accepted, which is fine for a local preview and not for a
	# storefront -- the Liquid section always passes it.
	_allowed_origin = query_param("host")
	_on_message = JavaScriptBridge.create_callback(_message)
	var window := JavaScriptBridge.get_interface("window")
	window.addEventListener("message", _on_message)
	# File picker. Defined once as a global so the callback can be handed to it
	# as a plain function; base64 is used for the bytes because a string is the
	# one payload type guaranteed to cross the bridge intact.
	JavaScriptBridge.eval("""
		window.__fpsPickFile = function (cb) {
			var i = document.createElement('input');
			i.type = 'file'; i.accept = '.glb,.gltf,model/gltf-binary';
			i.style.display = 'none';
			i.onchange = function () {
				var f = i.files && i.files[0];
				if (!f) { return; }
				var r = new FileReader();
				r.onload = function () { cb(f.name, String(r.result).split(',')[1] || ''); };
				r.readAsDataURL(f);
				document.body.removeChild(i);
			};
			document.body.appendChild(i);
			i.click();
		};
	""", true)
	_on_file = JavaScriptBridge.create_callback(_file_picked)
	var ready := {"type": "ready"}
	ready.merge(ready_extra)
	post(ready)


func post(msg: Dictionary) -> void:
	if not is_web():
		return
	var window := JavaScriptBridge.get_interface("window")
	var parent = window.parent
	if parent == null:
		return
	# "*" because the Pages build does not know which storefront embeds it; the
	# receiving side checks event.origin against the iframe's own URL.
	parent.postMessage(JSON.stringify(msg), "*")


func pick_file() -> void:
	if not is_web():
		return
	var window := JavaScriptBridge.get_interface("window")
	window.__fpsPickFile(_on_file)


func _message(args: Array) -> void:
	if args.is_empty():
		return
	var ev = args[0]
	if _allowed_origin != "" and str(ev.origin) != _allowed_origin:
		return
	var raw = ev.data
	if not (raw is String):
		return
	var data = JSON.parse_string(raw)
	if not (data is Dictionary):
		return
	match str(data.get("type", "")):
		"catalog":
			catalog_received.emit(data)
		"layout":
			layout_received.emit(data)
		"clear":
			clear_requested.emit()


func _file_picked(args: Array) -> void:
	if args.size() < 2:
		return
	var name := str(args[0])
	var bytes := Marshalls.base64_to_raw(str(args[1]))
	if bytes.is_empty():
		push_warning("HostBridge: empty upload '%s'" % name)
		return
	model_received.emit(bytes, name)
