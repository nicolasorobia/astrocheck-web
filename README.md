# BioBeacon

**An astronaut health-monitoring simulation built for the 2026 NASA Space Apps Challenge, connected to a real ESP32 sensor kit.**

Team: **Unartificial Intelligence**

### ▶ [Launch the simulation in your browser](https://nicolasorobia.github.io/astrocheck-web/)

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
- **Real sensor input**: with ESP32 Sensor Mode on, the suit CO2 reading comes from a real CO2 sensor instead of the simulation.
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

---

## ESP32 sensor kit

BioBeacon can read live data from a wearable-style sensor kit built around an ESP32. In our demo, the kit's **CO2 sensor** drives the astronaut's **suit CO2** in the game: breathe on the sensor and the value on the kit's screen and in Mission Control rise together.

### Hardware

| Part | What it measures / does | Connection |
|---|---|---|
| **ESP32 dev board** (CP2102 USB-to-serial) | Runs the firmware, reads every sensor, sends the data to the PC over USB | USB to the PC |
| **Sensirion SCD41** | CO2 (ppm), plus air temperature and humidity | I2C, address 0x62 |
| **MLX90614** infrared thermometer | Contact-free skin temperature | I2C, address 0x5A |
| **MAX30102** pulse oximeter | Heart rate and blood oxygen (SpO2) | I2C, address 0x57 |
| **MPU6050** (GY-521) accelerometer and gyroscope | Movement, activity and impact detection | I2C, address 0x68 |
| **BME280 / BMP280** | Air pressure (and humidity on the BME280) | I2C, address 0x76 |
| **1.8" ST7735 TFT** (128 × 160) | On-kit display: sensor pages and alerts | SPI |
| **2 push buttons** | Next and Select for the on-kit menu | GPIO 32 and 33 to GND |
| Breadboard, jumper wires, USB cable | Wiring and power | |

### Wiring

| Signal | ESP32 pin |
|---|---|
| I2C SDA (all sensors) | GPIO 25 |
| I2C SCL (all sensors) | GPIO 26 |
| TFT CS | GPIO 4 |
| TFT DC (A0) | GPIO 5 |
| TFT RST | GPIO 15 |
| TFT SDA / MOSI | GPIO 23 |
| TFT SCK | GPIO 18 |
| Next button | GPIO 32 |
| Select button | GPIO 33 |

All five sensors share one I2C bus at 100 kHz. The buttons use the ESP32's internal pull-ups, so each one just connects its pin to GND when pressed.

### How it works

```
 Sensors ──I2C──► ESP32 ──USB serial (115200 baud)──► Windows PC ──UDP ──► BioBeacon
                    │                                   PowerShell helper
                    └──SPI──► TFT screen
```

1. **Firmware (Arduino, C++)**: the ESP32 samples every sensor and runs each one's own measuring routine. For example, the SCD41 produces a new CO2 reading every 5 seconds, and the MLX90614 waits for a steady target, settles, then reports the median of about 50 readings. Ten times a second it prints one JSON line over USB:
   ```json
   {"t_ms":2275931, "hr_bpm":null, "spo2_pct":null, "skin_temp_c":25.1, "accel_g":0.99,
    "co2_ppm":701, "co2_mmhg":0.533, "cabin_temp_c":25.2, "humidity_pct":55, "pressure_hpa":1000.8}
   ```
   `null` means that sensor doesn't have a result yet. Lines starting with `#` are diagnostics.
2. **Bridge**: Godot can't open a COM port on its own. When **Settings → ESP32 Sensor Mode** is switched on, the game starts a small hidden PowerShell helper (built into Windows, nothing to install). The helper:
   - checks the USB serial ports (skipping Bluetooth ones)
   - recognises the kit by its JSON lines
   - forwards each line to the game over UDP on this PC only (127.0.0.1)
   - closes by itself when the game exits
3. **Game**: while fresh data keeps arriving, the live SCD41 value replaces the simulated suit CO2 on the Mission Control card and the on-screen HUD, labelled **ESP32**. CO2 is shown as a partial pressure in mmHg (ppm × 760 / 1,000,000, at sea-level pressure), the same unit the kit's screen uses. If the kit is unplugged, the game says SIGNAL LOST and goes back to the simulated value.

The Settings page shows the link status: **SEARCHING FOR DEVICE**, **CONNECTED · COMx**, or **BUSY** if another program (like the Arduino Serial Monitor) is already using the port.

### Demo mode

For the presentation we set the firmware to `CO2_ONLY`. In this mode:
- the TFT shows just the CO2 value, in large digits, in mmHg
- the on-kit menu and other sensor pages are hidden
- only a high-CO2 alert can take over the screen

This makes it easy to compare the kit and the game side by side. Every sensor keeps running and streaming in the background.

### Sensor status

| Sensor | Status |
|---|---|
| SCD41 CO2 | ✅ Live in the game (suit CO2) and on the kit's screen |
| MLX90614 skin temperature | Working on the kit. It needs the skin held still about 1 cm away for about 25 seconds per reading, so we kept the in-game body temperature simulated for the demo |
| MAX30102, MPU6050, BME280 | Wired and streaming from the kit, not yet used by the game |

### Limits

- **Not a medical device.** This is a hackathon prototype, and the alert thresholds are for demonstration only.
- The CO2 value is the carbon dioxide in the surrounding air, not the CO2 in a person's blood.
- The sensor link only works in the **Windows version** of BioBeacon. Browsers can't open USB serial ports from the game, so the web version always runs simulated.
- Only one program can use the kit's COM port at a time. Close the Arduino Serial Monitor before turning on ESP32 Sensor Mode.

### Arduino libraries used

- Adafruit GFX and Adafruit ST7735 (display)
- Adafruit MPU6050 and Adafruit Unified Sensor
- Adafruit MLX90614
- SparkFun MAX3010x (MAX30105 driver and `spo2_algorithm`)
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
