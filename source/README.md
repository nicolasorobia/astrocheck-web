# BioBeacon source code

The complete Godot 4.7 project for BioBeacon, plus the ESP32 sensor kit firmware.
The playable web build lives one folder up, at the root of this repository.

## Opening the project

1. Install [Godot Engine 4.7](https://godotengine.org/download) (standard version, not .NET).
2. In the Godot Project Manager, click **Import** and choose `source/project.godot`.
3. The first import takes a few minutes while Godot processes the models, textures and audio.

## Purchased asset packs are not included

These packs were purchased, and their licenses don't allow sharing the raw files publicly. The game will open without them, but the HUD art and the player's astronaut will be missing until you add them:

| Pack | Get it from | Put it in |
|---|---|---|
| ShockFrame Sci-Fi Game UI by Ultra-Knight | [itch.io](https://ultra-knight.itch.io/sci-fi-game-ui-asset-pack-shockframe) | `assets/HUD/sci-fi - ShockFrame/` |
| Astronaut Modular Low Poly Stylized by agor2012 (the player's astronaut, `Astronaut_A.fbx`) | [itch.io](https://agor2012.itch.io/astronaut-modular-low-poly-stylized) | `assets/Astronaut/FAB/` |

Everything else (NASA 3D Resources models, Poly Haven rocks, Freesound audio) is included, with credits in the main README.

## Where things are

| Folder | What's in it |
|---|---|
| `levels/` | The main lunar surface scene |
| `player/` | Astronaut controller, first-person camera, vitals and biometrics simulation |
| `ui/` | Main menu, Mission Control (Tab) menu, HUD, biometrics cards, stats, crew panel |
| `interactables/` | Rock samples, rover repair, habitat rest, the team flag |
| `terrain/` | Lunar terrain built from the Apollo 17 landing site heightmap |
| `props/`, `tools/` | Lander, dish, habitat, sample-collection tools |
| `shaders/` | Ground, sky and screen effects |
| `esp32/esp32_link.gd` | Game side of the ESP32 link (starts the USB serial helper, reads the kit's data) |
| `esp32/cumilative_launch/` | Current ESP32 firmware (Arduino sketch, open `cumilative_launch.ino`) |
| `esp32/5sensors_deprecated/` | Earlier version of the firmware, kept for reference |
| `web/loader_shell.html` | The custom "BOOTING_SIMULATION" loading page for the web build |

## Exporting

- **Web:** Project → Export → **Web** preset (output goes to `builds/web/`).
- **Windows:** Project → Export → **Windows Desktop** preset (output goes to `builds/windows/BioBeacon.exe`; the ESP32 sensor link only works in this version).

Both need Godot's export templates (Editor → Manage Export Templates).
