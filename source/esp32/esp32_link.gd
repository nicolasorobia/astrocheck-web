extends Node
## Live link to the BioBeacon ESP32 sensor kit (autoload "Esp32Link").
##
## The kit's sketch (esp32/cumilative_launch) prints one JSON line 10x a second over
## USB at 115200 baud, e.g.
##   {"t_ms":1234, "hr_bpm":72, "spo2_pct":98, "skin_temp_c":33.4, "accel_g":1.00,
##    "co2_ppm":812, "cabin_temp_c":24.1, "humidity_pct":48, "pressure_hpa":1009.6}
## null = that sensor has no result right now (finger not on it yet, still measuring...).
## The game mirrors that exactly, so the in-game numbers always match the kit's TFT.
##
## While connected, keys 1-5 open a TFT page and the Left / Right arrows go back / next
## (the kit's own Serial Monitor keys can't reach it while the game holds the port).
## Godot can't open a COM port by itself, so while ESP32 SENSOR MODE is on this starts
## a small hidden PowerShell helper (Windows has everything it needs built in). The
## helper finds the board's COM port, reads those lines and forwards them to the game
## over UDP on this PC (127.0.0.1). It exits by itself when the game closes.
##
## Only one program can hold a COM port at a time: close the Arduino IDE's Serial
## Monitor (and don't upload) while the game is connected.
## Windows desktop only (editor play / exported .exe), not the web build.

const UDP_PORT := 47321
const CMD_PORT_OFFSET := 100    ## The helper listens for TFT commands on UDP_PORT + 100.
const STALE_MS := 3000          ## No data for this long = connection lost.
const SKIN_MIN_C := 28.0        ## Below this the MLX90614 is looking at the room, not a person.
## true = the temperature card shows the MLX90614 skin temperature while connected.
## false = the astronaut's temperature stays simulated (CORE TEMP).
const USE_SKIN_TEMP := true

## TFT page keys while connected: 1-5 = page, these two = back / next.
const PAGE_KEYS := {KEY_1: "1", KEY_2: "2", KEY_3: "3", KEY_4: "4", KEY_5: "5",
	KEY_LEFT: "d", KEY_RIGHT: "a"}

## "off", "searching", "busy", "connected", "lost", "unsupported"
var state := "off"
var port_name := ""
var hr_bpm := NAN               ## MAX30102 (finger on it ~1 min for a result)
var spo2_pct := NAN             ## MAX30102
var skin_temp_c := NAN          ## MLX90614 (skin held still ~25 s for a result)
var co2_ppm := NAN              ## SCD41 (new value every 5 s)
var co2_mmhg := NAN             ## co2_ppm as a partial pressure at 760 mmHg
var pressure_hpa := NAN         ## BME280 / BMP280
var accel_g := NAN              ## MPU6050

var last_sent := ""             ## Last command key the helper confirmed it wrote to the kit.
var _udp: PacketPeerUDP
var _pid := -1
var _bound_port := 0
var _last_packet := -100000


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	var want := bool(GameSettings.esp32_mode)
	if want and _udp == null and state != "unsupported":
		_start()
	elif not want and (_udp != null or state != "off"):
		_stop()
	if _udp == null:
		return
	while _udp.get_available_packet_count() > 0:
		_handle(_udp.get_packet().get_string_from_utf8())
	if state == "connected" and Time.get_ticks_msec() - _last_packet > STALE_MS:
		state = "lost"


## True while fresh readings are arriving.
func is_live() -> bool:
	return state == "connected" and Time.get_ticks_msec() - _last_packet <= STALE_MS


## Live AND the skin temperature is part of the link (see USE_SKIN_TEMP).
func skin_live() -> bool:
	return USE_SKIN_TEMP and is_live()


func has_skin_temp() -> bool:
	return skin_live() and not is_nan(skin_temp_c)


## The MLX90614 has a result AND it's warm enough to be skin (not the room).
func skin_detected() -> bool:
	return has_skin_temp() and skin_temp_c >= SKIN_MIN_C


## Sends a one-key command to the kit, exactly like typing it in the Serial Monitor:
## "1"-"5" open a TFT page (1 heart / SpO2, 2 skin temp, 3 motion, 4 pressure, 5 air),
## "a" next page, "d" previous page.
## Works while the game holds the COM port (the helper passes it on).
func send_command(key: String) -> bool:
	if _udp == null or _bound_port == 0 or key.length() != 1:
		return false
	var out := PacketPeerUDP.new()
	out.connect_to_host("127.0.0.1", _bound_port + CMD_PORT_OFFSET)
	var ok := out.put_packet(key.to_ascii_buffer()) == OK
	out.close()
	return ok


func has_co2() -> bool:
	return is_live() and not is_nan(co2_ppm)


func has_hr() -> bool:
	return is_live() and not is_nan(hr_bpm)


func has_spo2() -> bool:
	return is_live() and not is_nan(spo2_pct)


func has_pressure() -> bool:
	return is_live() and not is_nan(pressure_hpa)


# Same 0 normal / 1 caution / 2 alert thresholds as the kit's TFT (demo values).
static func hr_level(bpm: float) -> int:
	if bpm >= 60 and bpm <= 100:
		return 0
	return 1 if (bpm >= 50 and bpm < 60) or (bpm > 100 and bpm <= 120) else 2


static func spo2_level(pct: float) -> int:
	return 0 if pct >= 95 else (1 if pct >= 90 else 2)


static func co2_level(ppm: float) -> int:
	return 0 if ppm < 1000 else (1 if ppm <= 2000 else 2)


static func pressure_level(hpa: float) -> int:
	if hpa >= 980 and hpa <= 1040:
		return 0
	return 1 if (hpa >= 900 and hpa < 980) or (hpa > 1040 and hpa <= 1060) else 2


## Keys 1-5 / Left / Right switch the kit's TFT page while it's connected. Runs before
## the menus so the arrow keys don't also nudge a focused slider.
func _input(event: InputEvent) -> void:
	if not is_live():
		return
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and PAGE_KEYS.has(k.physical_keycode):
		send_command(PAGE_KEYS[k.physical_keycode])
		get_viewport().set_input_as_handled()


## One line for the Settings page.
func status_text() -> String:
	match state:
		"connected":
			return "CONNECTED  ·  %s" % port_name if is_live() else "SIGNAL LOST  ·  %s" % port_name
		"searching", "lost":
			return "SEARCHING FOR DEVICE..."
		"busy":
			return "%s BUSY - CLOSE SERIAL MONITOR" % port_name
		"unsupported":
			return "NEEDS THE WINDOWS VERSION (NOT THE BROWSER)"
	return ""


func status_ok() -> bool:
	return is_live()


# ------------------------------------------------------------------ helper process

func _start() -> void:
	if not OS.has_feature("windows"):
		state = "unsupported"
		return
	_udp = PacketPeerUDP.new()
	_bound_port = 0
	for p in range(UDP_PORT, UDP_PORT + 10):  # skip a port something else already uses
		if _udp.bind(p, "127.0.0.1") == OK:
			_bound_port = p
			break
	if _bound_port == 0:
		_udp = null
		state = "unsupported"
		push_warning("Esp32Link: no free UDP port")
		return
	var path := "user://esp32_bridge.ps1"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Esp32Link: can't write %s" % path)
		return
	f.store_string(BRIDGE_PS1)
	f.close()
	_pid = OS.create_process("powershell.exe", [
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", ProjectSettings.globalize_path(path),
		"-UdpPort", str(_bound_port), "-ParentPid", str(OS.get_process_id())])
	state = "searching"


func _stop() -> void:
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1
	if _udp:
		_udp.close()
	_udp = null
	state = "off"
	port_name = ""
	_clear_readings()


func _clear_readings() -> void:
	for key in ["hr_bpm", "spo2_pct", "skin_temp_c", "co2_ppm", "co2_mmhg", "pressure_hpa", "accel_g"]:
		set(key, NAN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _pid > 0:
			OS.kill(_pid)
			_pid = -1


func _handle(line: String) -> void:
	line = line.strip_edges()
	if not line.begins_with("{"):
		return  # the sketch's "# ..." diagnostic lines
	var json := JSON.new()  # (instance parse: a half-received first line fails quietly)
	if json.parse(line) != OK or not json.data is Dictionary:
		return
	var d: Dictionary = json.data
	if d.has("bridge"):
		var s := str(d["bridge"])
		port_name = str(d.get("port", port_name))
		if s == "connected":
			state = "connected"
			_last_packet = Time.get_ticks_msec()
		elif s == "busy":
			state = "busy"
		elif s == "searching" and state != "busy":
			state = "searching"
		elif s == "lost":
			state = "lost"
		elif s == "sent":
			last_sent = str(d.get("key", ""))
		return
	# A sensor reading. null = that sensor has no result right now; mirror it as-is
	# (the TFT shows dashes then too), so both always agree.
	state = "connected"
	_last_packet = Time.get_ticks_msec()
	hr_bpm = _num(d.get("hr_bpm"))
	spo2_pct = _num(d.get("spo2_pct"))
	skin_temp_c = _num(d.get("skin_temp_c"))
	co2_ppm = _num(d.get("co2_ppm"))
	co2_mmhg = co2_ppm * 760.0 / 1000000.0  # (NAN stays NAN)
	pressure_hpa = _num(d.get("pressure_hpa"))
	accel_g = _num(d.get("accel_g"))


func _num(v: Variant) -> float:
	return float(v) if (v is float or v is int) else NAN


## The serial -> UDP helper. Kept here (not as a separate file) so it also ships
## inside an exported .exe; it's written to user:// and started from there.
const BRIDGE_PS1 := r'''
param([int]$UdpPort = 47321, [int]$ParentPid = 0)
$ErrorActionPreference = 'Stop'
$udp = New-Object System.Net.Sockets.UdpClient
$udp.Connect('127.0.0.1', $UdpPort)
# Commands for the kit (TFT page keys) arrive on UdpPort + 100 and are written to serial.
$cmd = New-Object System.Net.Sockets.UdpClient (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback), ($UdpPort + 100))
function Forward-Commands($sp) {
    while ($cmd.Available -gt 0) {
        $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
        $k = [System.Text.Encoding]::ASCII.GetString($cmd.Receive([ref]$ep)).Trim()
        if ($k -match '^[1-5aAdDmMnNsSbBkK]$') { $sp.Write($k); Send ('{"bridge":"sent","key":"' + $k + '"}') }
    }
}
function Send([string]$s) { $b = [System.Text.Encoding]::UTF8.GetBytes($s); [void]$udp.Send($b, $b.Length) }
$script:lastCheck = [DateTime]::MinValue
function ParentAlive {
    if ($ParentPid -le 0) { return $true }
    if (([DateTime]::Now - $script:lastCheck).TotalSeconds -lt 2) { return $true }
    $script:lastCheck = [DateTime]::Now
    return [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
}
function IsTimeout($err) {
    $e = $err.Exception
    while ($e) { if ($e -is [System.TimeoutException]) { return $true }; $e = $e.InnerException }
    return $false
}
# USB serial ports first (CH340 / CP210x / FTDI boards), Bluetooth ports skipped.
function Get-Ports {
    $usb = @(); $other = @()
    $names = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique)
    $pnp = @()
    try { $pnp = @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'") } catch {}
    foreach ($n in $names) {
        $dev = $pnp | Where-Object { $_.Name -like "*($n)*" } | Select-Object -First 1
        $desc = if ($dev) { [string]$dev.Name } else { '' }
        if ($desc -match 'Bluetooth') { continue }
        if ($desc -match 'USB|CH34|CP21|Silicon Labs|FTDI|UART|Serial') { $usb += $n } else { $other += $n }
    }
    return @($usb + $other)
}
while (ParentAlive) {
    $ports = Get-Ports
    Send ('{"bridge":"searching","ports":' + $ports.Count + '}')
    $found = $false
    foreach ($name in $ports) {
        if (-not (ParentAlive)) { break }
        $sp = New-Object System.IO.Ports.SerialPort $name, 115200
        $sp.ReadTimeout = 1500
        $sp.NewLine = "`n"
        $sp.DtrEnable = $false
        $sp.RtsEnable = $false
        try { $sp.Open() } catch { Send ('{"bridge":"busy","port":"' + $name + '"}'); $sp.Dispose(); continue }
        # Is this the BioBeacon kit? Its data lines start with {"t_ms"
        $ok = $false
        $deadline = [DateTime]::Now.AddSeconds(4)
        while ([DateTime]::Now -lt $deadline) {
            try { $line = $sp.ReadLine().Trim() } catch { if (IsTimeout $_) { continue } else { break } }
            if ($line.StartsWith('{"t_ms"')) { $ok = $true; break }
        }
        if ($ok) {
            $found = $true
            Send ('{"bridge":"connected","port":"' + $name + '"}')
            Send $line
            $quiet = 0
            while (ParentAlive) {
                try {
                    Forward-Commands $sp
                    $line = $sp.ReadLine().Trim()
                    if ($line.StartsWith('{')) { Send $line }
                    $quiet = 0
                } catch {
                    if ((IsTimeout $_) -and $quiet -lt 2) { $quiet++ } else { break }
                }
            }
            Send ('{"bridge":"lost","port":"' + $name + '"}')
        }
        try { $sp.Close() } catch {}
        $sp.Dispose()
        if ($found) { break }
    }
    if (-not $found) { Start-Sleep -Milliseconds 1500 }
}
$udp.Close()
$cmd.Close()
'''
