# BioBeacon

**An astronaut health-monitoring simulation built for the 2026 NASA Space Apps Challenge, connected to a real ESP32 sensor kit.**

Team: **Unartificial Intelligence**

### ▶ [Launch the simulation in your browser](https://nicolasorobia.github.io/biobeacon-web/)

> Works best in a recent version of Chrome, Edge or Firefox on a desktop or laptop. The first load downloads about 100 MB, so give it a moment while the system boots.
>
> The browser version runs fully simulated. The live ESP32 sensor link needs the Windows version (see [ESP32 sensor kit](#esp32-sensor-kit) below).

---

## About

BioBeacon puts you in the boots of an astronaut field-testing a new health-monitoring system on the Moon. While you work on the lunar surface, Mission Control follows your body in real time, and every decision you make shows up in your biometrics.

Your objective is to **collect all 10 lunar rock samples** and bring the mission home safely. To do that, you need to manage your oxygen, stamina, sleep and stress, avoid radiation hotspots, and know when to return to the habitat to rest.

The goal of the project is to show how continuous biometric monitoring could help keep explorers healthy on long-duration missions far from Earth. To prove the idea works beyond the screen, we built a physical sensor kit whose readings feed straight into the simulation.

## Features

- **Live biometrics dashboard**: heart rate, blood oxygen (SpO2), suit CO2, suit pressure, core body temperature, respiration, O2 tank, stamina, radiation dose, bone density, sleep score and stress score. The values are based on published NASA research ranges.
- **Real sensor input**: with ESP32 Sensor Mode on, heart rate, blood oxygen, skin temperature, CO2 and suit pressure come from real sensors on our ESP32 kit instead of the simulation.
- **Connected physiology**: the readings affect each other.
  - Poor sleep and high stress make you breathe harder and burn more oxygen.
  - Sprinting drains stamina and O2 faster.
  - Overheating raises heart rate, respiration and stress.
  - High suit CO2 makes the astronaut lightheaded, and the view starts to sway.
- **Radiation hotspots**: purple zones scattered across the map spike your dose and core temperature. Stay in one too long and Mission Control has to pull you out for **critical hyperthermia**.
- **Medical rescue system**: if your oxygen, stamina or body temperature reach a critical level, Mission Control rescues you and restores your health systems. Every rescue is logged.
- **Day and night cycle with sleep**: one surface day lasts 4 minutes. Rest at the habitat to recover. Staying awake too long builds up sleep debt and lowers your sleep score.
- **Rover support**: repair the rover parked beside the lander, and it will help collect samples for you.
- **Expedition record**: every completed run is saved on a card showing:
  - days on the surface
  - real-world duration
  - samples collected by you vs. the rover
  - steps taken
  - medical rescues
- **Watch it live**: open Mission Control with **Tab** to see your biometrics while you keep walking around.

## Controls

| Key | Action |
|---|---|
| W A S D | Move |
| Mouse | Look around |
| Shift | Sprint (uses more O2 and stamina) |
| Space | Jump |
| E | Interact: hold to collect samples, repair and rest |
| F | Flashlight |
| Tab | Mission Control: live biometrics, stats and settings |
| Right mouse (hold) | Look around while Mission Control is open |
| F11 | Full screen on / off |
| 1 – 5, ← → | Switch the ESP32 kit's screen page (Windows version, kit connected) |

---

## ESP32 sensor kit

BioBeacon can read live data from a wearable-style sensor kit built around an ESP32. With **ESP32 Sensor Mode** on, the kit's readings replace the simulated ones in Mission Control and on the HUD. The kit's own screen shows the same numbers, in the same units, so the two can be compared side by side.

### Hardware

| Part | What it measures / does | Connection |
|---|---|---|
| **ESP32 dev board** (CP2102 USB-to-serial) | Runs the firmware, reads every sensor, sends the data to the PC over USB | USB to the PC |
| **MAX30102** pulse oximeter | Heart rate and blood oxygen (SpO2) | I2C, address 0x57 |
| **MLX90614** infrared thermometer | Contact-free skin temperature | I2C, address 0x5A |
| **MPU6050** (GY-521) accelerometer and gyroscope | Movement, activity and impact detection | I2C, address 0x68 |
| **BME280 / BMP280** | Air pressure, shown as suit pressure in the game (and humidity on the BME280) | I2C, address 0x76 |
| **Sensirion SCD41** | CO2 (ppm), plus air temperature and humidity | I2C, address 0x62 |
| **1.8" ST7735 TFT** (128 × 160) | On-kit display with one page per sensor | SPI |
| Breadboard, jumper wires, USB cable | Wiring and power | |

### Wiring

| Signal | ESP32 pin |
|---|---|
| I2C SDA (all sensors) | GPIO 25 |
| I2C SCL (all sensors) | GPIO 26 |
| TFT CS | GPIO 4 |
| TFT DC (A0 / RS) | GPIO 5 |
| TFT RST | GPIO 15 |
| TFT SDA / MOSI | GPIO 23 |
| TFT SCK | GPIO 18 |

All five sensors share one I2C bus at 100 kHz.

### How it works

```
 Sensors ──I2C──► ESP32 ──USB serial (115200 baud)──► Windows PC ──UDP ──► BioBeacon
                    │                                   PowerShell helper
                    └──SPI──► TFT screen
```

1. **Firmware (Arduino, C++)**: on start-up the TFT plays a short launch animation. After that, the ESP32 samples every sensor and runs each one's own measuring routine. For example:
   - the MAX30102 waits for a steady finger, warms up, then reports the median of a 30-second window
   - the MLX90614 waits for a steady target, settles, then reports the median of about 50 readings
   - the SCD41 produces a new CO2 reading every 5 seconds

   Ten times a second the firmware prints one JSON line over USB:
   ```json
   {"t_ms":5000, "hr_bpm":72, "spo2_pct":98, "skin_temp_c":33.6, "accel_g":1.00,
    "co2_ppm":701, "cabin_temp_c":24.1, "humidity_pct":48, "pressure_hpa":1009.6}
   ```
   `null` means that sensor doesn't have a result right now (no finger on it, still measuring, and so on). Lines starting with `#` are diagnostics.
2. **Bridge**: Godot can't open a COM port on its own. When **Settings → ESP32 Sensor Mode** is switched on, the game starts a small hidden PowerShell helper (built into Windows, nothing to install). The helper:
   - checks the USB serial ports (skipping Bluetooth ones)
   - recognises the kit by its JSON lines
   - forwards each line to the game over UDP on the same PC (127.0.0.1)
   - passes the game's page keys back to the kit
   - closes by itself when the game exits
3. **Game**: while fresh data keeps arriving, each live reading replaces its simulated value and is labelled **ESP32**. The game uses the same units, rounding and normal / caution / alert thresholds as the kit's screen. When a sensor has no result yet, the game shows dashes and **MEASURING**, just like the TFT. If the kit is unplugged, the game says SIGNAL LOST and goes back to the simulated values.

The Settings page shows the link status: **SEARCHING FOR DEVICE**, **CONNECTED · COMx**, or **BUSY** if another program (like the Arduino Serial Monitor) is already using the port.

### Switching the kit's screen

The kit's TFT has one page per sensor. While the game is connected, you can switch pages from inside the game, without touching the kit:

| Key | TFT page |
|---|---|
| **1** | Heart rate / blood oxygen |
| **2** | Skin temperature |
| **3** | Motion |
| **4** | Pressure |
| **5** | Air quality (CO2) |
| **→** / **←** | Next / previous page |

Without the game, the same keys work from the Arduino Serial Monitor (1–5, and A / D for next / previous).

### Sensor status

| Sensor | In the game | Notes |
|---|---|---|
| MAX30102 heart rate and SpO2 | ✅ Live | Finger on the sensor for about 1 minute per reading |
| MLX90614 skin temperature | ✅ Live (replaces core temperature) | Skin held still about 1 cm away for about 25 seconds per reading |
| SCD41 CO2 | ✅ Live, in ppm (mmHg also shown) | New reading every 5 seconds |
| BME280 pressure | ✅ Live as suit pressure, in hPa (psi also shown) | Normal range 980–1040 hPa |

The live values are shown on screen only. The astronaut's simulation and its warnings keep running on their own numbers.

### Limits

- **Not a medical device.** This is a hackathon prototype, and the alert thresholds are for demonstration only.
- The CO2 value is the carbon dioxide in the surrounding air, not the CO2 in a person's blood.
- The suit pressure value comes from the surrounding air pressure, which stands in for a real spacesuit's pressure in this demo.
- The sensor link only works in the **Windows version** of BioBeacon. Browsers can't open USB serial ports from the game, so the web version always runs simulated.
- Only one program can use the kit's COM port at a time. Close the Arduino Serial Monitor before turning on ESP32 Sensor Mode.

### Arduino libraries used

- Adafruit GFX and Adafruit ST7735 (display)
- Adafruit MLX90614
- Adafruit MPU6050 and Adafruit Unified Sensor
- SparkFun MAX3010x 1.1.2 (driver and `spo2_algorithm`, bundled with the sketch)
- The SCD41 and BME280 / BMP280 are read with direct I2C commands (the `Wire` library), with no extra library.

---

## Mission crew

**Team Unartificial Intelligence**

- Nico Orobia
- Vir Padhya
- Minnoli Shukla
- Clarissa Suryapranata
- Reda Mourtada

## Built with

- [Godot Engine 4.7](https://godotengine.org/), exported to the web (WebGL 2) and Windows
- ESP32 with the Arduino framework

## Credits and sources

### itch.io
- [ShockFrame Sci-Fi Game UI](https://ultra-knight.itch.io/sci-fi-game-ui-asset-pack-shockframe) by Ultra-Knight: menus and HUD (bars, compass, panels, buttons, icons)
- [Astronaut Modular Low Poly Stylized](https://agor2012.itch.io/astronaut-modular-low-poly-stylized) by agor2012: the player's astronaut and its animations

### Poly Haven
- [Moon Rocks 01, 04, 05, 07](https://polyhaven.com/models/nature/rocks-stone): rock samples and scattered rocks

### NASA 3D Resources
All from [science.nasa.gov/3d-resources](https://science.nasa.gov/3d-resources/):
- **Apollo Lunar Module**: the lander at the landing site
- **70 Meter Dish**: comms dish beside the lander
- **Habitat Demonstration Unit (part 1)**: the base habitat and the outposts
- **Perseverance Rover**: the rover you repair
- **Apollo 17 Landing Site**: terrain heightmap and ground level
- **Apollo Hammer, Rake and Scoop**: sample-collection tools
- **Sample Container**: sealing samples
- **Wrench**: rover repair

### Audio
- [Freesound](https://freesound.org/): footsteps, tools, rover, ambience, music and UI sounds

---

*Created for the 2026 NASA Space Apps Challenge. This project is not affiliated with or endorsed by NASA.*
