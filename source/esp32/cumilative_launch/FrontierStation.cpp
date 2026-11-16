// The Next Frontier. Five sensor pages on one ESP32 and TFT.
#include <Arduino.h>
#include <math.h>
#include <new>
#include <stdlib.h>
#include <string.h>
#include <Wire.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <Adafruit_MLX90614.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
// Local SparkFun MAX3010x 1.1.2 sources keep the driver and algorithm together.
#include "Frontier_MAX30105.h"
#include "Frontier_spo2_algorithm.h"

namespace {
// ---------- Pins (from your whiteboard) ----------
const int SDA_PIN = 25;
const int SCL_PIN = 26;
const int TFT_CS  = 4;
const int TFT_DC  = 5;    // "RS" / "D/C" on the display
const int TFT_RST = 15;
// TFT SCK = GPIO 18, TFT SDA (MOSI) = GPIO 23 (default hardware SPI)

// ---------- Display ----------
Adafruit_ST7735 tft(TFT_CS, TFT_DC, TFT_RST);

// The Next Frontier palette, in RGB565.
const uint16_t C_BG      = 0x0845;
const uint16_t C_PANEL   = 0x10C9;
const uint16_t C_BORDER  = 0x29AD;
const uint16_t C_GREY    = 0xA55A;
const uint16_t C_ICE     = 0xE73F;
const uint16_t C_CYAN    = 0x5FDF;
const uint16_t C_VIOLET  = 0xABDF;
const uint16_t C_GREEN   = 0x6FF1;
const uint16_t C_AMBER   = 0xFDE9;
const uint16_t C_RED     = 0xFB6E;

constexpr int ORBIT_SIZE = 28;
constexpr int ORBIT_CENTER = ORBIT_SIZE / 2;
GFXcanvas16 orbit(ORBIT_SIZE, ORBIT_SIZE);

uint16_t levelColor(int lvl) {
  return lvl == 0 ? C_GREEN : (lvl == 1 ? C_AMBER : C_RED);
}

void drawRocket() {
  static uint8_t frame = 0;
  const float angle = frame * (TWO_PI / 16.0f);
  const float radialX = cosf(angle);
  const float radialY = sinf(angle);
  // Clockwise tangent in screen coordinates.
  const float forwardX = -radialY;
  const float forwardY = radialX;
  const int x = ORBIT_CENTER + lroundf(9 * radialX);
  const int y = ORBIT_CENTER + lroundf(9 * radialY);
  const int tailX = x - lroundf(2 * forwardX);
  const int tailY = y - lroundf(2 * forwardY);
  const int finX = lroundf(2 * radialX);
  const int finY = lroundf(2 * radialY);

  orbit.fillScreen(C_BG);
  orbit.drawCircle(ORBIT_CENTER, ORBIT_CENTER, 9, C_BORDER);
  // A shaded planet at the center of the orbit.
  orbit.fillCircle(ORBIT_CENTER, ORBIT_CENTER, 3, C_VIOLET);
  orbit.drawPixel(ORBIT_CENTER - 1, ORBIT_CENTER - 1, C_ICE);
  orbit.drawFastHLine(ORBIT_CENTER - 1, ORBIT_CENTER + 2, 4, C_BORDER);

  orbit.drawLine(tailX, tailY, x - lroundf(5 * forwardX),
                 y - lroundf(5 * forwardY), C_AMBER);
  orbit.fillTriangle(x + lroundf(3 * forwardX), y + lroundf(3 * forwardY),
                     tailX + finX, tailY + finY, tailX - finX, tailY - finY,
                     C_ICE);
  orbit.drawPixel(x, y, C_CYAN);
  if (orbit.getBuffer()) {
    tft.drawRGBBitmap(99, 1, orbit.getBuffer(), ORBIT_SIZE, ORBIT_SIZE);
  }
  frame = (frame + 1) % 16;
}

// ---------- I2C debug ----------
// Lines starting with '#' are debug text, not JSON. The bridge should ignore them.
void scanI2C() {
  Serial.print("# I2C scan:");
  int n = 0;
  for (uint8_t a = 1; a < 127; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) {
      Serial.print(" 0x");
      Serial.print(a, HEX);
      n++;
    }
  }
  if (n == 0) Serial.print(" none");
  Serial.println();
}

constexpr uint32_t PRINT_INTERVAL = 100;
constexpr uint32_t DISPLAY_INTERVAL = 250;
uint32_t lastPrint = 0;
uint32_t lastDraw = 0;
bool redrawPage = false;

void drawMeasurementStatus(const char *text, uint16_t color) {
  static char last[24] = "";
  static uint16_t lastColor = 0;
  if (!redrawPage && strcmp(text, last) == 0 && color == lastColor) return;
  snprintf(last, sizeof(last), "%s", text);
  lastColor = color;
  tft.fillRoundRect(3, 137, 122, 20, 5, C_PANEL);
  tft.drawRoundRect(3, 137, 122, 20, 5, color);
  tft.setTextSize(1);
  tft.setTextColor(color, C_PANEL);
  const int x = (128 - 6 * (int)strlen(text)) / 2;
  if (x > 24) tft.fillCircle(16, 147, 2, color);
  tft.setCursor(x, 143);
  tft.print(text);
}

void drawMeasurementProgress(int percent, uint16_t color) {
  static int lastWidth = -1;
  static uint16_t lastColor = 0;
  const int width = constrain(percent, 0, 100) * 118 / 100;
  if (!redrawPage && width == lastWidth && color == lastColor) return;
  lastWidth = width;
  lastColor = color;
  tft.fillRect(5, 132, 118, 3, C_BORDER);
  if (width > 0) tft.fillRect(5, 132, width, 3, color);
}

// ---------- Startup animation ----------
constexpr int LAUNCH_WIDTH = 128;
constexpr int LAUNCH_HEIGHT = 94;
constexpr int LAUNCH_TOP = 51;
constexpr int LAUNCH_CENTER_X = 64;
constexpr int LAUNCH_CENTER_Y = 46;
constexpr uint32_t LAUNCH_DURATION = 2500;
constexpr uint32_t LAUNCH_FRAME_INTERVAL = 45;
constexpr uint16_t C_PLANET_SHADOW = 0x2950;
constexpr uint16_t C_PLANET_BODY = 0x52BC;
constexpr uint16_t C_PLANET_LIGHT = 0x8CFF;

GFXcanvas16 *launchCanvas = nullptr;
bool launchActive = true;
uint32_t launchStartedAt = 0;
uint32_t lastLaunchFrame = 0;

struct LaunchPoint {
  int16_t x;
  int16_t y;
};

struct RocketPose {
  float x;
  float y;
  float dx;
  float dy;

  LaunchPoint point(int forward, int side) const {
    return {
      (int16_t)lroundf(x + forward * dx - side * dy),
      (int16_t)lroundf(y + forward * dy + side * dx),
    };
  }
};

void launchTriangle(Adafruit_GFX &scene, LaunchPoint a, LaunchPoint b,
                    LaunchPoint c, uint16_t color) {
  scene.fillTriangle(a.x, a.y, b.x, b.y, c.x, c.y, color);
}

LaunchPoint launchOrbitPoint(float angle) {
  const float radialX = cosf(angle);
  return {
    (int16_t)lroundf(LAUNCH_CENTER_X + 46 * radialX),
    (int16_t)lroundf(LAUNCH_CENTER_Y + 23 * sinf(angle) - 8 * radialX),
  };
}

void drawLaunchOrbit(Adafruit_GFX &scene, float start, uint16_t color) {
  LaunchPoint prev = launchOrbitPoint(start);
  for (int i = 1; i <= 24; ++i) {
    const LaunchPoint next = launchOrbitPoint(start + i * (PI / 24.0f));
    scene.drawLine(prev.x, prev.y, next.x, next.y, color);
    prev = next;
  }
}

void drawLaunchShip(Adafruit_GFX &scene, float angle, bool brightFlame) {
  const LaunchPoint center = launchOrbitPoint(angle);
  // The derivative of the orbit points the nose along its flight path.
  const float vx = -46 * sinf(angle);
  const float vy = 23 * cosf(angle) + 8 * sinf(angle);
  const float speed = sqrtf(vx * vx + vy * vy);
  const RocketPose ship = {(float)center.x, (float)center.y, vx / speed, vy / speed};

  launchTriangle(scene, ship.point(-5, -3), ship.point(-5, 3),
                 ship.point(brightFlame ? -16 : -12, 0), C_AMBER);
  launchTriangle(scene, ship.point(-5, -2), ship.point(-5, 2),
                 ship.point(-10, 0), C_ICE);
  launchTriangle(scene, ship.point(0, -2), ship.point(-6, -7),
                 ship.point(-6, -2), C_VIOLET);
  launchTriangle(scene, ship.point(0, 2), ship.point(-6, 7),
                 ship.point(-6, 2), C_VIOLET);
  launchTriangle(scene, ship.point(12, 0), ship.point(-6, -4),
                 ship.point(-6, 4), C_ICE);
  const LaunchPoint window = ship.point(2, 0);
  scene.fillCircle(window.x, window.y, 2, C_CYAN);
  scene.drawPixel(window.x, window.y, C_BG);
}

void drawLaunchFrame(uint32_t elapsed) {
  if (launchCanvas && launchCanvas->getBuffer()) {
    static const LaunchPoint stars[] = {
      {8, 8}, {26, 15}, {47, 6}, {73, 9}, {93, 16}, {114, 7}, {122, 29},
      {13, 33}, {25, 44}, {41, 22}, {76, 19}, {90, 33}, {106, 25},
      {6, 64}, {17, 76}, {31, 62}, {39, 84}, {58, 78}, {72, 88},
      {88, 75}, {104, 64}, {114, 82}, {121, 57}, {95, 87}, {24, 89},
    };
    const unsigned frame = elapsed / LAUNCH_FRAME_INTERVAL;
    GFXcanvas16 &scene = *launchCanvas;
    scene.fillScreen(C_BG);
    for (unsigned i = 0; i < sizeof(stars) / sizeof(stars[0]); ++i) {
      const LaunchPoint star = stars[i];
      const bool twinkle = (i * 3 + frame / 3) % 11 == 0;
      scene.drawPixel(star.x, star.y, twinkle ? C_ICE : (i % 4 == 0 ? C_VIOLET : C_BORDER));
      if (twinkle) {
        scene.drawFastHLine(star.x - 2, star.y, 5, C_BORDER);
        scene.drawFastVLine(star.x, star.y - 2, 5, C_BORDER);
        scene.drawPixel(star.x, star.y, C_ICE);
      }
    }

    drawLaunchOrbit(scene, PI, C_BORDER);
    const int cx = LAUNCH_CENTER_X;
    const int cy = LAUNCH_CENTER_Y;
    scene.fillCircle(cx, cy, 21, C_PLANET_SHADOW);
    scene.fillCircle(cx - 3, cy - 3, 17, C_PLANET_BODY);
    scene.drawFastHLine(cx - 16, cy - 10, 13, C_PLANET_LIGHT);
    scene.drawFastHLine(cx - 19, cy - 6, 21, C_PLANET_LIGHT);
    scene.drawFastHLine(cx - 11, cy + 6, 23, C_PLANET_SHADOW);
    scene.drawCircle(cx, cy, 21, C_VIOLET);
    drawLaunchOrbit(scene, 0, C_CYAN);

    const float angle = -PI * 0.7f + TWO_PI * elapsed / 2000.0f;
    drawLaunchShip(scene, angle, frame % 4 < 2);
    tft.drawRGBBitmap(0, LAUNCH_TOP, scene.getBuffer(), LAUNCH_WIDTH, LAUNCH_HEIGHT);
  }

  const int progress = min((int)(elapsed * 104 / LAUNCH_DURATION), 104);
  if (progress > 0) tft.drawFastHLine(12, 151, progress, C_CYAN);
}

void beginLaunch() {
  launchCanvas = new (std::nothrow) GFXcanvas16(LAUNCH_WIDTH, LAUNCH_HEIGHT);
  tft.fillScreen(C_BG);
  tft.setTextSize(2);
  tft.setTextColor(C_VIOLET, C_BG);
  tft.setCursor(16, 11);
  tft.print("THE NEXT");
  tft.setTextColor(C_ICE, C_BG);
  tft.setCursor(16, 30);
  tft.print("FRONTIER");
  tft.drawFastHLine(12, 48, 104, C_BORDER);
  tft.drawFastHLine(52, 48, 24, C_CYAN);
  tft.drawFastHLine(12, 151, 104, C_BORDER);
  drawLaunchFrame(0);
}

namespace Vitals {
// ---------------- SENSOR SETTINGS ----------------

// Was 60, which gave IR ~240,000 (near the 262,143 ceiling of the 18-bit ADC).
// 20 should put IR around 50,000-100,000. Tune it: raise if IR stays < 30,000,
// lower if it is still > 150,000 with a normal finger.
const uint8_t LED_BRIGHTNESS = 20;

const uint32_t FINGER_THRESHOLD = 3000;   // below this = no finger / weak
const uint32_t IR_SATURATED = 250000;     // above this = too strong, treated as bad

const int BUF_LEN = 100;
const int RECALC_EVERY = 25;
const int BAD_SAMPLE_LIMIT = 50;          // finger considered gone
const int GAP_RESTART_SAMPLES = 5;        // this many bad samples restarts the warm-up

// ---------------- MEASUREMENT TIMING ----------------

const uint32_t FINGER_STABLE_MS = 2000;   // good signal needed before warm-up starts
const uint32_t WARMUP_MS = 30000;         // settling time (set 15000 once signal is clean)
const uint32_t MEASURE_MS = 30000;        // collection window
const uint32_t RETRY_WARMUP_MS = 10000;   // shorter warm-up after an unstable result
const uint32_t UNSTABLE_SHOW_MS = 3000;   // how long "UNSTABLE" is shown

// ---------------- RESULT QUALITY ----------------

const int MAX_SAMPLES = 64;               // storage for window samples
const int MIN_SAMPLES = 12;               // minimum valid samples to trust a result

const float HR_OUTLIER_FRAC = 0.25f;      // drop HR more than 25% from the median
const int SPO2_OUTLIER_ABS = 4;           // drop SpO2 more than 4 points from the median
const int HR_MAX_IQR = 15;                // spread limit (25th-75th percentile), bpm
const int SPO2_MAX_IQR = 3;               // spread limit, percentage points


// ---------------- SENSOR STATE ----------------

MAX30105 sensor;

bool sensorOk = false;
bool fingerPresent = false;

uint32_t lastInitTry = 0;
uint32_t lastDebug = 0;
uint32_t lastGoodSample = 0;

uint32_t irBuf[BUF_LEN];
uint32_t redBuf[BUF_LEN];

int filled = 0;
int newSinceCalc = 0;
int badSamples = 0;

int32_t rawHr = 0;
int32_t rawSpo2 = 0;

int8_t hrValid = 0;
int8_t spo2Valid = 0;

// ---------------- MEASUREMENT STATE ----------------

enum State {
  ST_WAIT,
  ST_WARMUP,
  ST_MEASURE,
  ST_DONE,
  ST_UNSTABLE
};

const char *STATE_NAMES[] = {
  "WAIT", "WARMUP", "MEASURE", "DONE", "UNSTABLE"
};

State state = ST_WAIT;
uint32_t stateStart = 0;
uint32_t goodSince = 0;
uint32_t warmupMs = WARMUP_MS;

int hrSamples[MAX_SAMPLES];
int spSamples[MAX_SAMPLES];
int hrCount = 0;
int spCount = 0;

// Final single result
int displayHr = 0;
int displaySpo2 = 0;
bool haveHr = false;
bool haveSpo2 = false;

void resetMeasurement();

struct Field { char txt[5]; uint16_t color; };
Field fHr = {"", 0}, fSp = {"", 0};

// 0 = ok, 1 = caution, 2 = alert. Demo thresholds, not medical limits.
int hrLevel(int v) {
  if (v >= 60 && v <= 100) return 0;

  if ((v >= 50 && v < 60) ||
      (v > 100 && v <= 120)) return 1;

  return 2;
}

int spo2Level(int v) {
  if (v >= 95) return 0;
  if (v >= 90) return 1;
  return 2;
}

void sortInts(int *a, int n) {
  for (int i = 1; i < n; i++) {
    int key = a[i];
    int j = i - 1;

    while (j >= 0 && a[j] > key) {
      a[j + 1] = a[j];
      j--;
    }

    a[j + 1] = key;
  }
}

// Median of the window after outlier rejection.
// Returns false if there are too few samples or the spread is too large.
bool summarize(
  const int *vals, int n,
  float frac, int minAbs, int maxIqr,
  int *out
) {
  if (n < MIN_SAMPLES) return false;

  int tmp[MAX_SAMPLES];
  memcpy(tmp, vals, n * sizeof(int));
  sortInts(tmp, n);

  int med = tmp[n / 2];

  int dev = (int)(med * frac);
  if (dev < minAbs) dev = minAbs;

  // tmp is sorted, so kept[] stays sorted.
  int kept[MAX_SAMPLES];
  int k = 0;

  for (int i = 0; i < n; i++) {
    if (abs(tmp[i] - med) <= dev) kept[k++] = tmp[i];
  }

  if (k < MIN_SAMPLES || k < n / 2) return false;

  int q1 = kept[k / 4];
  int q3 = kept[(3 * k) / 4];

  if (q3 - q1 > maxIqr) return false;

  *out = kept[k / 2];
  return true;
}

void drawCard(int y, const char *label, const char *unit, uint16_t accent) {
  tft.fillRoundRect(3, y, 122, 47, 5, C_PANEL);
  tft.drawRoundRect(3, y, 122, 47, 5, C_BORDER);
  tft.drawFastVLine(8, y + 6, 7, accent);
  tft.setTextSize(1);
  tft.setTextColor(C_ICE, C_PANEL);
  tft.setCursor(13, y + 6);
  tft.print(label);
  tft.setCursor(91, y + 31);
  tft.print(unit);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.drawPixel(69, 6, C_BORDER);
  tft.drawPixel(85, 4, C_VIOLET);
  tft.drawPixel(93, 10, C_BORDER);

  tft.setTextSize(1);
  tft.setTextColor(C_VIOLET, C_BG);
  tft.setCursor(5, 3);
  tft.print("THE NEXT");
  tft.setTextSize(2);
  tft.setTextColor(C_ICE, C_BG);
  tft.setCursor(4, 13);
  tft.print("FRONTIER");
  tft.drawFastHLine(4, 31, 120, C_BORDER);
  tft.drawFastHLine(4, 31, 24, C_CYAN);

  drawCard(35, "HEART RATE", "bpm", C_CYAN);
  drawCard(83, "BLOOD OXYGEN", "%", C_VIOLET);
}

void drawField(Field &f, int y, bool valid, int v, uint16_t color) {
  char buf[5];
  if (valid) snprintf(buf, sizeof(buf), "%3d", v);
  else       strcpy(buf, "---");
  if (!redrawPage && (strcmp(buf, f.txt) == 0 && color == f.color)) return;   // nothing changed
  strcpy(f.txt, buf);
  f.color = color;
  tft.setTextSize(3);
  tft.setTextColor(color, C_PANEL);
  tft.setCursor(10, y);
  tft.print(buf);
}

void setState(State s) {
  state = s;
  stateStart = millis();

  if (s == ST_MEASURE) {
    hrCount = 0;
    spCount = 0;
  }

  Serial.print("# STATE -> ");
  Serial.println(STATE_NAMES[s]);
}

void startNewMeasurement() {
  haveHr = false;
  haveSpo2 = false;
  warmupMs = WARMUP_MS;
  setState(ST_WARMUP);
}

void finishMeasurement() {
  int hr = 0;
  int sp = 0;

  bool okHr = summarize(
    hrSamples, hrCount,
    HR_OUTLIER_FRAC, 0, HR_MAX_IQR, &hr
  );

  bool okSp = summarize(
    spSamples, spCount,
    0.0f, SPO2_OUTLIER_ABS, SPO2_MAX_IQR, &sp
  );

  Serial.print("# WINDOW hr_samples: ");
  Serial.print(hrCount);
  Serial.print(" spo2_samples: ");
  Serial.println(spCount);

  if (okHr && okSp) {
    displayHr = hr;
    displaySpo2 = sp;
    haveHr = true;
    haveSpo2 = true;

    Serial.print("# RESULT HR: ");
    Serial.print(hr);
    Serial.print(" SPO2: ");
    Serial.println(sp);

    setState(ST_DONE);
  } else {
    Serial.println("# RESULT unstable, retrying");
    setState(ST_UNSTABLE);
  }
}

void updateState() {
  uint32_t now = millis();

  if (!sensorOk) {
    goodSince = 0;
    state = ST_WAIT;
    return;
  }

  // Signal lost -> back to WAIT.
  if (state == ST_DONE) {
    // Keep the result until the finger is really lifted.
    if (!fingerPresent) {
      goodSince = 0;
      setState(ST_WAIT);
      return;
    }
  } else if (state != ST_WAIT &&
             badSamples >= GAP_RESTART_SAMPLES) {
    goodSince = 0;
    setState(ST_WAIT);
    return;
  }

  bool signalGood =
    fingerPresent &&
    badSamples == 0 &&
    now - lastGoodSample < 500;

  switch (state) {
    case ST_WAIT:
      if (signalGood) {
        if (goodSince == 0) goodSince = now;

        if (now - goodSince >= FINGER_STABLE_MS) {
          goodSince = 0;
          startNewMeasurement();
        }
      } else {
        goodSince = 0;
      }
      break;

    case ST_WARMUP:
      if (now - stateStart >= warmupMs) {
        setState(ST_MEASURE);
      }
      break;

    case ST_MEASURE:
      if (now - stateStart >= MEASURE_MS) {
        finishMeasurement();
      }
      break;

    case ST_UNSTABLE:
      if (now - stateStart >= UNSTABLE_SHOW_MS) {
        warmupMs = RETRY_WARMUP_MS;
        setState(ST_WARMUP);
      }
      break;

    case ST_DONE:
    default:
      break;
  }
}

// ---------------- UPDATE DISPLAY ----------------

void updateDisplay() {
  uint32_t now = millis();

  int hl = haveHr ? hrLevel(displayHr) : -1;
  int sl = haveSpo2 ? spo2Level(displaySpo2) : -1;

  drawField(
    fHr, 52,
    haveHr, displayHr,
    haveHr ? levelColor(hl) : C_GREY
  );

  drawField(
    fSp, 100,
    haveSpo2, displaySpo2,
    haveSpo2 ? levelColor(sl) : C_GREY
  );

  char txt[24];
  uint16_t color = C_GREY;
  int pct = 0;
  uint16_t barColor = C_CYAN;

  if (!sensorOk) {
    strcpy(txt, "NO SENSOR");
    color = C_RED;
  }
  else {
    uint32_t elapsed = now - stateStart;

    switch (state) {
      case ST_WAIT:
        if (haveHr) {
          strcpy(txt, "LAST READING");
          color = C_GREY;
        } else if (fingerPresent) {
          strcpy(txt, "DETECTING FINGER");
          color = C_CYAN;
        } else {
          strcpy(txt, "NO FINGER");
          color = C_GREY;
        }
        break;

      case ST_WARMUP: {
        uint32_t left = elapsed >= warmupMs
          ? 0 : (warmupMs - elapsed + 999) / 1000;

        snprintf(txt, sizeof(txt), "SETTLING %lus", (unsigned long)left);
        color = C_AMBER;
        pct = (int)(elapsed * 100 / warmupMs);
        barColor = C_AMBER;
        break;
      }

      case ST_MEASURE: {
        uint32_t left = elapsed >= MEASURE_MS
          ? 0 : (MEASURE_MS - elapsed + 999) / 1000;

        snprintf(txt, sizeof(txt), "MEASURING %lus", (unsigned long)left);
        color = C_CYAN;
        pct = (int)(elapsed * 100 / MEASURE_MS);
        barColor = C_CYAN;
        break;
      }

      case ST_UNSTABLE:
        strcpy(txt, "UNSTABLE - RETRY");
        color = C_AMBER;
        break;

      case ST_DONE:
      default: {
        int worst = hl > sl ? hl : sl;

        strcpy(
          txt,
          worst == 0 ? "NOMINAL" :
          worst == 1 ? "CAUTION" : "ALERT"
        );

        color = levelColor(worst);
        pct = 100;
        barColor = color;
        break;
      }
    }
  }

  drawMeasurementProgress(pct, barColor);
  drawMeasurementStatus(txt, color);
}

bool initSensor() {
  if (!sensor.begin(Wire, 100000UL))
    return false;

  sensor.setup(
    LED_BRIGHTNESS,  // LED brightness (lowered to avoid near-saturation)
    4,               // Sample averaging
    2,               // Red + IR
    100,             // Sample rate
    411,             // Pulse width
    4096             // ADC range
  );

  return true;
}

// ---------------- RESET WINDOW ----------------

void resetMeasurement() {
  filled = 0;
  newSinceCalc = 0;

  hrValid = 0;
  spo2Valid = 0;
}

// ---------------- CALCULATE VITALS ----------------

void recalc() {
  maxim_heart_rate_and_oxygen_saturation(
    irBuf,
    BUF_LEN,
    redBuf,
    &rawSpo2,
    &spo2Valid,
    &rawHr,
    &hrValid
  );

  // Only collect samples during the measurement window.
  if (state == ST_MEASURE) {
    if (hrValid == 1 &&
        rawHr >= 40 && rawHr <= 180 &&
        hrCount < MAX_SAMPLES) {
      hrSamples[hrCount++] = rawHr;
    }

    if (spo2Valid == 1 &&
        rawSpo2 >= 70 && rawSpo2 <= 100 &&
        spCount < MAX_SAMPLES) {
      spSamples[spCount++] = rawSpo2;
    }
  }

  newSinceCalc = 0;
}

// ---------------- PROCESS SAMPLE ----------------

void addSample(uint32_t red, uint32_t ir) {
  if (millis() - lastDebug >= 500) {
    lastDebug = millis();

    Serial.print("# IR: ");
    Serial.print(ir);

    Serial.print(" RED: ");
    Serial.print(red);

    Serial.print(" RAW_HR: ");
    if (hrValid == 1)
      Serial.print(rawHr);
    else
      Serial.print("invalid");

    Serial.print(" STATE: ");
    Serial.print(STATE_NAMES[state]);

    Serial.print(" buffered: ");
    Serial.print(filled);

    Serial.print(" weak_count: ");
    Serial.println(badSamples);
  }

  // Too weak (no finger) or too strong (saturated).
  if (ir < FINGER_THRESHOLD || ir > IR_SATURATED) {
    badSamples++;

    if (badSamples >= BAD_SAMPLE_LIMIT) {
      fingerPresent = false;
      resetMeasurement();
    }

    return;
  }

  // Do not join samples across a gap.
  if (badSamples > 0) {
    resetMeasurement();
  }

  badSamples = 0;
  fingerPresent = true;
  lastGoodSample = millis();

  if (filled < BUF_LEN) {
    redBuf[filled] = red;
    irBuf[filled] = ir;

    filled++;

    if (filled == BUF_LEN)
      recalc();

  } else {
    memmove(
      redBuf,
      redBuf + 1,
      (BUF_LEN - 1) * sizeof(uint32_t)
    );

    memmove(
      irBuf,
      irBuf + 1,
      (BUF_LEN - 1) * sizeof(uint32_t)
    );

    redBuf[BUF_LEN - 1] = red;
    irBuf[BUF_LEN - 1] = ir;

    newSinceCalc++;

    if (newSinceCalc >= RECALC_EVERY)
      recalc();
  }
}

// ---------------- JSON OUTPUT ----------------

void tick() {
  if (!sensorOk) {
    if (millis() - lastInitTry > 2000) {
      lastInitTry = millis();

      sensorOk = initSensor();

      if (sensorOk) {
        resetMeasurement();
        haveHr = false;
        haveSpo2 = false;
        setState(ST_WAIT);
      }
    }
  } else {
    sensor.check();

    while (sensor.available()) {
      addSample(
        sensor.getFIFORed(),
        sensor.getFIFOIR()
      );

      sensor.nextSample();
    }
  }

  updateState();

}
}  // namespace Vitals

namespace Skin {
// ---------- Timing ----------
const uint32_t SAMPLE_INTERVAL  = 200;     // ms -> 5 sensor reads/sec

const uint32_t SETTLE_MS        = 10000;   // calibration time (try 15000-20000 if needed)
const uint32_t MEASURE_MS       = 10000;   // collection window
const uint32_t RETRY_SETTLE_MS  = 5000;    // shorter calibration after an unstable result
const uint32_t UNSTABLE_SHOW_MS = 3000;    // how long "HOLD STEADY" is shown

// ---------- Sensor hardware range ----------
// These are the MLX90614 datasheet limits (what the chip can physically report),
// NOT limits on what objects you may measure. Anything outside is a bad read.
const float SENSOR_MIN_C = -70.0f;
const float SENSOR_MAX_C = 380.0f;

// ---------- Stability settings (all RELATIVE, none depend on the temperature) ----------
const int   RING_LEN       = 10;           // last 10 reads (~2 s) used to judge steadiness
const float STABLE_BAND_C  = 0.8f;         // reads in the last ~2 s must stay within this to start
const float JUMP_C         = 1.5f;         // a read this far from the recent median = spike
const int   JUMP_RESTART   = 5;            // this many spikes/bad reads in a row = target changed

const int   MAX_SAMPLES    = 64;
const int   MIN_SAMPLES    = 25;           // minimum good samples (of ~50) to trust a result
const float OUTLIER_C      = 1.0f;         // drop samples more than this from the window median
const float MAX_IQR_C      = 0.6f;         // spread limit (25th-75th percentile)

// ---------- Sensor state ----------
Adafruit_MLX90614 mlx;
bool mlxOk = false;

uint32_t lastSample = 0, lastInitTry = 0, lastDebug = 0;

float lastReading = NAN;     // latest raw reading, for debug only
int   rejectRun = 0;         // consecutive spikes / bad reads
int   nanRun = 0;            // consecutive failed reads (sensor trouble)

float ring[RING_LEN];        // most recent raw reads
int   ringCount = 0;
int   ringIndex = 0;

// ---------- Measurement state ----------
enum State { ST_WAIT, ST_SETTLE, ST_MEASURE, ST_DONE, ST_UNSTABLE };
const char *STATE_NAMES[] = { "WAIT", "SETTLE", "MEASURE", "DONE", "UNSTABLE" };

State    state = ST_WAIT;
uint32_t stateStart = 0;
uint32_t settleMs = SETTLE_MS;

float samples[MAX_SAMPLES];
int   sampleCount = 0;

float resultC = 0;           // final single result
bool  haveResult = false;

void sortFloats(float *a, int n) {
  for (int i = 1; i < n; i++) {
    float key = a[i];
    int j = i - 1;
    while (j >= 0 && a[j] > key) {
      a[j + 1] = a[j];
      j--;
    }
    a[j + 1] = key;
  }
}

void pushRing(float v) {
  ring[ringIndex] = v;
  ringIndex = (ringIndex + 1) % RING_LEN;
  if (ringCount < RING_LEN) ringCount++;
}

float ringMedian() {
  float tmp[RING_LEN];
  memcpy(tmp, ring, ringCount * sizeof(float));
  sortFloats(tmp, ringCount);
  return tmp[ringCount / 2];
}

float ringRange() {
  float lo = ring[0], hi = ring[0];
  for (int i = 1; i < ringCount; i++) {
    if (ring[i] < lo) lo = ring[i];
    if (ring[i] > hi) hi = ring[i];
  }
  return hi - lo;
}

bool targetSteady() {
  return ringCount >= RING_LEN && ringRange() <= STABLE_BAND_C;
}

// Median of the window after outlier rejection.
// Returns false if too few samples or the spread is too large.
bool summarize(const float *vals, int n, float *out) {
  if (n < MIN_SAMPLES) return false;

  float tmp[MAX_SAMPLES];
  memcpy(tmp, vals, n * sizeof(float));
  sortFloats(tmp, n);

  float med = tmp[n / 2];

  float kept[MAX_SAMPLES];   // stays sorted because tmp is sorted
  int k = 0;
  for (int i = 0; i < n; i++) {
    if (fabsf(tmp[i] - med) <= OUTLIER_C) kept[k++] = tmp[i];
  }

  if (k < MIN_SAMPLES || k < n / 2) return false;

  float iqr = kept[(3 * k) / 4] - kept[k / 4];
  if (iqr > MAX_IQR_C) return false;

  *out = kept[k / 2];
  return true;
}

void drawCard(int y, const char *label, uint16_t accent) {
  tft.fillRoundRect(3, y, 122, 47, 5, C_PANEL);
  tft.drawRoundRect(3, y, 122, 47, 5, C_BORDER);
  tft.drawFastVLine(8, y + 6, 7, accent);
  tft.setTextSize(1);
  tft.setTextColor(C_ICE, C_PANEL);
  tft.setCursor(13, y + 6);
  tft.print(label);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.drawPixel(69, 6, C_BORDER);
  tft.drawPixel(85, 4, C_VIOLET);
  tft.drawPixel(93, 10, C_BORDER);

  tft.setTextSize(1);
  tft.setTextColor(C_VIOLET, C_BG);
  tft.setCursor(5, 3);
  tft.print("THE NEXT");
  tft.setTextSize(2);
  tft.setTextColor(C_ICE, C_BG);
  tft.setCursor(4, 13);
  tft.print("FRONTIER");
  tft.drawFastHLine(4, 31, 120, C_BORDER);
  tft.drawFastHLine(4, 31, 24, C_CYAN);

  drawCard(35, "OBJECT TEMP", C_CYAN);
  tft.drawCircle(108, 62, 2, C_ICE);
  tft.setCursor(113, 63);
  tft.print("C");

  drawCard(83, "SENSOR AIM", C_VIOLET);
  tft.setTextColor(C_GREY, C_PANEL);
  tft.setCursor(13, 103);
  tft.print("Hold sensor 2-3 cm");
  tft.setCursor(13, 114);
  tft.print("from the object");
}

void drawTemp(const char *s, uint16_t color) {
  static char lastTxt[8] = "";
  static uint16_t lastColor = 0;
  if (!redrawPage && (strcmp(s, lastTxt) == 0 && color == lastColor)) return;   // nothing changed
  strncpy(lastTxt, s, sizeof(lastTxt) - 1);
  lastColor = color;
  tft.fillRect(10, 52, 96, 24, C_PANEL);
  tft.setTextSize(3);
  tft.setTextColor(color, C_PANEL);
  tft.setCursor(10, 52);
  tft.print(s);
}

void setState(State s) {
  state = s;
  stateStart = millis();
  rejectRun = 0;
  if (s == ST_MEASURE) sampleCount = 0;

  Serial.print("# STATE -> ");
  Serial.println(STATE_NAMES[s]);
}

void startNewMeasurement() {
  haveResult = false;
  settleMs = SETTLE_MS;
  setState(ST_SETTLE);
}

void finishMeasurement() {
  float result = 0;
  bool ok = summarize(samples, sampleCount, &result);

  Serial.print("# WINDOW samples: ");
  Serial.println(sampleCount);

  if (ok) {
    resultC = result;
    haveResult = true;
    Serial.print("# RESULT TEMP: ");
    Serial.println(result, 1);
    setState(ST_DONE);
  } else {
    Serial.println("# RESULT unstable, retrying");
    setState(ST_UNSTABLE);
  }
}

void updateState() {
  uint32_t now = millis();

  if (!mlxOk) {
    state = ST_WAIT;
    return;
  }

  // Target changed or lost (several spikes in a row) -> back to WAIT.
  // A finished result stays on screen until a new one replaces it.
  if (state != ST_WAIT && rejectRun >= JUMP_RESTART) {
    setState(ST_WAIT);
    return;
  }

  switch (state) {
    case ST_WAIT:
      if (targetSteady()) startNewMeasurement();
      break;

    case ST_SETTLE:
      if (now - stateStart >= settleMs) setState(ST_MEASURE);
      break;

    case ST_MEASURE:
      if (now - stateStart >= MEASURE_MS) finishMeasurement();
      break;

    case ST_UNSTABLE:
      if (now - stateStart >= UNSTABLE_SHOW_MS) {
        settleMs = RETRY_SETTLE_MS;
        setState(ST_SETTLE);
      }
      break;

    case ST_DONE:
    default:
      break;
  }
}

// ---------- Display update ----------
void updateDisplay() {
  uint32_t now = millis();

  // Only the final result is ever shown as a number.
  char buf[8];
  if (haveResult) snprintf(buf, sizeof(buf), "%4.1f", resultC);
  else strcpy(buf, "--.-");

  drawTemp(buf, haveResult ? C_GREEN : C_GREY);

  char txt[24];
  uint16_t color = C_GREY;
  int pct = 0;
  uint16_t barColor = C_CYAN;

  if (!mlxOk) {
    strcpy(txt, "NO SENSOR");
    color = C_RED;
  } else {
    uint32_t elapsed = now - stateStart;

    switch (state) {
      case ST_WAIT:
        if (haveResult) {
          strcpy(txt, "LAST READING");
          color = C_GREY;
        } else {
          strcpy(txt, "AIM & HOLD STILL");
          color = targetSteady() ? C_CYAN : C_GREY;
        }
        break;

      case ST_SETTLE: {
        uint32_t left = elapsed >= settleMs ? 0 : (settleMs - elapsed + 999) / 1000;
        snprintf(txt, sizeof(txt), "CALIBRATING %lus", (unsigned long)left);
        color = C_AMBER;
        pct = (int)(elapsed * 100 / settleMs);
        barColor = C_AMBER;
        break;
      }

      case ST_MEASURE: {
        uint32_t left = elapsed >= MEASURE_MS ? 0 : (MEASURE_MS - elapsed + 999) / 1000;
        snprintf(txt, sizeof(txt), "MEASURING %lus", (unsigned long)left);
        color = C_CYAN;
        pct = (int)(elapsed * 100 / MEASURE_MS);
        barColor = C_CYAN;
        break;
      }

      case ST_UNSTABLE:
        strcpy(txt, "HOLD STEADY");
        color = C_AMBER;
        break;

      case ST_DONE:
      default:
        strcpy(txt, "FINAL READING");
        color = C_GREEN;
        pct = 100;
        barColor = C_GREEN;
        break;
    }
  }

  drawMeasurementProgress(pct, barColor);
  drawMeasurementStatus(txt, color);
}

// ---------- MLX90614 ----------
bool initMlx() {
  return mlx.begin();   // default address 0x5A on the default Wire bus
}

void takeSample() {
  float t = (float)mlx.readObjectTempC();

  // Failed read (outside what the chip can physically report).
  if (isnan(t) || t < SENSOR_MIN_C || t > SENSOR_MAX_C) {
    lastReading = NAN;
    rejectRun++;

    if (++nanRun >= 25) {          // ~5 s of failed reads -> re-init the sensor
      mlxOk = false;
      nanRun = 0;
    }
    return;
  }

  nanRun = 0;
  lastReading = t;

  // Is this read a spike compared with the last ~2 s?
  bool spike = false;
  if (ringCount >= RING_LEN && fabsf(t - ringMedian()) > JUMP_C) spike = true;

  pushRing(t);

  if (spike) {
    rejectRun++;
  } else {
    rejectRun = 0;
    if (state == ST_MEASURE && sampleCount < MAX_SAMPLES) {
      samples[sampleCount++] = t;
    }
  }
}

void printDebug() {
  Serial.print("# OBJ: ");
  if (isnan(lastReading)) Serial.print("invalid");
  else Serial.print(lastReading, 2);
  Serial.print(" STATE: ");
  Serial.print(STATE_NAMES[state]);
  Serial.print(" range2s: ");
  if (ringCount >= RING_LEN) Serial.print(ringRange(), 2);
  else Serial.print("--");
  Serial.print(" samples: ");
  Serial.print(sampleCount);
  Serial.print(" reject_run: ");
  Serial.println(rejectRun);
}

void tick() {
  uint32_t now = millis();

  // Missing sensor: keep sending nulls and retry every 2 s.
  if (!mlxOk && now - lastInitTry > 2000) {
    lastInitTry = now;
    mlxOk = initMlx();
    if (mlxOk) {
      ringCount = ringIndex = 0;
      rejectRun = nanRun = 0;
      haveResult = false;
      setState(ST_WAIT);
    }
  }

  if (mlxOk && now - lastSample >= SAMPLE_INTERVAL) {
    lastSample = now;
    takeSample();
  }

  updateState();

  if (now - lastDebug >= 500) {
    lastDebug = now;
    printDebug();
  }

}
}  // namespace Skin

namespace Motion {
// ---------- Config ----------
const bool     DEBUG_MPU        = true;    // prints a "# mpu ..." line once per second
const uint32_t SAMPLE_INTERVAL  = 20;      // ms -> 50 samples/s

const float ACC_ALPHA      = 0.3f;    // smoothing for the displayed/JSON acceleration
const float BASE_ALPHA     = 0.02f;   // slow baseline (~1 s) used to detect motion
const float ACC_MOVE_G     = 0.04f;   // change in acceleration that counts as movement
const float GYRO_MOVE_DPS  = 5.0f;    // change in rotation rate that counts as movement
const uint32_t HOLD_MS     = 1500;    // stay "moving" this long after the last motion
const float IMPACT_G       = 2.5f;    // spike that counts as an impact / fall (demo value)
const uint32_t IMPACT_HOLD = 3000;    // ms to keep showing IMPACT
// Seconds of continuous stillness before time counts as sleep.
// 20 min is realistic; set to 20 for a quick demo.
const float SLEEP_AFTER_STILL_S = 20.0f * 60.0f;

const float G_MS2    = 9.80665f;
const float RAD2DEG  = 57.2957795f;

// ---------- Sensor state ----------
Adafruit_MPU6050 mpu;
bool mpuOk = false;
bool haveAccel = false;
int  badReads = 0;

float ax = 0, ay = 0, az = 0;     // g
float gx = 0, gy = 0, gz = 0;     // deg/s (raw, includes the sensor's small bias)
float accelG = 0;                 // smoothed acceleration magnitude, g
float gyroDyn = 0;                // rotation-rate change magnitude, deg/s (bias removed)

bool  baseInit = false;
float bax, bay, baz, bgx, bgy, bgz;   // slow baselines

bool     motionSeen = false;
uint32_t lastMotionMs = 0;
uint32_t impactUntil = 0;
bool     moving = false;

float moveS = 0;          // total seconds of movement
float stillRunS = 0;      // current continuous stillness, seconds
float sleepS = 0;         // total estimated sleep, seconds
bool  inSleepRun = false;

uint32_t lastSample = 0, lastInitTry = 0, lastDebug = 0;

enum Status { S_NO_SENSOR, S_IMPACT, S_MOVING, S_SLEEP, S_STILL };

struct Field { char txt[8]; uint16_t color; };
Field fAcc = {"", 0}, fGyro = {"", 0}, fMove = {"", 0}, fSleep = {"", 0};

void drawCard(int x, int y, int width, int height, const char *label, uint16_t accent) {
  tft.fillRoundRect(x, y, width, height, 5, C_PANEL);
  tft.drawRoundRect(x, y, width, height, 5, C_BORDER);
  if (width > 59) tft.drawFastVLine(x + 5, y + 5, 7, accent);
  tft.setTextSize(1);
  tft.setTextColor(C_ICE, C_PANEL);
  tft.setCursor(x + (width > 59 ? 10 : 3), y + 5);
  tft.print(label);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.drawPixel(69, 6, C_BORDER);
  tft.drawPixel(85, 4, C_VIOLET);
  tft.drawPixel(93, 10, C_BORDER);

  tft.setTextSize(1);
  tft.setTextColor(C_VIOLET, C_BG);
  tft.setCursor(5, 3);
  tft.print("THE NEXT");
  tft.setTextSize(2);
  tft.setTextColor(C_ICE, C_BG);
  tft.setCursor(4, 13);
  tft.print("FRONTIER");
  tft.drawFastHLine(4, 31, 120, C_BORDER);
  tft.drawFastHLine(4, 31, 24, C_CYAN);

  drawCard(3, 35, 122, 41, "ACCELERATION", C_CYAN);
  tft.setCursor(104, 61);
  tft.print("g");

  drawCard(3, 79, 122, 28, "ROTATION", C_VIOLET);
  tft.setCursor(56, 94);
  tft.print("deg/s");

  drawCard(3, 110, 59, 23, "MOVE min", C_GREEN);
  drawCard(66, 110, 59, 23, "SLEEP min", C_CYAN);
}

void drawField(Field &f, int x, int y, int size, const char *s, uint16_t color) {
  if (!redrawPage && (strcmp(s, f.txt) == 0 && color == f.color)) return;   // nothing changed
  strncpy(f.txt, s, sizeof(f.txt) - 1);
  f.txt[sizeof(f.txt) - 1] = 0;
  f.color = color;
  tft.setTextSize(size);
  tft.setTextColor(color, C_PANEL);
  tft.setCursor(x, y);
  tft.print(s);
}

void drawStatus(Status s) {
  static int last = -1;
  if (!redrawPage && (int)s == last) return;
  last = s;

  const char *txt;
  uint16_t col;
  switch (s) {
    case S_NO_SENSOR: txt = "NO SENSOR"; col = C_RED;   break;
    case S_IMPACT:    txt = "IMPACT";    col = C_RED;   break;
    case S_MOVING:    txt = "MOVING";    col = C_GREEN; break;
    case S_SLEEP:     txt = "SLEEPING";  col = C_VIOLET; break;
    default:          txt = "STILL";     col = C_CYAN;  break;
  }
  tft.fillRoundRect(3, 137, 122, 20, 5, C_PANEL);
  tft.drawRoundRect(3, 137, 122, 20, 5, col);
  tft.fillCircle(16, 147, 2, col);
  tft.setTextSize(1);
  tft.setTextColor(col, C_PANEL);
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 143);
  tft.print(txt);
}

void updateDisplay() {
  bool ok = mpuOk && haveAccel;
  char buf[8];

  if (ok) snprintf(buf, sizeof(buf), "%5.2f", fminf(accelG, 99.99f)); else strcpy(buf, "--.--");
  drawField(fAcc, 10, 50, 3, buf, ok ? C_ICE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%3d", (int)fminf(gyroDyn, 999.0f)); else strcpy(buf, "---");
  drawField(fGyro, 10, 90, 2, buf, ok ? C_ICE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%5.1f", fminf(moveS / 60.0f, 999.9f)); else strcpy(buf, " --.-");
  drawField(fMove, 12, 123, 1, buf, ok ? C_GREEN : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%5.1f", fminf(sleepS / 60.0f, 999.9f)); else strcpy(buf, " --.-");
  drawField(fSleep, 75, 123, 1, buf, ok ? C_CYAN : C_GREY);

  Status s;
  if (!mpuOk || !haveAccel)         s = S_NO_SENSOR;
  else if (millis() < impactUntil)  s = S_IMPACT;
  else if (moving)                  s = S_MOVING;
  else if (inSleepRun)              s = S_SLEEP;
  else                              s = S_STILL;
  drawStatus(s);
}

// ---------- MPU6050 ----------
bool initMpu() {
  if (!mpu.begin(0x68, &Wire)) return false;   // GY-521 default address (AD0 low)
  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  baseInit = false;
  lastSample = millis();
  return true;
}

void readMpu(uint32_t now) {
  sensors_event_t a, g, t;
  mpu.getEvent(&a, &g, &t);

  ax = a.acceleration.x / G_MS2;
  ay = a.acceleration.y / G_MS2;
  az = a.acceleration.z / G_MS2;
  gx = g.gyro.x * RAD2DEG;
  gy = g.gyro.y * RAD2DEG;
  gz = g.gyro.z * RAD2DEG;

  // A failed I2C read comes back as NaN or exactly 0,0,0.
  bool good = !isnan(ax) && !isnan(ay) && !isnan(az) && !(ax == 0 && ay == 0 && az == 0);
  if (!good) {
    if (++badReads >= 3) { haveAccel = false; baseInit = false; }
    return;
  }
  badReads = 0;
  haveAccel = true;

  float mag = sqrtf(ax * ax + ay * ay + az * az);
  if (!baseInit) {
    bax = ax; bay = ay; baz = az;
    bgx = gx; bgy = gy; bgz = gz;
    accelG = mag;
    baseInit = true;
  }

  // Motion = how far the current reading is from its own slow baseline.
  // This works at 1 g on Earth and ~0 g in orbit, and ignores the gyro's constant bias.
  float dAcc = sqrtf(sq(ax - bax) + sq(ay - bay) + sq(az - baz));
  float dGyr = sqrtf(sq(gx - bgx) + sq(gy - bgy) + sq(gz - bgz));
  bax += BASE_ALPHA * (ax - bax);
  bay += BASE_ALPHA * (ay - bay);
  baz += BASE_ALPHA * (az - baz);
  bgx += BASE_ALPHA * (gx - bgx);
  bgy += BASE_ALPHA * (gy - bgy);
  bgz += BASE_ALPHA * (gz - bgz);

  accelG  = accelG * (1.0f - ACC_ALPHA) + mag * ACC_ALPHA;
  gyroDyn = dGyr;

  if (dAcc > ACC_MOVE_G || dGyr > GYRO_MOVE_DPS) {
    lastMotionMs = now;
    motionSeen = true;
  }
  if (mag > IMPACT_G) impactUntil = now + IMPACT_HOLD;
}

void updateActivity(uint32_t now, uint32_t dtMs) {
  float dt = dtMs / 1000.0f;
  moving = motionSeen && (now - lastMotionMs) < HOLD_MS;

  if (moving) {
    moveS += dt;
    stillRunS = 0;
    inSleepRun = false;
  } else {
    stillRunS += dt;
    if (stillRunS >= SLEEP_AFTER_STILL_S) {
      if (!inSleepRun) { sleepS += stillRunS; inSleepRun = true; }   // count the whole still run
      else             { sleepS += dt; }
    }
  }
}

void printDebug() {
  Serial.print("# mpu ax="); Serial.print(ax, 2);
  Serial.print(" ay=");       Serial.print(ay, 2);
  Serial.print(" az=");       Serial.print(az, 2);
  Serial.print(" g | gx=");   Serial.print(gx, 1);
  Serial.print(" gy=");       Serial.print(gy, 1);
  Serial.print(" gz=");       Serial.print(gz, 1);
  Serial.print(" dps | move_min="); Serial.print(moveS / 60.0f, 2);
  Serial.print(" still_min=");      Serial.print(stillRunS / 60.0f, 2);
  Serial.print(" sleep_min=");      Serial.println(sleepS / 60.0f, 2);
}

void tick() {
  uint32_t now = millis();

  // Missing sensor: keep sending nulls and retry every 2 s.
  if (!mpuOk && now - lastInitTry > 2000) {
    lastInitTry = now;
    mpuOk = initMpu();
  }

  if (mpuOk && now - lastSample >= SAMPLE_INTERVAL) {
    uint32_t dt = now - lastSample;
    lastSample = now;
    if (dt > 200) dt = 200;              // guard against long stalls
    readMpu(now);
    if (haveAccel) updateActivity(now, dt);
  }

  if (DEBUG_MPU && haveAccel && now - lastDebug >= 1000) {
    lastDebug = now;
    printDebug();
  }
}
}  // namespace Motion

namespace Cabin {
// ---------- Config ----------
const bool     DEBUG_BME          = true;     // prints a "# bme ..." line once per second
const uint32_t POLL_INTERVAL      = 500;      // ms -> sensor reads
const uint32_t STALE_MS           = 5000;     // no good reading this long -> re-init the sensor
const float    EARTH_SEA_LEVEL    = 1013.25f; // hPa, for the "% of Earth" readout
const float    DROP_ALERT_HPA_MIN = -1.0f;    // pressure falling faster than this = possible leak (demo value)

// ---------- BME280 / BMP280 registers ----------
const uint8_t REG_ID        = 0xD0;
const uint8_t REG_RESET     = 0xE0;
const uint8_t REG_CTRL_HUM  = 0xF2;
const uint8_t REG_STATUS    = 0xF3;
const uint8_t REG_CTRL_MEAS = 0xF4;
const uint8_t REG_CONFIG    = 0xF5;
const uint8_t REG_DATA      = 0xF7;

uint8_t bmeAddr = 0x76;
uint8_t bmeId   = 0;
bool    hasHum  = false;          // true = BME280, false = BMP280 (no humidity)

bool     bmeOk = false;
bool     everRead = false;
bool     haveData = false;
uint32_t lastGoodMs = 0;
float    pHpa = 0, tempC = 0, rh = 0;

// Calibration constants stored inside the chip
uint16_t digT1; int16_t digT2, digT3;
uint16_t digP1; int16_t digP2, digP3, digP4, digP5, digP6, digP7, digP8, digP9;
uint8_t  digH1, digH3; int16_t digH2, digH4, digH5; int8_t digH6;
int32_t  tFine;

// ---------- Pressure trend (for leak detection) ----------
const int TREND_N = 13;           // 12 intervals x 5 s = 60 s of history
float    trendBuf[TREND_N];
int      trendCount = 0;
uint32_t lastTrendMs = 0;
float    trendHpaMin = 0;
bool     haveTrend = false;

uint32_t lastPoll = 0, lastInitTry = 0, lastDebug = 0;

enum Status { S_NO_SENSOR, S_NO_DATA, S_DROP, S_NOMINAL, S_CAUTION, S_ALERT };

struct Field { char txt[8]; uint16_t color; };
Field fP = {"", 0}, fTemp = {"", 0}, fHum = {"", 0}, fEarth = {"", 0}, fTrend = {"", 0};

// 0 = ok, 1 = caution, 2 = alert. Demo thresholds, not medical limits.
int pressureLevel(float p) {
  if (p >= 980.0f && p <= 1040.0f) return 0;
  if ((p >= 900.0f && p < 980.0f) || (p > 1040.0f && p <= 1060.0f)) return 1;
  return 2;
}
void drawCard(int x, int y, int width, int height, const char *label) {
  tft.fillRoundRect(x, y, width, height, 5, C_PANEL);
  tft.drawRoundRect(x, y, width, height, 5, C_BORDER);
  tft.setTextSize(1);
  tft.setTextColor(C_ICE, C_PANEL);
  tft.setCursor(x + 5, y + 4);
  tft.print(label);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.drawPixel(69, 6, C_BORDER);
  tft.drawPixel(85, 4, C_VIOLET);
  tft.drawPixel(93, 10, C_BORDER);

  tft.setTextSize(1);
  tft.setTextColor(C_VIOLET, C_BG);
  tft.setCursor(5, 3);
  tft.print("THE NEXT");
  tft.setTextSize(2);
  tft.setTextColor(C_ICE, C_BG);
  tft.setCursor(4, 13);
  tft.print("FRONTIER");
  tft.drawFastHLine(4, 31, 120, C_BORDER);
  tft.drawFastHLine(4, 31, 24, C_CYAN);

  drawCard(3, 35, 122, 37, "PRESSURE");
  tft.setCursor(101, 40);
  tft.print("hPa");

  drawCard(3, 74, 66, 25, "TEMP");
  tft.drawCircle(35, 88, 1, C_ICE);
  tft.setCursor(38, 87);
  tft.print("C");
  drawCard(71, 74, 54, 25, "HUMIDITY");
  tft.setCursor(95, 87);
  tft.print("%");

  drawCard(3, 101, 66, 25, "% OF EARTH");
  tft.setCursor(27, 114);
  tft.print("%");
  drawCard(71, 101, 54, 25, "hPa/min");
}

void drawField(Field &f, int x, int y, int size, const char *s, uint16_t color) {
  if (!redrawPage && (strcmp(s, f.txt) == 0 && color == f.color)) return;   // nothing changed
  // Clear the previous value if its formatted width changes.
  if (strlen(s) != strlen(f.txt)) {
    tft.fillRect(x, y, strlen(f.txt) * 6 * size, 8 * size, C_PANEL);
  }
  strncpy(f.txt, s, sizeof(f.txt) - 1);
  f.txt[sizeof(f.txt) - 1] = 0;
  f.color = color;
  tft.setTextSize(size);
  tft.setTextColor(color, C_PANEL);
  tft.setCursor(x, y);
  tft.print(s);
}

void drawHint(const char *s, uint16_t color) {
  static char last[24] = "~";
  static uint16_t lastCol = 0;
  if (!redrawPage && (strcmp(s, last) == 0 && color == lastCol)) return;
  strncpy(last, s, sizeof(last) - 1);
  last[sizeof(last) - 1] = 0;
  lastCol = color;
  tft.fillRect(0, 127, 128, 8, C_BG);
  tft.setTextSize(1);
  tft.setTextColor(color, C_BG);
  tft.setCursor(1, 127);
  tft.print(s);
}

void drawStatus(Status s) {
  static int last = -1;
  if (!redrawPage && (int)s == last) return;
  last = s;

  const char *txt;
  uint16_t col;
  switch (s) {
    case S_NO_SENSOR: txt = "NO SENSOR";  col = C_RED;    break;
    case S_NO_DATA:   txt = "NO DATA";    col = C_GREY;        break;
    case S_DROP:      txt = "PRESS DROP"; col = C_RED;    break;
    case S_NOMINAL:   txt = "NOMINAL";    col = C_GREEN;  break;
    case S_CAUTION:   txt = "CAUTION";    col = C_AMBER; break;
    default:          txt = "ALERT";      col = C_RED;    break;
  }
  tft.fillRoundRect(3, 137, 122, 20, 5, C_PANEL);
  tft.drawRoundRect(3, 137, 122, 20, 5, col);
  tft.fillCircle(16, 147, 2, col);
  tft.setTextSize(1);
  tft.setTextColor(col, C_PANEL);
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 143);
  tft.print(txt);
}

void updateDisplay() {
  bool ok = bmeOk && haveData;
  bool leak = ok && haveTrend && trendHpaMin <= DROP_ALERT_HPA_MIN;
  int lvl = ok ? pressureLevel(pHpa) : -1;
  uint16_t pCol = !ok ? C_GREY : (leak ? C_RED : levelColor(lvl));
  char buf[10];

  if (ok) snprintf(buf, sizeof(buf), "%6.1f", pHpa); else strcpy(buf, "----.-");
  drawField(fP, 8, 47, 2, buf, pCol);

  if (ok) snprintf(buf, sizeof(buf), "%4.1f", constrain(tempC, -9.9f, 99.9f)); else strcpy(buf, "--.-");
  drawField(fTemp, 8, 87, 1, buf, ok ? C_ICE : C_GREY);

  bool humOk = ok && hasHum;
  if (humOk) snprintf(buf, sizeof(buf), "%3d", constrain((int)(rh + 0.5f), 0, 100)); else strcpy(buf, "---");
  drawField(fHum, 76, 87, 1, buf, humOk ? C_ICE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%3d", constrain((int)(pHpa / EARTH_SEA_LEVEL * 100.0f + 0.5f), 0, 999));
  else    strcpy(buf, "---");
  drawField(fEarth, 8, 114, 1, buf, ok ? C_ICE : C_GREY);

  if (ok && haveTrend) {
    float tr = constrain(trendHpaMin, -9.9f, 9.9f);
    if (fabsf(tr) < 0.05f) tr = 0.0f;               // avoid "-0.0"
    snprintf(buf, sizeof(buf), "%+.1f", tr);
  } else {
    strcpy(buf, "--.-");
  }
  drawField(fTrend, 76, 114, 1, buf, (ok && haveTrend) ? (leak ? C_RED : C_ICE) : C_GREY);

  if (!ok)                 drawHint("", C_GREY);
  else if (leak)           drawHint("Possible cabin leak!", C_RED);
  else if (lvl == 1)       drawHint("Pressure off nominal", C_AMBER);
  else if (lvl == 2)       drawHint("Outside cabin range", C_RED);
  else if (!hasHum)        drawHint("Normal | BMP280 no RH", C_GREEN);
  else                     drawHint("Cabin pressure normal", C_GREEN);

  Status s;
  if (!bmeOk)         s = S_NO_SENSOR;
  else if (!haveData) s = S_NO_DATA;
  else if (leak)      s = S_DROP;
  else                s = (lvl == 0) ? S_NOMINAL : (lvl == 1 ? S_CAUTION : S_ALERT);
  drawStatus(s);
}

// ---------- BME280 low-level ----------
bool bmeRead(uint8_t reg, uint8_t *buf, int n) {
  Wire.beginTransmission(bmeAddr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;   // repeated start
  if (Wire.requestFrom((int)bmeAddr, n) != n) return false;
  for (int i = 0; i < n; i++) buf[i] = Wire.read();
  return true;
}

bool bmeWrite8(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(bmeAddr);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

bool bmeLoadCalib() {
  uint8_t c[26];
  if (!bmeRead(0x88, c, 26)) return false;
  digT1 = (uint16_t)((c[1] << 8) | c[0]);
  digT2 = (int16_t)((c[3] << 8) | c[2]);
  digT3 = (int16_t)((c[5] << 8) | c[4]);
  digP1 = (uint16_t)((c[7] << 8) | c[6]);
  digP2 = (int16_t)((c[9] << 8) | c[8]);
  digP3 = (int16_t)((c[11] << 8) | c[10]);
  digP4 = (int16_t)((c[13] << 8) | c[12]);
  digP5 = (int16_t)((c[15] << 8) | c[14]);
  digP6 = (int16_t)((c[17] << 8) | c[16]);
  digP7 = (int16_t)((c[19] << 8) | c[18]);
  digP8 = (int16_t)((c[21] << 8) | c[20]);
  digP9 = (int16_t)((c[23] << 8) | c[22]);
  digH1 = c[25];                                     // register 0xA1
  if (hasHum) {
    uint8_t h[7];
    if (!bmeRead(0xE1, h, 7)) return false;
    digH2 = (int16_t)((h[1] << 8) | h[0]);
    digH3 = h[2];
    digH4 = (int16_t)(((int8_t)h[3] << 4) | (h[4] & 0x0F));
    digH5 = (int16_t)(((int8_t)h[5] << 4) | (h[4] >> 4));
    digH6 = (int8_t)h[6];
  }
  return true;
}

// Bosch compensation formulas (integer versions from the datasheet).
int32_t compT(int32_t adcT) {                        // returns 0.01 degC
  int32_t var1 = ((((adcT >> 3) - ((int32_t)digT1 << 1))) * ((int32_t)digT2)) >> 11;
  int32_t var2 = (((((adcT >> 4) - ((int32_t)digT1)) * ((adcT >> 4) - ((int32_t)digT1))) >> 12) * ((int32_t)digT3)) >> 14;
  tFine = var1 + var2;
  return (tFine * 5 + 128) >> 8;
}

uint32_t compP(int32_t adcP) {                       // returns Pa in Q24.8 (divide by 256)
  int64_t var1 = ((int64_t)tFine) - 128000;
  int64_t var2 = var1 * var1 * (int64_t)digP6;
  var2 = var2 + ((var1 * (int64_t)digP5) << 17);
  var2 = var2 + (((int64_t)digP4) << 35);
  var1 = ((var1 * var1 * (int64_t)digP3) >> 8) + ((var1 * (int64_t)digP2) << 12);
  var1 = (((((int64_t)1) << 47) + var1)) * ((int64_t)digP1) >> 33;
  if (var1 == 0) return 0;
  int64_t p = 1048576 - adcP;
  p = (((p << 31) - var2) * 3125) / var1;
  var1 = (((int64_t)digP9) * (p >> 13) * (p >> 13)) >> 25;
  var2 = (((int64_t)digP8) * p) >> 19;
  p = ((p + var1 + var2) >> 8) + (((int64_t)digP7) << 4);
  return (uint32_t)p;
}

uint32_t compH(int32_t adcH) {                       // returns %RH in Q22.10 (divide by 1024)
  int32_t v = tFine - 76800;
  v = (((((adcH << 14) - (((int32_t)digH4) << 20) - (((int32_t)digH5) * v)) + 16384) >> 15) *
       (((((((v * (int32_t)digH6) >> 10) * (((v * (int32_t)digH3) >> 11) + 32768)) >> 10) + 2097152) *
         (int32_t)digH2 + 8192) >> 14));
  v = v - (((((v >> 15) * (v >> 15)) >> 7) * (int32_t)digH1) >> 4);
  v = v < 0 ? 0 : v;
  v = v > 419430400 ? 419430400 : v;
  return (uint32_t)(v >> 12);
}

bool initBme() {
  const uint8_t addrs[2] = {0x76, 0x77};             // 0x77 if the SDO pin is tied high
  for (int i = 0; i < 2; i++) {
    bmeAddr = addrs[i];
    uint8_t id;
    if (!bmeRead(REG_ID, &id, 1)) continue;          // nothing at this address
    if (id == 0x60)                                  hasHum = true;    // BME280
    else if (id == 0x58 || id == 0x56 || id == 0x57) hasHum = false;   // BMP280 (no humidity)
    else continue;
    bmeId = id;

    bmeWrite8(REG_RESET, 0xB6);                      // soft reset
    delay(10);
    for (int k = 0; k < 20; k++) {                   // wait for calibration copy to finish
      uint8_t st;
      if (bmeRead(REG_STATUS, &st, 1) && !(st & 0x01)) break;
      delay(5);
    }
    if (!bmeLoadCalib()) continue;

    if (hasHum) bmeWrite8(REG_CTRL_HUM, 0x01);       // humidity x1 (must be written before ctrl_meas)
    bmeWrite8(REG_CONFIG, 0x88);                     // 500 ms standby, IIR filter x4
    bmeWrite8(REG_CTRL_MEAS, 0x4F);                  // temp x2, pressure x4, normal mode

    everRead = false;
    haveData = false;
    lastGoodMs = millis();
    return true;
  }
  return false;
}

bool readBme() {
  uint8_t d[8];
  if (!bmeRead(REG_DATA, d, hasHum ? 8 : 6)) return false;
  int32_t adcP = ((int32_t)d[0] << 12) | ((int32_t)d[1] << 4) | (d[2] >> 4);
  int32_t adcT = ((int32_t)d[3] << 12) | ((int32_t)d[4] << 4) | (d[5] >> 4);
  if (adcP == 0x80000 || adcT == 0x80000) return false;   // no measurement yet

  float t = compT(adcT) / 100.0f;                    // must run first: sets tFine
  float p = compP(adcP) / 25600.0f;                  // Q24.8 Pa -> hPa
  float h = 0;
  if (hasHum) {
    int32_t adcH = ((int32_t)d[6] << 8) | d[7];
    if (adcH == 0x8000) return false;
    h = compH(adcH) / 1024.0f;
  }
  if (t < -40.0f || t > 85.0f || p < 300.0f || p > 1100.0f) return false;   // out of sensor range

  tempC = t; pHpa = p; rh = h;
  return true;
}

void updateTrend(uint32_t now) {
  if (now - lastTrendMs < 5000) return;              // one sample every 5 s
  lastTrendMs = now;
  if (trendCount < TREND_N) {
    trendBuf[trendCount++] = pHpa;
  } else {
    memmove(trendBuf, trendBuf + 1, (TREND_N - 1) * sizeof(float));
    trendBuf[TREND_N - 1] = pHpa;
  }
  if (trendCount >= 7) {                             // need at least 30 s of history
    float minutes = (trendCount - 1) * 5.0f / 60.0f;
    trendHpaMin = (trendBuf[trendCount - 1] - trendBuf[0]) / minutes;
    haveTrend = true;
  }
}

void pollBme(uint32_t now) {
  if (readBme()) {
    lastGoodMs = now;
    everRead = true;
  }
  if (now - lastGoodMs >= STALE_MS) {                // sensor stopped answering -> re-init
    bmeOk = false;
    everRead = false;
  }
  haveData = bmeOk && everRead;
  if (haveData) {
    updateTrend(now);
  } else {
    trendCount = 0;
    haveTrend = false;
  }
}

void printDebug() {
  Serial.print("# bme chip=");
  Serial.print(hasHum ? "BME280" : "BMP280 (no humidity)");
  Serial.print(" addr=0x"); Serial.print(bmeAddr, HEX);
  Serial.print(" p=");      Serial.print(pHpa, 2);
  Serial.print(" hPa t=");  Serial.print(tempC, 2);
  Serial.print(" C rh=");   Serial.print(rh, 1);
  Serial.print(" % trend=");
  if (haveTrend) Serial.print(trendHpaMin, 2); else Serial.print("--");
  Serial.println(" hPa/min");
}

void tick() {
  uint32_t now = millis();

  // Missing sensor: keep sending nulls and retry every 2 s.
  if (!bmeOk && now - lastInitTry > 2000) {
    lastInitTry = now;
    bmeOk = initBme();
  }

  if (bmeOk && now - lastPoll >= POLL_INTERVAL) {
    lastPoll = now;
    pollBme(now);
  }

  if (DEBUG_BME && bmeOk && haveData && now - lastDebug >= 1000) {
    lastDebug = now;
    printDebug();
  }
}
}  // namespace Cabin

namespace Air {
// ---------- Config ----------
const bool     DEBUG_SCD        = true;    // prints a "# scd ..." line for each new reading
const uint32_t POLL_INTERVAL    = 500;     // ms -> check for new data (sensor makes one every 5 s)
const uint32_t STALE_MS         = 15000;   // no good reading for this long -> null
const uint16_t CAL_TARGET_PPM   = 420;     // fresh outdoor air, used by the 'c' calibration command

// ---------- SCD41 ----------
const uint8_t SCD_ADDR = 0x62;
const uint16_t CMD_START_PERIODIC = 0x21B1;
const uint16_t CMD_STOP_PERIODIC  = 0x3F86;
const uint16_t CMD_DATA_READY     = 0xE4B8;
const uint16_t CMD_READ_MEAS      = 0xEC05;
const uint16_t CMD_FORCED_RECAL   = 0x362F;

bool     scdOk = false;
bool     everRead = false;
bool     haveData = false;
uint32_t lastGoodMs = 0;
float    co2ppm = 0, tempC = 0, rh = 0;

uint32_t lastPoll = 0, lastInitTry = 0;

enum Status { S_NO_SENSOR, S_WARMING, S_NO_DATA, S_CAL, S_NOMINAL, S_CAUTION, S_ALERT };

struct Field { char txt[8]; uint16_t color; };
Field fCo2 = {"", 0}, fTemp = {"", 0}, fHum = {"", 0};

// 0 = ok, 1 = caution, 2 = alert. Demo thresholds, not medical limits.
int co2Level(int ppm) {
  if (ppm < 1000)  return 0;
  if (ppm <= 2000) return 1;
  return 2;
}
void drawCard(int x, int y, int width, int height, const char *label, int labelInset) {
  tft.fillRoundRect(x, y, width, height, 5, C_PANEL);
  tft.drawRoundRect(x, y, width, height, 5, C_BORDER);
  tft.setTextSize(1);
  tft.setTextColor(C_ICE, C_PANEL);
  tft.setCursor(x + labelInset, y + 4);
  tft.print(label);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.drawPixel(69, 6, C_BORDER);
  tft.drawPixel(85, 4, C_VIOLET);
  tft.drawPixel(93, 10, C_BORDER);

  tft.setTextSize(1);
  tft.setTextColor(C_VIOLET, C_BG);
  tft.setCursor(5, 3);
  tft.print("THE NEXT");
  tft.setTextSize(2);
  tft.setTextColor(C_ICE, C_BG);
  tft.setCursor(4, 13);
  tft.print("FRONTIER");
  tft.drawFastHLine(4, 31, 120, C_BORDER);
  tft.drawFastHLine(4, 31, 24, C_CYAN);

  drawCard(3, 35, 122, 51, "CARBON DIOXIDE", 11);
  tft.drawFastVLine(8, 39, 7, C_CYAN);
  tft.setCursor(96, 64);
  tft.print("ppm");
  tft.drawRect(4, 74, 120, 8, C_BORDER);

  drawCard(3, 89, 66, 31, "TEMP", 5);
  tft.drawCircle(59, 104, 1, C_ICE);
  tft.setCursor(62, 103);
  tft.print("C");

  drawCard(71, 89, 54, 31, "HUMIDITY", 5);
  tft.setCursor(115, 103);
  tft.print("%");
}

void drawField(Field &f, int x, int y, int size, const char *s, uint16_t color) {
  if (!redrawPage && (strcmp(s, f.txt) == 0 && color == f.color)) return;   // nothing changed
  strncpy(f.txt, s, sizeof(f.txt) - 1);
  f.txt[sizeof(f.txt) - 1] = 0;
  f.color = color;
  tft.setTextSize(size);
  tft.setTextColor(color, C_PANEL);
  tft.setCursor(x, y);
  tft.print(s);
}

// Bar fills from 400 ppm (fresh air) to 3000 ppm.
void drawBar(bool ok, int ppm, uint16_t color) {
  static int lastW = -1;
  static uint16_t lastCol = 0;
  int w = ok ? constrain((ppm - 400) * 118 / 2600, 0, 118) : 0;
  if (!redrawPage && (w == lastW && color == lastCol)) return;
  lastW = w;
  lastCol = color;
  if (w > 0)   tft.fillRect(5, 75, w, 6, color);
  if (w < 118) tft.fillRect(5 + w, 75, 118 - w, 6, C_PANEL);
}

void drawHint(const char *s, uint16_t color) {
  static char last[24] = "~";
  static uint16_t lastCol = 0;
  if (!redrawPage && (strcmp(s, last) == 0 && color == lastCol)) return;
  strncpy(last, s, sizeof(last) - 1);
  last[sizeof(last) - 1] = 0;
  lastCol = color;
  tft.fillRect(0, 127, 128, 8, C_BG);
  tft.setTextSize(1);
  tft.setTextColor(color, C_BG);
  tft.setCursor(1, 127);
  tft.print(s);
}

void drawStatus(Status s) {
  static int last = -1;
  if (!redrawPage && (int)s == last) return;
  last = s;

  const char *txt;
  uint16_t col;
  switch (s) {
    case S_NO_SENSOR: txt = "NO SENSOR"; col = C_RED;    break;
    case S_WARMING:   txt = "WARMING UP"; col = C_CYAN;  break;
    case S_NO_DATA:   txt = "NO DATA";   col = C_GREY;        break;
    case S_CAL:       txt = "CALIBRATE"; col = C_CYAN;   break;
    case S_NOMINAL:   txt = "NOMINAL";   col = C_GREEN;  break;
    case S_CAUTION:   txt = "CAUTION";   col = C_AMBER; break;
    default:          txt = "ALERT";     col = C_RED;    break;
  }
  tft.fillRoundRect(3, 137, 122, 20, 5, C_PANEL);
  tft.drawRoundRect(3, 137, 122, 20, 5, col);
  tft.fillCircle(16, 147, 2, col);
  tft.setTextSize(1);
  tft.setTextColor(col, C_PANEL);
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 143);
  tft.print(txt);
}

void updateDisplay() {
  bool ok = scdOk && haveData;
  char buf[8];
  int lvl = -1;
  uint16_t col = C_GREY;

  if (ok) {
    int ppm = (int)(co2ppm + 0.5f);
    lvl = co2Level(ppm);
    col = levelColor(lvl);
    snprintf(buf, sizeof(buf), "%4d", min(ppm, 9999));
  } else {
    strcpy(buf, "----");
  }
  drawField(fCo2, 10, 48, 3, buf, col);
  drawBar(ok, (int)co2ppm, col);

  if (ok) snprintf(buf, sizeof(buf), "%4.1f", constrain(tempC, -9.9f, 99.9f));
  else    strcpy(buf, "--.-");
  drawField(fTemp, 8, 101, 2, buf, ok ? C_ICE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%3d", constrain((int)(rh + 0.5f), 0, 100));
  else    strcpy(buf, "---");
  drawField(fHum, 76, 101, 2, buf, ok ? C_ICE : C_GREY);

  if (!ok)            drawHint("", C_GREY);
  else if (lvl == 0)  drawHint("Air is fresh", C_GREEN);
  else if (lvl == 1)  drawHint("Stuffy: focus may dip", C_AMBER);
  else                drawHint("Headache risk: vent!", C_RED);

  Status s;
  if (!scdOk)         s = S_NO_SENSOR;
  else if (!haveData) s = everRead ? S_NO_DATA : S_WARMING;
  else                s = (lvl == 0) ? S_NOMINAL : (lvl == 1 ? S_CAUTION : S_ALERT);
  drawStatus(s);
}

// ---------- SCD41 low-level (Sensirion protocol: 16-bit commands, CRC-8 on every data word) ----------
uint8_t crc8(const uint8_t *d, int n) {
  uint8_t crc = 0xFF;
  for (int i = 0; i < n; i++) {
    crc ^= d[i];
    for (int b = 0; b < 8; b++) crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x31) : (uint8_t)(crc << 1);
  }
  return crc;
}

bool scdCmd(uint16_t cmd) {
  Wire.beginTransmission(SCD_ADDR);
  Wire.write((uint8_t)(cmd >> 8));
  Wire.write((uint8_t)(cmd & 0xFF));
  return Wire.endTransmission() == 0;
}

bool scdCmdArg(uint16_t cmd, uint16_t arg) {
  uint8_t b[2] = { (uint8_t)(arg >> 8), (uint8_t)(arg & 0xFF) };
  Wire.beginTransmission(SCD_ADDR);
  Wire.write((uint8_t)(cmd >> 8));
  Wire.write((uint8_t)(cmd & 0xFF));
  Wire.write(b, 2);
  Wire.write(crc8(b, 2));
  return Wire.endTransmission() == 0;
}

// Reads n bytes (multiple of 3: word, word, CRC) and checks every CRC.
bool scdRead(uint8_t *buf, int n) {
  if (Wire.requestFrom((int)SCD_ADDR, n) != n) return false;
  for (int i = 0; i < n; i++) buf[i] = Wire.read();
  for (int i = 0; i < n; i += 3) {
    if (crc8(buf + i, 2) != buf[i + 2]) return false;
  }
  return true;
}

bool scdDataReady() {
  if (!scdCmd(CMD_DATA_READY)) return false;
  delay(1);
  uint8_t b[3];
  if (!scdRead(b, 3)) return false;
  uint16_t w = ((uint16_t)b[0] << 8) | b[1];
  return (w & 0x07FF) != 0;
}

bool scdReadMeasurement(float &co2, float &t, float &h) {
  if (!scdCmd(CMD_READ_MEAS)) return false;
  delay(1);
  uint8_t b[9];
  if (!scdRead(b, 9)) return false;
  uint16_t rawCo2 = ((uint16_t)b[0] << 8) | b[1];
  uint16_t rawT   = ((uint16_t)b[3] << 8) | b[4];
  uint16_t rawRh  = ((uint16_t)b[6] << 8) | b[7];
  co2 = rawCo2;
  t   = -45.0f + 175.0f * rawT / 65535.0f;
  h   = 100.0f * rawRh / 65535.0f;
  return true;
}

bool initScd() {
  Wire.beginTransmission(SCD_ADDR);
  if (Wire.endTransmission() != 0) return false;     // not on the bus
  scdCmd(CMD_STOP_PERIODIC);                         // in case it kept measuring through an ESP32 reset
  delay(500);
  if (!scdCmd(CMD_START_PERIODIC)) return false;     // new reading every 5 s
  everRead = false;
  haveData = false;
  return true;
}

void pollScd(uint32_t now) {
  if (scdDataReady()) {
    float c, t, h;
    if (scdReadMeasurement(c, t, h) && c >= 1.0f) {  // 0 ppm = invalid sample
      co2ppm = c; tempC = t; rh = h;
      lastGoodMs = now;
      everRead = true;
      if (DEBUG_SCD) {
        Serial.print("# scd co2="); Serial.print(c, 0);
        Serial.print(" ppm t=");    Serial.print(t, 1);
        Serial.print(" C rh=");     Serial.print(h, 1);
        Serial.println(" %");
      }
    }
  }
  haveData = everRead && (now - lastGoodMs) < STALE_MS;
}

// Forced recalibration: tells the sensor "the air right now is CAL_TARGET_PPM".
// Only do this outdoors in fresh air, after the sensor has been running there 3+ minutes.
void forcedRecalibration() {
  Serial.println("# FRC: calibrating to " + String(CAL_TARGET_PPM) + " ppm...");

  scdCmd(CMD_STOP_PERIODIC);
  delay(500);
  bool sent = scdCmdArg(CMD_FORCED_RECAL, CAL_TARGET_PPM);
  delay(400);
  uint8_t b[3];
  bool got = sent && scdRead(b, 3);
  uint16_t w = got ? (((uint16_t)b[0] << 8) | b[1]) : 0xFFFF;
  if (got && w != 0xFFFF) {
    Serial.print("# FRC ok, correction = ");
    Serial.print((int)w - 0x8000);
    Serial.println(" ppm");
  } else {
    Serial.println("# FRC failed (run it after 3+ min of measuring in the new air)");
  }
  scdCmd(CMD_START_PERIODIC);
  everRead = false;                 // wait for a fresh reading
  haveData = false;
}

void tick() {
  uint32_t now = millis();

  // Missing sensor: keep sending nulls and retry every 2 s.
  if (!scdOk && now - lastInitTry > 2000) {
    lastInitTry = now;
    scdOk = initScd();
  }

  if (scdOk && now - lastPoll >= POLL_INTERVAL) {
    lastPoll = now;
    pollScd(now);
  }

}
}  // namespace Air

struct Page {
  const char *name;
  void (*drawStatic)();
  void (*update)();
};

constexpr Page pages[] = {
  {"Heart rate / blood oxygen", Vitals::drawStatic, Vitals::updateDisplay},
  {"Skin temperature", Skin::drawStatic, Skin::updateDisplay},
  {"Motion", Motion::drawStatic, Motion::updateDisplay},
  {"Cabin pressure", Cabin::drawStatic, Cabin::updateDisplay},
  {"Air quality", Air::drawStatic, Air::updateDisplay},
};
constexpr int PAGE_COUNT = sizeof(pages) / sizeof(pages[0]);
int currentPage = 0;

void refreshPage(bool firstDraw) {
  redrawPage = firstDraw;
  if (firstDraw) pages[currentPage].drawStatic();
  pages[currentPage].update();
  drawRocket();
  redrawPage = false;
  lastDraw = millis();
}

void selectPage(int page) {
  if (launchActive) {
    launchActive = false;
    delete launchCanvas;
    launchCanvas = nullptr;
  }
  currentPage = (page + PAGE_COUNT) % PAGE_COUNT;
  Serial.print("# Page ");
  Serial.print(currentPage + 1);
  Serial.print(": ");
  Serial.println(pages[currentPage].name);
  refreshPage(true);
}

void updateLaunch(uint32_t now) {
  const uint32_t elapsed = now - launchStartedAt;
  if (elapsed >= LAUNCH_DURATION) {
    selectPage(0);
  } else if (now - lastLaunchFrame >= LAUNCH_FRAME_INTERVAL) {
    lastLaunchFrame = now;
    drawLaunchFrame(elapsed);
  }
}

void readKeyboard() {
  enum KeyState { Plain, Escape, Arrow };
  static KeyState state = Plain;
  static uint32_t escapeAt = 0;

  // Limit work per loop so a pasted command cannot monopolize sensor polling.
  for (int remaining = 16; remaining > 0 && Serial.available(); --remaining) {
    const char ch = Serial.read();
    if (state != Plain && millis() - escapeAt > 250) state = Plain;
    if (ch == '\x1b') {
      state = Escape;
      escapeAt = millis();
      continue;
    }
    if (state == Escape) {
      state = (ch == '[' || ch == 'O') ? Arrow : Plain;
      continue;
    }
    if (state == Arrow) {
      // Ignore parameters on modified arrow sequences.
      if (ch >= '0' && ch <= '?') continue;
      state = Plain;
      if (ch == 'D') selectPage(currentPage + 1);
      if (ch == 'C') selectPage(currentPage - 1);
      continue;
    }
    if (ch == 'a' || ch == 'A') selectPage(currentPage + 1);
    if (ch == 'd' || ch == 'D') selectPage(currentPage - 1);
    if (ch >= '1' && ch < '1' + PAGE_COUNT) selectPage(ch - '1');
    if ((ch == 'c' || ch == 'C') && Air::scdOk) {
      if (currentPage == 4) Air::drawStatus(Air::S_CAL);
      Air::forcedRecalibration();
    }
  }
}

void printKey(const char *key) {
  Serial.print('"');
  Serial.print(key);
  Serial.print("\":");
}

template <typename T>
void printValue(const char *key, bool valid, T value, int decimals) {
  Serial.print(", ");
  printKey(key);
  if (valid) Serial.print(value, decimals);
  else Serial.print("null");
}

void printReading() {
  const bool airOk = Air::scdOk && Air::haveData;
  const bool cabinOk = Cabin::bmeOk && Cabin::haveData;
  const bool cabinHumidityOk = cabinOk && Cabin::hasHum;

  Serial.print('{');
  printKey("t_ms");
  Serial.print(millis());
  printValue("hr_bpm", Vitals::haveHr, Vitals::displayHr, DEC);
  printValue("spo2_pct", Vitals::haveSpo2, Vitals::displaySpo2, DEC);
  printValue("skin_temp_c", Skin::mlxOk && Skin::haveResult, Skin::resultC, 1);
  printValue("accel_g", Motion::mpuOk && Motion::haveAccel, Motion::accelG, 2);
  printValue("co2_ppm", airOk, (int)(Air::co2ppm + 0.5f), DEC);
  printValue("cabin_temp_c", airOk || cabinOk, airOk ? Air::tempC : Cabin::tempC, 1);
  printValue("humidity_pct", airOk || cabinHumidityOk,
             (int)((airOk ? Air::rh : Cabin::rh) + 0.5f), DEC);
  printValue("pressure_hpa", cabinOk, Cabin::pHpa, 1);
  Serial.println('}');
}

}  // namespace

void frontierSetup() {
  Serial.begin(115200);
  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(100000);
  tft.initR(INITR_BLACKTAB);
  tft.setRotation(0);
  tft.setTextWrap(false);
  beginLaunch();

  delay(300);
  scanI2C();
  Vitals::sensorOk = Vitals::initSensor();
  Skin::mlxOk = Skin::initMlx();
  Motion::mpuOk = Motion::initMpu();
  Cabin::bmeOk = Cabin::initBme();
  Air::scdOk = Air::initScd();

  Serial.println("# Left/A: next | Right/D: back | 1-5: select page");
  launchStartedAt = lastLaunchFrame = millis();
}

void frontierLoop() {
  Vitals::tick();
  Skin::tick();
  Motion::tick();
  Cabin::tick();
  Air::tick();
  readKeyboard();

  const uint32_t now = millis();
  if (now - lastPrint >= PRINT_INTERVAL) {
    lastPrint = now;
    printReading();
  }
  if (launchActive) updateLaunch(now);
  else if (now - lastDraw >= DISPLAY_INTERVAL) refreshPage(false);
}
