// Astronaut Station HUD - Combined ESP32 sketch
// Preserves original MAX30102, MPU6050, SCD41, MLX90614, and BME280/BMP280 sensing algorithms.
// Single ST7735 screen: selectable menu + alert override; no automatic page rotation.
// Serial Monitor baud 115200; combined JSON at 10 Hz; lines beginning # are diagnostics.
// Prototype only: NOT a medical device. Sleep and impact detection are experimental.
#include <Arduino.h>
#include <Wire.h>
#include <SPI.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7735.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include "MAX30105.h"
#include "spo2_algorithm.h"
#include <Adafruit_MLX90614.h>

Adafruit_ST7735 sharedTft(4, 5, 15);

// DEMO MODE: true = the TFT only ever shows the carbon dioxide value (big, in mmHg),
// with no menu, no other pages, and only the high-CO2 alert can interrupt it. All
// five sensors still run and still send their readings over USB to the BioBeacon game.
// Set to false and re-upload to get the full menu and all pages back.
const bool CO2_ONLY = true;


namespace Heart {
// ESP32 + MAX30102 + ST7735 TFT
// Astronaut Station Health HUD
// Spot-check version: warm-up -> measure window -> ONE result
// Prototype only - NOT medical equipment.
//
// Flow:
//   WAIT      : wait for a finger with a good signal for FINGER_STABLE_MS
//   WARMUP    : 30 s settling, restarts if the signal is lost
//   MEASURE   : 30 s collecting every valid HR / SpO2 calculation
//   DONE      : shows ONE HR and ONE SpO2 (median of the window)
//   UNSTABLE  : spread too large or too few samples -> short re-warm-up, retry
//
// To measure again: lift the finger, then place it back.


// ---------------- PINS ----------------

const int SDA_PIN = 25;
const int SCL_PIN = 26;

const int TFT_CS = 4;
const int TFT_DC = 5;
const int TFT_RST = 15;

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

const uint32_t PRINT_INTERVAL = 100;
const uint32_t DISPLAY_INTERVAL = 250;

// ---------------- SENSOR STATE ----------------

MAX30105 sensor;

bool sensorOk = false;
bool fingerPresent = false;

uint32_t lastInitTry = 0;
uint32_t lastPrint = 0;
uint32_t lastDraw = 0;
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

// ---------------- DISPLAY ----------------

Adafruit_ST7735 &tft = sharedTft;

const uint16_t C_BG = ST77XX_BLACK;
const uint16_t C_GREY = 0x7BEF;

struct Field {
  char txt[5];
  uint16_t color;
};

Field fHr = {"", 0};
Field fSp = {"", 0};

// ---------------- HELPERS ----------------

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

uint16_t levelColor(int level) {
  if (level == 0) return ST77XX_GREEN;
  if (level == 1) return ST77XX_YELLOW;
  return ST77XX_RED;
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

// ---------------- STATIC SCREEN ----------------

void drawStatic() {
  tft.fillScreen(C_BG);

  tft.setTextSize(1);
  tft.setTextColor(ST77XX_CYAN, C_BG);

  tft.setCursor(31, 4);
  tft.print("STATION HUD");

  tft.drawFastHLine(0, 15, 128, ST77XX_CYAN);

  tft.setTextColor(ST77XX_WHITE, C_BG);

  tft.setCursor(4, 24);
  tft.print("HEART RATE");

  tft.setCursor(4, 80);
  tft.print("BLOOD OXYGEN");

  tft.drawFastHLine(0, 74, 128, C_GREY);

  tft.setTextSize(2);

  tft.setCursor(84, 52);
  tft.print("bpm");

  tft.setCursor(84, 108);
  tft.print("%");
}

// ---------------- DRAW VALUE ----------------

void drawField(
  Field &field,
  int y,
  bool valid,
  int value,
  uint16_t color
) {
  char buf[5];

  if (valid) {
    snprintf(buf, sizeof(buf), "%3d", value);
  } else {
    strcpy(buf, "---");
  }

  // Redraw even if unchanged: another page may have cleared the screen.

  strcpy(field.txt, buf);
  field.color = color;

  tft.fillRect(0, y, 80, 34, C_BG);

  tft.setTextSize(4);
  tft.setTextColor(color, C_BG);

  tft.setCursor(4, y);
  tft.print(buf);
}

// ---------------- STATUS BAR ----------------

void drawStatus(const char *txt, uint16_t color) {
  static char last[24] = "";
  static uint16_t lastColor = 0;

  // Always redraw after a page switch.

  strncpy(last, txt, sizeof(last) - 1);
  last[sizeof(last) - 1] = 0;
  lastColor = color;

  tft.fillRect(0, 132, 128, 28, color);

  tft.setTextSize(1);
  tft.setTextColor(ST77XX_BLACK, color);

  int16_t x1, y1;
  uint16_t w, h;

  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);

  tft.setCursor((128 - w) / 2, 141);
  tft.print(txt);
}

// ---------------- PROGRESS BAR ----------------

void drawProgress(int pct, uint16_t color) {
  static int lastW = -1;
  static uint16_t lastColor = 0;

  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;

  int w = pct * 128 / 100;

  // Always redraw after a page switch.

  lastW = w;
  lastColor = color;

  tft.fillRect(0, 128, 128, 3, C_BG);

  if (w > 0) tft.fillRect(0, 128, w, 3, color);
}

// ---------------- STATE MACHINE ----------------

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
    fHr, 36,
    haveHr, displayHr,
    haveHr ? levelColor(hl) : C_GREY
  );

  drawField(
    fSp, 92,
    haveSpo2, displaySpo2,
    haveSpo2 ? levelColor(sl) : C_GREY
  );

  char txt[24];
  uint16_t color = C_GREY;
  int pct = 0;
  uint16_t barColor = ST77XX_CYAN;

  if (!sensorOk) {
    strcpy(txt, "NO SENSOR");
    color = ST77XX_RED;
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
          color = ST77XX_CYAN;
        } else {
          strcpy(txt, "NO FINGER");
          color = C_GREY;
        }
        break;

      case ST_WARMUP: {
        uint32_t left = elapsed >= warmupMs
          ? 0 : (warmupMs - elapsed + 999) / 1000;

        snprintf(txt, sizeof(txt), "SETTLING %lus", (unsigned long)left);
        color = ST77XX_YELLOW;
        pct = (int)(elapsed * 100 / warmupMs);
        barColor = ST77XX_YELLOW;
        break;
      }

      case ST_MEASURE: {
        uint32_t left = elapsed >= MEASURE_MS
          ? 0 : (MEASURE_MS - elapsed + 999) / 1000;

        snprintf(txt, sizeof(txt), "MEASURING %lus", (unsigned long)left);
        color = ST77XX_CYAN;
        pct = (int)(elapsed * 100 / MEASURE_MS);
        barColor = ST77XX_CYAN;
        break;
      }

      case ST_UNSTABLE:
        strcpy(txt, "UNSTABLE - RETRY");
        color = ST77XX_YELLOW;
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

  drawProgress(pct, barColor);
  drawStatus(txt, color);
}

// ---------------- I2C SCAN ----------------

void scanI2C() {
  Serial.print("# I2C scan:");

  int found = 0;

  for (uint8_t a = 1; a < 127; a++) {
    Wire.beginTransmission(a);

    if (Wire.endTransmission() == 0) {
      Serial.print(" 0x");
      Serial.print(a, HEX);
      found++;
    }
  }

  if (found == 0)
    Serial.print(" none");

  Serial.println();
}

// ---------------- INITIALIZE SENSOR ----------------

bool initSensor() {
  if (!sensor.begin(Wire, I2C_SPEED_FAST))
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

void printInt(
  const char *key,
  bool valid,
  long value,
  bool last = false
) {
  Serial.print('"');
  Serial.print(key);
  Serial.print("\":");

  if (valid)
    Serial.print(value);
  else
    Serial.print("null");

  if (!last)
    Serial.print(", ");
}

void printNull(
  const char *key,
  bool last = false
) {
  printInt(key, false, 0, last);
}

void printLine() {
  uint32_t now = millis();

  Serial.print('{');

  printInt("t_ms", true, now);

  // Only the final, validated result is published.
  printInt("hr_bpm", haveHr, displayHr);
  printInt("spo2_pct", haveSpo2, displaySpo2);

  printNull("skin_temp_c");
  printNull("accel_g");
  printNull("co2_ppm");
  printNull("cabin_temp_c");
  printNull("humidity_pct");
  printNull("pressure_hpa", true);

  Serial.println('}');
}

// ---------------- SETUP ----------------


}


namespace Motion {
// Sensor_MPU6050.ino
// ESP32 + MPU6050 (GY-521) only -> JSON over USB (~10 Hz) + motion readout on 1.8" ST7735 TFT.
// All other fields are null for now.


// ---------- Pins (from your whiteboard) ----------
const int SDA_PIN = 25;
const int SCL_PIN = 26;
const int TFT_CS  = 4;
const int TFT_DC  = 5;    // "RS" / "D/C" on the display
const int TFT_RST = 15;
// TFT SCK = GPIO 18, TFT SDA (MOSI) = GPIO 23 (default hardware SPI)

// ---------- Config ----------
const bool     SCAN_AT_BOOT     = true;    // prints "# I2C scan: ..." once at startup
const bool     DEBUG_MPU        = true;    // prints a "# mpu ..." line once per second
const uint32_t SAMPLE_INTERVAL  = 20;      // ms -> 50 samples/s
const uint32_t PRINT_INTERVAL   = 100;     // ms -> 10 JSON lines/sec
const uint32_t DISPLAY_INTERVAL = 250;     // ms -> 4 screen updates/sec

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

uint32_t lastSample = 0, lastPrint = 0, lastDraw = 0, lastInitTry = 0, lastDebug = 0;

// ---------- Display ----------
Adafruit_ST7735 &tft = sharedTft;

const uint16_t C_BG   = ST77XX_BLACK;
const uint16_t C_GREY = 0x7BEF;

// Row layout (128 x 160 portrait)
const int Y_ACC  = 20;    // label y; value at +9
const int Y_GYRO = 61;
const int Y_ROW3 = 94;

enum Status { S_NO_SENSOR, S_IMPACT, S_MOVING, S_SLEEP, S_STILL };

struct Field { char txt[8]; uint16_t color; };
Field fAcc = {"", 0}, fGyro = {"", 0}, fMove = {"", 0}, fSleep = {"", 0};

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.setTextSize(1);
  tft.setTextColor(ST77XX_CYAN, C_BG);
  tft.setCursor(31, 4);
  tft.print("STATION HUD");
  tft.drawFastHLine(0, 15, 128, ST77XX_CYAN);

  tft.setTextColor(ST77XX_WHITE, C_BG);
  tft.setCursor(4, Y_ACC);   tft.print("ACCELERATION");
  tft.setCursor(4, Y_GYRO);  tft.print("ROTATION");
  tft.setCursor(4, Y_ROW3);  tft.print("MOVE min");
  tft.setCursor(68, Y_ROW3); tft.print("SLEEP min");
  tft.drawFastHLine(0, Y_GYRO - 4, 128, C_GREY);
  tft.drawFastHLine(0, Y_ROW3 - 4, 128, C_GREY);

  tft.setTextSize(2);
  tft.setCursor(98, Y_ACC + 17);  tft.print("g");
  tft.setTextSize(1);
  tft.setCursor(44, Y_GYRO + 17); tft.print("deg/s");
}

void drawField(Field &f, int x, int y, int size, const char *s, uint16_t color) {
  // Always redraw after a page switch.
  strncpy(f.txt, s, sizeof(f.txt) - 1);
  f.txt[sizeof(f.txt) - 1] = 0;
  f.color = color;
  tft.setTextSize(size);
  tft.setTextColor(color, C_BG);
  tft.fillRect(x, y, (size == 3 ? 115 : 65), size * 8, C_BG);
  tft.setCursor(x, y);
  tft.print(s);
}

void drawStatus(Status s) {
  static int last = -1;
  // Always redraw after a page switch.
  last = s;

  const char *txt;
  uint16_t col, fg = ST77XX_BLACK;
  switch (s) {
    case S_NO_SENSOR: txt = "NO SENSOR"; col = ST77XX_RED;   break;
    case S_IMPACT:    txt = "IMPACT";    col = ST77XX_RED;   break;
    case S_MOVING:    txt = "MOVING";    col = ST77XX_GREEN; break;
    case S_SLEEP:     txt = "SLEEPING";  col = ST77XX_BLUE; fg = ST77XX_WHITE; break;
    default:          txt = "STILL";     col = ST77XX_CYAN;  break;
  }
  tft.fillRect(0, 128, 128, 32, col);
  tft.setTextSize(2);
  tft.setTextColor(fg, col);
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 136);
  tft.print(txt);
}

void updateDisplay() {
  bool ok = mpuOk && haveAccel;
  char buf[8];

  if (ok) snprintf(buf, sizeof(buf), "%5.2f", fminf(accelG, 99.99f)); else strcpy(buf, "--.--");
  drawField(fAcc, 4, Y_ACC + 9, 3, buf, ok ? ST77XX_WHITE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%3d", (int)fminf(gyroDyn, 999.0f)); else strcpy(buf, "---");
  drawField(fGyro, 4, Y_GYRO + 9, 2, buf, ok ? ST77XX_WHITE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%5.1f", fminf(moveS / 60.0f, 999.9f)); else strcpy(buf, " --.-");
  drawField(fMove, 4, Y_ROW3 + 9, 2, buf, ok ? ST77XX_GREEN : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%5.1f", fminf(sleepS / 60.0f, 999.9f)); else strcpy(buf, " --.-");
  drawField(fSleep, 68, Y_ROW3 + 9, 2, buf, ok ? ST77XX_CYAN : C_GREY);

  Status s;
  if (!mpuOk || !haveAccel)         s = S_NO_SENSOR;
  else if (millis() < impactUntil)  s = S_IMPACT;
  else if (moving)                  s = S_MOVING;
  else if (inSleepRun)              s = S_SLEEP;
  else                              s = S_STILL;
  drawStatus(s);
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

// ---------- JSON output ----------
void printNull(const char *key, bool last = false) {
  Serial.print('"'); Serial.print(key); Serial.print("\":null");
  if (!last) Serial.print(", ");
}

void printLine() {
  Serial.print("{\"t_ms\":");
  Serial.print(millis());
  Serial.print(", ");
  printNull("hr_bpm");             // MAX30102 - later
  printNull("spo2_pct");           // MAX30102 - later
  printNull("skin_temp_c");        // MLX90614 - later
  Serial.print("\"accel_g\":");
  if (mpuOk && haveAccel) Serial.print(accelG, 2); else Serial.print("null");
  Serial.print(", ");
  printNull("co2_ppm");            // SCD41    - later
  printNull("cabin_temp_c");       // SCD41    - later
  printNull("humidity_pct");       // SCD41/BME280 - later
  printNull("pressure_hpa", true); // BME280 - later
  Serial.println('}');
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

// ---------- Arduino ----------

}


namespace Air {
// Sensor_SCD41.ino
// ESP32 + SCD41 only -> JSON over USB (~10 Hz) + CO2 / temp / humidity on 1.8" ST7735 TFT.
// Talks to the SCD41 directly over I2C (no sensor library needed).
// All other fields are null for now.


// ---------- Pins (from your whiteboard) ----------
const int SDA_PIN = 25;
const int SCL_PIN = 26;
const int TFT_CS  = 4;
const int TFT_DC  = 5;    // "RS" / "D/C" on the display
const int TFT_RST = 15;
// TFT SCK = GPIO 18, TFT SDA (MOSI) = GPIO 23 (default hardware SPI)

// ---------- Config ----------
const bool     SCAN_AT_BOOT     = true;    // prints "# I2C scan: ..." once at startup
const bool     DEBUG_SCD        = true;    // prints a "# scd ..." line for each new reading
const uint32_t PRINT_INTERVAL   = 100;     // ms -> 10 JSON lines/sec
const uint32_t DISPLAY_INTERVAL = 250;     // ms -> 4 screen updates/sec
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
// (mmHG) Estimated ambient CO2 partial pressure at assumed 760 mmHg total pressure.
// Keep native ppm for sensor readings, alerts, calibration, and existing JSON clients.
// This is NOT blood CO2 partial pressure.
float co2MmHg() { return co2ppm * (760.0f / 1000000.0f); } 

uint32_t lastPrint = 0, lastDraw = 0, lastPoll = 0, lastInitTry = 0;

// ---------- Display ----------
Adafruit_ST7735 &tft = sharedTft;

const uint16_t C_BG   = ST77XX_BLACK;
const uint16_t C_GREY = 0x7BEF;

// Layout (128 x 160 portrait)
const int Y_CO2  = 20;    // label y; big value at +9
const int Y_ROW2 = 62;    // temp / humidity labels; values at +9

enum Status { S_NO_SENSOR, S_WARMING, S_NO_DATA, S_CAL, S_NOMINAL, S_CAUTION, S_ALERT };

struct Field { char txt[8]; uint16_t color; };
Field fCo2 = {"", 0}, fTemp = {"", 0}, fHum = {"", 0};

// 0 = ok, 1 = caution, 2 = alert. Demo thresholds, not medical limits.
int co2Level(int ppm) {
  if (ppm < 1000)  return 0;
  if (ppm <= 2000) return 1;
  return 2;
}
uint16_t levelColor(int lvl) {
  return lvl == 0 ? ST77XX_GREEN : (lvl == 1 ? ST77XX_YELLOW : ST77XX_RED);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.setTextSize(1);
  tft.setTextColor(ST77XX_CYAN, C_BG);
  tft.setCursor(31, 4);
  tft.print("STATION HUD");
  tft.drawFastHLine(0, 15, 128, ST77XX_CYAN);

  if (CO2_ONLY) {  // demo layout: just the CO2 value, big and centred
    tft.setTextColor(ST77XX_WHITE, C_BG);
    tft.setCursor(22, 26);        tft.print("CARBON DIOXIDE");
    tft.setTextSize(2);
    tft.setCursor(40, 74);        tft.print("mmHg");
    tft.drawRect(4, 98, 120, 8, C_GREY);              // CO2 bar outline
    return;
  }

  tft.setTextColor(ST77XX_WHITE, C_BG);
  tft.setCursor(4, Y_CO2);        tft.print("CARBON DIOXIDE");
  tft.setCursor(4, Y_ROW2);       tft.print("TEMP");
  tft.setCursor(80, Y_ROW2);      tft.print("HUMIDITY");
  tft.drawFastHLine(0, Y_ROW2 - 4, 128, C_GREY);
  tft.drawFastHLine(0, 93, 128, C_GREY);
  tft.drawFastVLine(76, Y_ROW2 - 3, 31, C_GREY);

  tft.setTextSize(2);
  tft.setTextSize(1);
  tft.setCursor(93, Y_CO2 + 17);  tft.print("mmHg");
  tft.setTextSize(2);
  tft.drawCircle(57, Y_ROW2 + 13, 2, ST77XX_WHITE);   // degree sign
  tft.setCursor(62, Y_ROW2 + 9);  tft.print("C");
  tft.setCursor(116, Y_ROW2 + 9); tft.print("%");

  tft.drawRect(4, 98, 120, 8, C_GREY);                // CO2 bar outline
}

void drawField(Field &f, int x, int y, int size, const char *s, uint16_t color) {
  // Always redraw after a page switch.
  strncpy(f.txt, s, sizeof(f.txt) - 1);
  f.txt[sizeof(f.txt) - 1] = 0;
  f.color = color;
  tft.setTextSize(size);
  tft.setTextColor(color, C_BG);
  tft.fillRect(x, y, (size == 3 ? 124 - x : 65), size * 8, C_BG);
  tft.setCursor(x, y);
  tft.print(s);
}

// Bar fills from 400 ppm (fresh air) to 3000 ppm.
void drawBar(bool ok, int ppm, uint16_t color) {
  static int lastW = -1;
  static uint16_t lastCol = 0;
  int w = ok ? constrain((ppm - 400) * 118 / 2600, 0, 118) : 0;
  // Always redraw after a page switch.
  lastW = w;
  lastCol = color;
  if (w > 0)   tft.fillRect(5, 99, w, 6, color);
  if (w < 118) tft.fillRect(5 + w, 99, 118 - w, 6, C_BG);
}

void drawHint(const char *s, uint16_t color) {
  static char last[24] = "~";
  static uint16_t lastCol = 0;
  // Always redraw after a page switch.
  strncpy(last, s, sizeof(last) - 1);
  last[sizeof(last) - 1] = 0;
  lastCol = color;
  char buf[24];
  snprintf(buf, sizeof(buf), "%-21s", s);          // pad so old text is overwritten
  tft.setTextSize(1);
  tft.setTextColor(color, C_BG);
  tft.setCursor(4, 110);
  tft.print(buf);
}

void drawStatus(Status s) {
  static int last = -1;
  // Always redraw after a page switch.
  last = s;

  const char *txt;
  uint16_t col;
  switch (s) {
    case S_NO_SENSOR: txt = "NO SENSOR"; col = ST77XX_RED;    break;
    case S_WARMING:   txt = "WARMING UP"; col = ST77XX_CYAN;  break;
    case S_NO_DATA:   txt = "NO DATA";   col = C_GREY;        break;
    case S_CAL:       txt = "CALIBRATE"; col = ST77XX_CYAN;   break;
    case S_NOMINAL:   txt = "NOMINAL";   col = ST77XX_GREEN;  break;
    case S_CAUTION:   txt = "CAUTION";   col = ST77XX_YELLOW; break;
    default:          txt = "ALERT";     col = ST77XX_RED;    break;
  }
  tft.fillRect(0, 128, 128, 32, col);
  tft.setTextSize(2);
  tft.setTextColor(ST77XX_BLACK, col);
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 136);
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
    snprintf(buf, sizeof(buf), "%5.3f", co2MmHg());
  } else {
    strcpy(buf, "----");
  }
  if (CO2_ONLY) drawField(fCo2, 19, 44, 3, buf, col);  // "0.533" = 90 px wide at size 3
  else          drawField(fCo2, 4, Y_CO2 + 9, 2, buf, col);
  drawBar(ok, (int)co2ppm, col);

  if (CO2_ONLY) {
    // (temperature / humidity rows are hidden in the demo layout)
  } else {
  if (ok) snprintf(buf, sizeof(buf), "%4.1f", constrain(tempC, -9.9f, 99.9f));
  else    strcpy(buf, "--.-");
  drawField(fTemp, 4, Y_ROW2 + 9, 2, buf, ok ? ST77XX_WHITE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%3d", constrain((int)(rh + 0.5f), 0, 100));
  else    strcpy(buf, "---");
  drawField(fHum, 80, Y_ROW2 + 9, 2, buf, ok ? ST77XX_WHITE : C_GREY);
  }

  if (!ok)            drawHint("", C_GREY);
  else if (lvl == 0)  drawHint("Air is fresh", ST77XX_GREEN);
  else if (lvl == 1)  drawHint("Stuffy: focus may dip", ST77XX_YELLOW);
  else                drawHint("Headache risk: vent!", ST77XX_RED);

  Status s;
  if (!scdOk)         s = S_NO_SENSOR;
  else if (!haveData) s = everRead ? S_NO_DATA : S_WARMING;
  else                s = (lvl == 0) ? S_NOMINAL : (lvl == 1 ? S_CAUTION : S_ALERT);
  drawStatus(s);
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
  drawStatus(S_CAL);
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

// ---------- JSON output ----------
void printNull(const char *key, bool last = false) {
  Serial.print('"'); Serial.print(key); Serial.print("\":null");
  if (!last) Serial.print(", ");
}

void printLine() {
  bool ok = scdOk && haveData;
  Serial.print("{\"t_ms\":");
  Serial.print(millis());
  Serial.print(", ");
  printNull("hr_bpm");             // MAX30102 - later
  printNull("spo2_pct");           // MAX30102 - later
  printNull("skin_temp_c");        // MLX90614 - later
  printNull("accel_g");            // MPU6050  - later
  Serial.print("\"co2_ppm\":");
  if (ok) Serial.print((int)(co2ppm + 0.5f)); else Serial.print("null");
  Serial.print(", \"cabin_temp_c\":");
  if (ok) Serial.print(tempC, 1); else Serial.print("null");
  Serial.print(", \"humidity_pct\":");
  if (ok) Serial.print((int)(rh + 0.5f)); else Serial.print("null");
  Serial.print(", ");
  printNull("pressure_hpa", true); // BME280 - later
  Serial.println('}');
}

// ---------- Arduino ----------

}


namespace Infrared {
// ---------- Timing ----------
const bool     SCAN_AT_BOOT     = true;
const uint32_t PRINT_INTERVAL   = 100;     // ms -> 10 JSON lines/sec
const uint32_t DISPLAY_INTERVAL = 250;     // ms -> 4 screen updates/sec
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

uint32_t lastPrint = 0, lastDraw = 0, lastSample = 0, lastInitTry = 0, lastDebug = 0;

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

// ---------- Display ----------
Adafruit_ST7735 &tft = sharedTft;

const uint16_t C_BG   = ST77XX_BLACK;
const uint16_t C_GREY = 0x7BEF;

// ---------- Helpers ----------
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

// ---------- Display drawing ----------
void drawStatic() {
  // Page re-entry: clear cached field text and redraw below.

  tft.fillScreen(C_BG);
  tft.setTextSize(1);
  tft.setTextColor(ST77XX_CYAN, C_BG);
  tft.setCursor(31, 4);
  tft.print("STATION HUD");
  tft.drawFastHLine(0, 15, 128, ST77XX_CYAN);

  tft.setTextColor(ST77XX_WHITE, C_BG);
  tft.setCursor(4, 28);
  tft.print("OBJECT TEMP");

  tft.setTextColor(C_GREY, C_BG);
  tft.setCursor(4, 100);
  tft.print("Hold sensor 2-3 cm");
  tft.setCursor(4, 110);
  tft.print("from the object");

  tft.setTextColor(ST77XX_WHITE, C_BG);
  tft.setTextSize(2);
  tft.drawCircle(105, 58, 2, ST77XX_WHITE);   // degree sign
  tft.setCursor(110, 62);
  tft.print("C");
}

void drawTemp(const char *s, uint16_t color) {
  static char lastTxt[8] = "";
  static uint16_t lastColor = 0;
  // redraw after page changes
  strncpy(lastTxt, s, sizeof(lastTxt) - 1);
  lastTxt[sizeof(lastTxt) - 1] = 0;
  lastColor = color;
  tft.setTextSize(4);
  tft.setTextColor(color, C_BG);
  tft.setCursor(2, 44);
  tft.print(s);
}

void drawProgress(int pct, uint16_t color) {
  static int lastW = -1;
  static uint16_t lastColor = 0;

  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  int w = pct * 128 / 100;

  // Always repaint progress: the shared TFT may have shown another page.
  lastW = w;
  lastColor = color;

  tft.fillRect(0, 121, 128, 4, C_BG);
  if (w > 0) tft.fillRect(0, 121, w, 4, color);
}

void drawStatus(const char *txt, uint16_t col) {
  static char last[24] = "";
  static uint16_t lastCol = 0;
  // redraw after page changes

  strncpy(last, txt, sizeof(last) - 1);
  last[sizeof(last) - 1] = 0;
  lastCol = col;

  tft.fillRect(0, 128, 128, 32, col);
  tft.setTextSize(strlen(txt) <= 10 ? 2 : 1);
  tft.setTextColor(ST77XX_BLACK, col);

  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 128 + (32 - h) / 2);
  tft.print(txt);
}

// ---------- State machine ----------
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

  drawTemp(buf, haveResult ? ST77XX_GREEN : C_GREY);

  char txt[24];
  uint16_t color = C_GREY;
  int pct = 0;
  uint16_t barColor = ST77XX_CYAN;

  if (!mlxOk) {
    strcpy(txt, "NO SENSOR");
    color = ST77XX_RED;
  } else {
    uint32_t elapsed = now - stateStart;

    switch (state) {
      case ST_WAIT:
        if (haveResult) {
          strcpy(txt, "LAST READING");
          color = C_GREY;
        } else {
          strcpy(txt, "AIM & HOLD STILL");
          color = targetSteady() ? ST77XX_CYAN : C_GREY;
        }
        break;

      case ST_SETTLE: {
        uint32_t left = elapsed >= settleMs ? 0 : (settleMs - elapsed + 999) / 1000;
        snprintf(txt, sizeof(txt), "CALIBRATING %lus", (unsigned long)left);
        color = ST77XX_YELLOW;
        pct = (int)(elapsed * 100 / settleMs);
        barColor = ST77XX_YELLOW;
        break;
      }

      case ST_MEASURE: {
        uint32_t left = elapsed >= MEASURE_MS ? 0 : (MEASURE_MS - elapsed + 999) / 1000;
        snprintf(txt, sizeof(txt), "MEASURING %lus", (unsigned long)left);
        color = ST77XX_CYAN;
        pct = (int)(elapsed * 100 / MEASURE_MS);
        barColor = ST77XX_CYAN;
        break;
      }

      case ST_UNSTABLE:
        strcpy(txt, "HOLD STEADY");
        color = ST77XX_YELLOW;
        break;

      case ST_DONE:
      default:
        strcpy(txt, "FINAL READING");
        color = ST77XX_GREEN;
        pct = 100;
        barColor = ST77XX_GREEN;
        break;
    }
  }

  drawProgress(pct, barColor);
  drawStatus(txt, color);
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

// ---------- JSON output ----------
void printNull(const char *key, bool last = false) {
  Serial.print('"'); Serial.print(key); Serial.print("\":null");
  if (!last) Serial.print(", ");
}

void printLine() {
  Serial.print("{\"t_ms\":");
  Serial.print(millis());
  Serial.print(", ");
  printNull("hr_bpm");             // MAX30102 - later
  printNull("spo2_pct");           // MAX30102 - later
  Serial.print("\"skin_temp_c\":");
  if (mlxOk && haveResult) Serial.print(resultC, 1); else Serial.print("null");
  Serial.print(", ");
  printNull("accel_g");            // MPU6050  - later
  printNull("co2_ppm");            // SCD41    - later
  printNull("cabin_temp_c");       // SCD41    - later
  printNull("humidity_pct");       // SCD41/BME280 - later
  printNull("pressure_hpa", true); // BME280 - later
  Serial.println('}');
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


}

namespace Pressure {
// Sensor_BME280.ino
// ESP32 + BME280 only -> JSON over USB (~10 Hz) + pressure / temp / humidity on 1.8" ST7735 TFT.
// Talks to the sensor directly over I2C (no sensor library needed).
// Also detects a mislabeled BMP280 (no humidity) automatically.
// All other fields are null for now.


// ---------- Pins (from your whiteboard) ----------
const int SDA_PIN = 25;
const int SCL_PIN = 26;
const int TFT_CS  = 4;
const int TFT_DC  = 5;    // "RS" / "D/C" on the display
const int TFT_RST = 15;
// TFT SCK = GPIO 18, TFT SDA (MOSI) = GPIO 23 (default hardware SPI)

// ---------- Config ----------
const bool     SCAN_AT_BOOT       = true;     // prints "# I2C scan: ..." once at startup
const bool     DEBUG_BME          = true;     // prints a "# bme ..." line once per second
const uint32_t PRINT_INTERVAL     = 100;      // ms -> 10 JSON lines/sec
const uint32_t DISPLAY_INTERVAL   = 250;      // ms -> 4 screen updates/sec
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

uint32_t lastPrint = 0, lastDraw = 0, lastPoll = 0, lastInitTry = 0, lastDebug = 0;

// ---------- Display ----------
Adafruit_ST7735 &tft = sharedTft;

const uint16_t C_BG   = ST77XX_BLACK;
const uint16_t C_GREY = 0x7BEF;

// Layout (128 x 160 portrait)
const int Y_P    = 20;    // pressure label y; big value at +9
const int Y_ROW2 = 62;    // temp / humidity
const int Y_ROW3 = 97;    // % of Earth / trend

enum Status { S_NO_SENSOR, S_NO_DATA, S_DROP, S_NOMINAL, S_CAUTION, S_ALERT };

struct Field { char txt[8]; uint16_t color; };
Field fP = {"", 0}, fTemp = {"", 0}, fHum = {"", 0}, fEarth = {"", 0}, fTrend = {"", 0};

// 0 = ok, 1 = caution, 2 = alert. Demo thresholds, not medical limits.
int pressureLevel(float p) {
  if (p >= 980.0f && p <= 1040.0f) return 0;
  if ((p >= 900.0f && p < 980.0f) || (p > 1040.0f && p <= 1060.0f)) return 1;
  return 2;
}
uint16_t levelColor(int lvl) {
  return lvl == 0 ? ST77XX_GREEN : (lvl == 1 ? ST77XX_YELLOW : ST77XX_RED);
}

void drawStatic() {
  tft.fillScreen(C_BG);
  tft.setTextSize(1);
  tft.setTextColor(ST77XX_CYAN, C_BG);
  tft.setCursor(31, 4);
  tft.print("STATION HUD");
  tft.drawFastHLine(0, 15, 128, ST77XX_CYAN);

  tft.setTextColor(ST77XX_WHITE, C_BG);
  tft.setCursor(4, Y_P);       tft.print("PRESSURE");
  tft.setCursor(104, Y_P);     tft.print("hPa");
  tft.setCursor(4, Y_ROW2);    tft.print("TEMP");
  tft.setCursor(80, Y_ROW2);   tft.print("HUMIDITY");
  tft.setCursor(4, Y_ROW3);    tft.print("% OF EARTH");
  tft.setCursor(68, Y_ROW3);   tft.print("hPa/min");
  tft.drawFastHLine(0, Y_ROW2 - 4, 128, C_GREY);
  tft.drawFastHLine(0, Y_ROW3 - 4, 128, C_GREY);
  tft.drawFastVLine(76, Y_ROW2 - 3, 31, C_GREY);
  tft.drawFastVLine(64, Y_ROW3 - 3, 28, C_GREY);

  tft.setTextSize(2);
  tft.drawCircle(57, Y_ROW2 + 13, 2, ST77XX_WHITE);   // degree sign
  tft.setCursor(62, Y_ROW2 + 9);   tft.print("C");
  tft.setCursor(116, Y_ROW2 + 9);  tft.print("%");
  tft.setCursor(40, Y_ROW3 + 9);   tft.print("%");
}

void drawField(Field &f, int x, int y, int size, const char *s, uint16_t color) {
  // Redraw after switching pages; cached text may belong to another page.
  tft.fillRect(x, y, size == 3 ? 124 : 62, size * 8, C_BG);
  strncpy(f.txt, s, sizeof(f.txt) - 1);
  f.txt[sizeof(f.txt) - 1] = 0;
  f.color = color;
  tft.setTextSize(size);
  tft.setTextColor(color, C_BG);
  tft.setCursor(x, y);
  tft.print(s);
}

void drawHint(const char *s, uint16_t color) {
  static char last[24] = "~";
  static uint16_t lastCol = 0;
  // Always repaint hint after switching pages.
  strncpy(last, s, sizeof(last) - 1);
  last[sizeof(last) - 1] = 0;
  lastCol = color;
  char buf[24];
  snprintf(buf, sizeof(buf), "%-21s", s);          // pad so old text is overwritten
  tft.setTextSize(1);
  tft.setTextColor(color, C_BG);
  tft.setCursor(4, 127);
  tft.print(buf);
}

void drawStatus(Status s) {
  static int last = -1;
  // Always repaint status after switching pages.
  last = s;

  const char *txt;
  uint16_t col;
  switch (s) {
    case S_NO_SENSOR: txt = "NO SENSOR";  col = ST77XX_RED;    break;
    case S_NO_DATA:   txt = "NO DATA";    col = C_GREY;        break;
    case S_DROP:      txt = "PRESS DROP"; col = ST77XX_RED;    break;
    case S_NOMINAL:   txt = "NOMINAL";    col = ST77XX_GREEN;  break;
    case S_CAUTION:   txt = "CAUTION";    col = ST77XX_YELLOW; break;
    default:          txt = "ALERT";      col = ST77XX_RED;    break;
  }
  tft.fillRect(0, 141, 128, 19, col);
  tft.setTextSize(2);
  tft.setTextColor(ST77XX_BLACK, col);
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(txt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((128 - w) / 2, 143);
  tft.print(txt);
}

void updateDisplay() {
  bool ok = bmeOk && haveData;
  bool leak = ok && haveTrend && trendHpaMin <= DROP_ALERT_HPA_MIN;
  int lvl = ok ? pressureLevel(pHpa) : -1;
  uint16_t pCol = !ok ? C_GREY : (leak ? ST77XX_RED : levelColor(lvl));
  char buf[10];

  if (ok) snprintf(buf, sizeof(buf), "%6.1f", pHpa); else strcpy(buf, "----.-");
  drawField(fP, 4, Y_P + 9, 3, buf, pCol);

  if (ok) snprintf(buf, sizeof(buf), "%4.1f", constrain(tempC, -9.9f, 99.9f)); else strcpy(buf, "--.-");
  drawField(fTemp, 4, Y_ROW2 + 9, 2, buf, ok ? ST77XX_WHITE : C_GREY);

  bool humOk = ok && hasHum;
  if (humOk) snprintf(buf, sizeof(buf), "%3d", constrain((int)(rh + 0.5f), 0, 100)); else strcpy(buf, "---");
  drawField(fHum, 80, Y_ROW2 + 9, 2, buf, humOk ? ST77XX_WHITE : C_GREY);

  if (ok) snprintf(buf, sizeof(buf), "%3d", constrain((int)(pHpa / EARTH_SEA_LEVEL * 100.0f + 0.5f), 0, 999));
  else    strcpy(buf, "---");
  drawField(fEarth, 4, Y_ROW3 + 9, 2, buf, ok ? ST77XX_WHITE : C_GREY);

  if (ok && haveTrend) {
    float tr = constrain(trendHpaMin, -9.9f, 9.9f);
    if (fabsf(tr) < 0.05f) tr = 0.0f;               // avoid "-0.0"
    snprintf(buf, sizeof(buf), "%+.1f", tr);
  } else {
    strcpy(buf, "--.-");
  }
  drawField(fTrend, 68, Y_ROW3 + 9, 2, buf, (ok && haveTrend) ? (leak ? ST77XX_RED : ST77XX_WHITE) : C_GREY);

  if (!ok)                 drawHint("", C_GREY);
  else if (leak)           drawHint("Possible cabin leak!", ST77XX_RED);
  else if (lvl == 1)       drawHint("Pressure off nominal", ST77XX_YELLOW);
  else if (lvl == 2)       drawHint("Outside cabin range", ST77XX_RED);
  else if (!hasHum)        drawHint("Normal | BMP280 no RH", ST77XX_GREEN);
  else                     drawHint("Cabin pressure normal", ST77XX_GREEN);

  Status s;
  if (!bmeOk)         s = S_NO_SENSOR;
  else if (!haveData) s = S_NO_DATA;
  else if (leak)      s = S_DROP;
  else                s = (lvl == 0) ? S_NOMINAL : (lvl == 1 ? S_CAUTION : S_ALERT);
  drawStatus(s);
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

// ---------- JSON output ----------
void printNull(const char *key, bool last = false) {
  Serial.print('"'); Serial.print(key); Serial.print("\":null");
  if (!last) Serial.print(", ");
}

void printLine() {
  bool ok = bmeOk && haveData;
  Serial.print("{\"t_ms\":");
  Serial.print(millis());
  Serial.print(", ");
  printNull("hr_bpm");             // MAX30102 - later
  printNull("spo2_pct");           // MAX30102 - later
  printNull("skin_temp_c");        // MLX90614 - later
  printNull("accel_g");            // MPU6050  - later
  printNull("co2_ppm");            // SCD41    - later
  Serial.print("\"cabin_temp_c\":");
  if (ok) Serial.print(tempC, 1); else Serial.print("null");
  Serial.print(", \"humidity_pct\":");
  if (ok && hasHum) Serial.print((int)(rh + 0.5f)); else Serial.print("null");
  Serial.print(", \"pressure_hpa\":");
  if (ok) Serial.print(pHpa, 1); else Serial.print("null");
  Serial.println('}');
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


}

// ---------------- Menu + alert-driven orchestrator ----------------
// Optional push buttons: connect GPIO32 and GPIO33 to GND when pressed.
// No buttons? Serial Monitor at 115200: m=menu, 1-5=pages, n=next, s=select,
// b=back, k=acknowledge cleared alert, t=simulate alert, c=SCD41 calibration.
const uint8_t CO2_PAGE = 2;
const int NEXT_BUTTON_PIN = 32;
const int SELECT_BUTTON_PIN = 33;
const uint32_t BUTTON_DEBOUNCE_MS = 40;
const uint32_t LONG_PRESS_MS = 850;
const uint32_t JSON_PERIOD_MS = 100;
const uint32_t SCREEN_PERIOD_MS = 250;
uint8_t activePage = 0; // 0 heart, 1 motion, 2 air, 3 infrared, 4 pressure
uint8_t menuSelection = 0;
bool menuVisible = true;
uint32_t lastCombinedPrint = 0, lastScreenDraw = 0;

// Alert priority: impact, SpO2, HR, pressure drop, pressure range, CO2.
// Thresholds are reused from each original sketch. These are DEMO thresholds.
enum AlertKind { ALERT_NONE, ALERT_IMPACT, ALERT_SPO2, ALERT_HR,
                 ALERT_LEAK, ALERT_PRESSURE, ALERT_CO2, ALERT_TEST };
AlertKind currentAlert = ALERT_NONE;
bool alertAcknowledged = false;
bool demoAlert = false;

const char* pageNames[5] = {"HEART / SPO2", "MOVEMENT", "CO2 / AIR", "OBJECT TEMP", "PRESSURE"};

void drawMenu() {
  sharedTft.fillScreen(ST77XX_BLACK);
  sharedTft.setTextSize(1);
  sharedTft.setTextColor(ST77XX_CYAN, ST77XX_BLACK);
  sharedTft.setCursor(29, 4); sharedTft.print("STATION HUD");
  sharedTft.drawFastHLine(0, 15, 128, ST77XX_CYAN);
  sharedTft.setTextColor(ST77XX_WHITE, ST77XX_BLACK);
  sharedTft.setCursor(4, 20); sharedTft.print("SELECT SENSOR");
  for (int i = 0; i < 5; i++) {
    int y = 35 + i * 20;
    bool selected = i == menuSelection;
    if (selected) sharedTft.fillRect(1, y-2, 126, 18, ST77XX_BLUE);
    sharedTft.setTextColor(selected ? ST77XX_WHITE : 0xBDF7,
                           selected ? ST77XX_BLUE : ST77XX_BLACK);
    sharedTft.setCursor(4, y);
    sharedTft.print(i + 1); sharedTft.print(" "); sharedTft.print(pageNames[i]);
  }
  sharedTft.setTextColor(ST77XX_GREEN, ST77XX_BLACK);
  sharedTft.setCursor(4, 142); sharedTft.print("ALL SENSORS ACTIVE");
}

void showPage(uint8_t page) {
  if (CO2_ONLY) page = CO2_PAGE;
  activePage = page;
  menuVisible = false;
  if (page == 0) Heart::drawStatic();
  else if (page == 1) Motion::drawStatic();
  else if (page == 2) Air::drawStatic();
  else if (page == 3) Infrared::drawStatic();
  else Pressure::drawStatic();
  lastScreenDraw = 0;
}

void showMenu() {
  if (CO2_ONLY) { showPage(CO2_PAGE); return; }  // no menu in CO2-only demo mode
  menuVisible = true; drawMenu();
}

AlertKind detectAlert() {
  uint32_t now = millis();
  if (demoAlert) return ALERT_TEST;
  if (CO2_ONLY) {  // only the CO2 alert may take over the screen during the demo
    if (Air::scdOk && Air::haveData && Air::co2Level((int)(Air::co2ppm + 0.5f)) == 2) return ALERT_CO2;
    return ALERT_NONE;
  }
  if (Motion::mpuOk && Motion::haveAccel &&
      (int32_t)(Motion::impactUntil - now) > 0) return ALERT_IMPACT;
  if (Heart::sensorOk && Heart::haveSpo2 && Heart::spo2Level(Heart::displaySpo2) == 2) return ALERT_SPO2;
  if (Heart::sensorOk && Heart::haveHr && Heart::hrLevel(Heart::displayHr) == 2) return ALERT_HR;
  if (Pressure::bmeOk && Pressure::haveData) {
    if (Pressure::haveTrend && Pressure::trendHpaMin <= Pressure::DROP_ALERT_HPA_MIN) return ALERT_LEAK;
    if (Pressure::pressureLevel(Pressure::pHpa) == 2) return ALERT_PRESSURE;
  }
  if (Air::scdOk && Air::haveData && Air::co2Level((int)(Air::co2ppm + 0.5f)) == 2) return ALERT_CO2;
  return ALERT_NONE;
}

void drawAlert() {
  sharedTft.fillScreen(ST77XX_BLACK);
  sharedTft.fillRect(0, 0, 128, 20, ST77XX_RED);
  sharedTft.setTextColor(ST77XX_WHITE, ST77XX_RED);
  sharedTft.setTextSize(2); sharedTft.setCursor(33, 2); sharedTft.print("ALERT");
  sharedTft.setTextColor(ST77XX_YELLOW, ST77XX_BLACK);
  sharedTft.setTextSize(1); sharedTft.setCursor(5, 32);
  switch (currentAlert) {
    case ALERT_IMPACT: sharedTft.print("POSSIBLE IMPACT"); break;
    case ALERT_SPO2: sharedTft.print("LOW BLOOD OXYGEN"); break;
    case ALERT_HR: sharedTft.print("HEART RATE ALERT"); break;
    case ALERT_LEAK: sharedTft.print("PRESSURE FALLING"); break;
    case ALERT_PRESSURE: sharedTft.print("CABIN PRESSURE"); break;
    case ALERT_CO2: sharedTft.print("HIGH CO2 LEVEL"); break;
    case ALERT_TEST: sharedTft.print("TEST ALERT ONLY"); break;
    default: break;
  }
  sharedTft.setTextSize(2); sharedTft.setTextColor(ST77XX_WHITE, ST77XX_BLACK);
  sharedTft.setCursor(5, 57);
  switch (currentAlert) {
    case ALERT_IMPACT: sharedTft.print(Motion::accelG, 1); sharedTft.print(" g"); break;
    case ALERT_SPO2: sharedTft.print(Heart::displaySpo2); sharedTft.print(" %"); break;
    case ALERT_HR: sharedTft.print(Heart::displayHr); sharedTft.print(" BPM"); break;
    case ALERT_LEAK: sharedTft.print(Pressure::trendHpaMin, 1); sharedTft.print(" hPa/m"); break;
    case ALERT_PRESSURE: sharedTft.print(Pressure::pHpa, 0); sharedTft.print(" hPa"); break;
    case ALERT_CO2: sharedTft.print(Air::co2MmHg(), 3); sharedTft.print(" mmHg"); break;
    case ALERT_TEST: sharedTft.print("DEMO"); break;
    default: break;
  }
  sharedTft.setTextSize(1); sharedTft.setTextColor(ST77XX_WHITE, ST77XX_BLACK);
  sharedTft.setCursor(5, 105);
  sharedTft.print("Check sensor / cabin");
  sharedTft.setCursor(5, 118);
  sharedTft.print("condition immediately");
  sharedTft.setTextColor(ST77XX_CYAN, ST77XX_BLACK);
  sharedTft.setCursor(4, 144);
  sharedTft.print("Select/K: acknowledge");
}

void refreshAlert() {
  AlertKind detected = detectAlert();
  if (detected != ALERT_NONE) {
    if (detected != currentAlert) {
      currentAlert = detected;
      alertAcknowledged = false;
      drawAlert();
      Serial.println("# HUD alert triggered");
    }
  } else if (currentAlert != ALERT_NONE && alertAcknowledged) {
    currentAlert = ALERT_NONE;
    if (menuVisible) drawMenu(); else showPage(activePage);
    Serial.println("# HUD alert cleared");
  } else if (currentAlert != ALERT_NONE && detected == ALERT_NONE) {
    // Alert is no longer present, but keep it visible until acknowledged.
  }
}

void acknowledgeAlert() {
  if (currentAlert != ALERT_NONE) {
    alertAcknowledged = true;
    demoAlert = false;
    refreshAlert();
    if (currentAlert != ALERT_NONE) Serial.println("# Alert acknowledged; condition still active");
  }
}

void nextSelection() {
  if (currentAlert != ALERT_NONE) return;
  if (!menuVisible) { showMenu(); return; }
  menuSelection = (menuSelection + 1) % 5;
  drawMenu();
}
void selectSelection() {
  if (currentAlert != ALERT_NONE) { acknowledgeAlert(); return; }
  if (menuVisible) showPage(menuSelection);
  else showMenu();
}

// Edge-triggered, debounced buttons; hold Select for 850ms to return to menu.
struct ButtonState { bool raw, stable; uint32_t changedAt, pressedAt; bool longDone; };
ButtonState nextButton = {HIGH,HIGH,0,0,false};
ButtonState selectButton = {HIGH,HIGH,0,0,false};
void pollButtons(uint32_t now) {
  bool rawNext = digitalRead(NEXT_BUTTON_PIN);
  bool rawSelect = digitalRead(SELECT_BUTTON_PIN);
  if (rawNext != nextButton.raw) { nextButton.raw = rawNext; nextButton.changedAt = now; }
  if (rawSelect != selectButton.raw) { selectButton.raw = rawSelect; selectButton.changedAt = now; }
  if (now - nextButton.changedAt >= BUTTON_DEBOUNCE_MS && rawNext != nextButton.stable) {
    nextButton.stable = rawNext;
    if (rawNext == LOW) nextSelection();
  }
  if (now - selectButton.changedAt >= BUTTON_DEBOUNCE_MS && rawSelect != selectButton.stable) {
    selectButton.stable = rawSelect;
    if (rawSelect == LOW) { selectButton.pressedAt = now; selectButton.longDone = false; }
    else if (!selectButton.longDone) selectSelection();
  }
  if (selectButton.stable == LOW && !selectButton.longDone &&
      now - selectButton.pressedAt >= LONG_PRESS_MS) {
    selectButton.longDone = true;
    if (currentAlert != ALERT_NONE) acknowledgeAlert(); else showMenu();
  }
}

void combinedJson() {
  Serial.print("{\"t_ms\":"); Serial.print(millis());
  Serial.print(", \"hr_bpm\":");
  if (Heart::sensorOk && Heart::haveHr) Serial.print(Heart::displayHr); else Serial.print("null");
  Serial.print(", \"spo2_pct\":");
  if (Heart::sensorOk && Heart::haveSpo2) Serial.print(Heart::displaySpo2); else Serial.print("null");
  Serial.print(", \"skin_temp_c\":");
  if (Infrared::mlxOk && Infrared::haveResult) Serial.print(Infrared::resultC, 1); else Serial.print("null");
  Serial.print(", \"accel_g\":");
  if (Motion::mpuOk && Motion::haveAccel) Serial.print(Motion::accelG, 2); else Serial.print("null");
  Serial.print(", \"co2_ppm\":");
  if (Air::scdOk && Air::haveData) Serial.print((int)(Air::co2ppm + 0.5f)); else Serial.print("null");
  Serial.print(", \"co2_mmhg\":");
  if (Air::scdOk && Air::haveData) Serial.print(Air::co2MmHg(), 3); else Serial.print("null");
  Serial.print(", \"cabin_temp_c\":");
  if (Air::scdOk && Air::haveData) Serial.print(Air::tempC, 1); else Serial.print("null");
  Serial.print(", \"humidity_pct\":");
  if (Air::scdOk && Air::haveData) Serial.print((int)(Air::rh + 0.5f)); else Serial.print("null");
  Serial.print(", \"pressure_hpa\":");
  if (Pressure::bmeOk && Pressure::haveData) Serial.print(Pressure::pHpa, 1); else Serial.print("null");
  Serial.println("}");
}

void setup() {
  Serial.begin(115200);
  Wire.begin(25, 26);
  Wire.setClock(100000);
  sharedTft.initR(INITR_BLACKTAB);
  sharedTft.setRotation(0);
  delay(300);
  Heart::scanI2C();
  Heart::sensorOk = Heart::initSensor();
  Motion::mpuOk = Motion::initMpu();
  Air::scdOk = Air::initScd();
  Infrared::mlxOk = Infrared::initMlx();
  Pressure::bmeOk = Pressure::initBme();
  // SCD41 and MPU6050 work at 100 kHz; MAX30102 library configures its own bus speed.
  Wire.setClock(100000);
  pinMode(NEXT_BUTTON_PIN, INPUT_PULLUP);
  pinMode(SELECT_BUTTON_PIN, INPUT_PULLUP);
  showMenu();
  Serial.println("# HUD ready. m=menu 1-5=sensor n=next s=select b=back k=ack t=test c=SCD41 calibration");
}

void loop() {
  uint32_t now = millis();
  // Prioritize heart sensor FIFO servicing to avoid dropped samples.
  if (!Heart::sensorOk) {
    if (now - Heart::lastInitTry > 2000) {
      Heart::lastInitTry = now;
      Heart::sensorOk = Heart::initSensor();
      if (Heart::sensorOk) {
        Heart::resetMeasurement(); Heart::haveHr = false; Heart::haveSpo2 = false;
        Heart::setState(Heart::ST_WAIT);
      }
    }
  } else {
    Heart::sensor.check();
    while (Heart::sensor.available()) {
      Heart::addSample(Heart::sensor.getFIFORed(), Heart::sensor.getFIFOIR());
      Heart::sensor.nextSample();
    }
  }
  Heart::updateState();
  now = millis();
  if (!Motion::mpuOk && now - Motion::lastInitTry > 2000) {
    Motion::lastInitTry = now;
    Motion::mpuOk = Motion::initMpu();
  }
  if (Motion::mpuOk && now - Motion::lastSample >= Motion::SAMPLE_INTERVAL) {
    uint32_t dt = now - Motion::lastSample;
    Motion::lastSample = now;
    if (dt > 200) dt = 200;
    Motion::readMpu(now);
    if (Motion::haveAccel) Motion::updateActivity(now, dt);
  }
  if (!Air::scdOk && now - Air::lastInitTry > 2000) {
    Air::lastInitTry = now;
    Air::scdOk = Air::initScd();
  }
  if (Air::scdOk && now - Air::lastPoll >= Air::POLL_INTERVAL) {
    Air::lastPoll = now;
    Air::pollScd(now);
  }
  if (!Infrared::mlxOk && now - Infrared::lastInitTry > 2000) {
    Infrared::lastInitTry = now;
    Infrared::mlxOk = Infrared::initMlx();
    if (Infrared::mlxOk) {
      Infrared::ringCount = Infrared::ringIndex = 0;
      Infrared::rejectRun = Infrared::nanRun = 0;
      Infrared::haveResult = false;
      Infrared::setState(Infrared::ST_WAIT);
    }
  }
  if (Infrared::mlxOk && now - Infrared::lastSample >= Infrared::SAMPLE_INTERVAL) {
    Infrared::lastSample = now;
    Infrared::takeSample();
  }
  Infrared::updateState();
  if (!Pressure::bmeOk && now - Pressure::lastInitTry > 2000) {
    Pressure::lastInitTry = now;
    Pressure::bmeOk = Pressure::initBme();
  }
  if (Pressure::bmeOk && now - Pressure::lastPoll >= Pressure::POLL_INTERVAL) {
    Pressure::lastPoll = now;
    Pressure::pollBme(now);
  }
  pollButtons(millis());
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch >= '1' && ch <= '5') {
      if (currentAlert == ALERT_NONE) showPage(ch - '1');
    } else if (ch == 'm' || ch == 'M' || ch == 'b' || ch == 'B') {
      if (currentAlert == ALERT_NONE) showMenu();
    } else if (ch == 'n' || ch == 'N') {
      nextSelection();
    } else if (ch == 's' || ch == 'S') {
      selectSelection();
    } else if (ch == 'k' || ch == 'K') {
      acknowledgeAlert();
    } else if (ch == 't' || ch == 'T') {
      demoAlert = true;
    } else if ((ch == 'c' || ch == 'C') && Air::scdOk) {
      Air::forcedRecalibration(); // Only calibrate outdoors after stabilization.
    }
  }
  refreshAlert();
  now = millis();
  if (now - Infrared::lastDebug >= 500) {
    Infrared::lastDebug = now;
    Infrared::printDebug();
  }
  if (Pressure::DEBUG_BME && Pressure::bmeOk && Pressure::haveData && now - Pressure::lastDebug >= 1000) {
    Pressure::lastDebug = now;
    Pressure::printDebug();
  }
  if (now - lastCombinedPrint >= JSON_PERIOD_MS) {
    lastCombinedPrint = now;
    combinedJson();
  }
  if (Motion::DEBUG_MPU && Motion::haveAccel && now - Motion::lastDebug >= 1000) {
    Motion::lastDebug = now;
    Motion::printDebug();
  }
  if (now - lastScreenDraw >= SCREEN_PERIOD_MS) {
    lastScreenDraw = now;
    if (currentAlert != ALERT_NONE) {
      static uint32_t lastAlertDraw = 0;
      if (now - lastAlertDraw >= 1000) { lastAlertDraw = now; drawAlert(); }
    }
    else if (menuVisible) { /* menu is static; do not redraw */ }
    else if (activePage == 0) Heart::updateDisplay();
    else if (activePage == 1) Motion::updateDisplay();
    else if (activePage == 2) Air::updateDisplay();
    else if (activePage == 3) Infrared::updateDisplay();
    else Pressure::updateDisplay();
  }
}