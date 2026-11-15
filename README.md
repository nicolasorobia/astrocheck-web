# Astrocheck

**An astronaut health-monitoring simulation built for the 2026 NASA Space Apps Challenge.**

Team: **[Unartificial Intelligence]**

### ▶ [Launch the simulation in your browser](https://nicolasorobia.github.io/astrocheck-web/)

> Works best in a recent version of Chrome, Edge or Firefox on a desktop or laptop. The first load downloads about 100 MB, so give it a moment while the system boots.

---

## About

Astrocheck puts you in the boots of an astronaut field-testing a new health-monitoring system on the Moon. While you work on the lunar surface, Mission Control follows your body in real time, and every decision you make shows up in your biometrics.

Your objective is to **collect all 10 lunar rock samples** and bring the mission home safely. To do that, you need to manage your oxygen, stamina, sleep and stress, avoid radiation hotspots, and know when to return to the habitat to rest.

The goal of the project is to show how continuous biometric monitoring could help keep explorers healthy on long-duration missions far from Earth.

## Features

- **Live biometrics dashboard**: heart rate, blood oxygen (SpO2), suit CO2, suit pressure, core body temperature, respiration, O2 tank, stamina, radiation dose, bone density, sleep score and stress score. The values are based on published NASA research ranges.
- **Connected physiology**: the readings affect each other.
  - Poor sleep and high stress make you breathe harder and burn more oxygen.
  - Sprinting drains stamina and O2 faster.
  - Overheating raises heart rate, respiration and stress.
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

## Coming soon: ESP32 sensor kit

We are connecting Astrocheck to a real **ESP32 biometric sensor kit**. With ESP32 Mode turned on (Settings → ESP32 Mode), the simulation will read live vitals from the hardware instead of simulating them, so a real person's body drives the astronaut on screen.

This repository will be updated once the hardware link is working.

## Mission crew

**[Team Unartificial Intelligence]**

- Migelle Orobia
- Vir Padhya
- Minnoli Shukla
- Clarissa Suryapranata
- Reda Mourtada

## Built with

- [Godot Engine 4.7](https://godotengine.org/), exported to the web (WebGL 2)

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
