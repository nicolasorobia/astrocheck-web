// The Next Frontier
// Open this sketch with its companion .cpp and .h files.
// Serial Monitor, 115200 baud: send 1-5 to select a sensor page.
// In a terminal that sends arrow keys: Left = next, Right = back.

void frontierSetup();
void frontierLoop();

void setup() {
  frontierSetup();
}

void loop() {
  frontierLoop();
}
