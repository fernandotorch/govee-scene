# govee-scene

Android app for running Govee H6047 RGBIC light bar effects during tabletop RPG sessions. Loads **session packs** authored in [govee-scene-web](https://github.com/fernandotorch/govee-scene-web) and plays them without a laptop — lights, Spotify, ambient sound, and trigger effects all from the phone.

## What a session pack contains

A session pack is a ZIP exported from Studio with:

- **Arc** — ordered list of scenes, each with a Govee light effect, a Spotify playlist URI, and an optional ambient loop
- **Trigger sounds** — one-shot audio files (OGG/MP3) assigned to tap buttons on the performance screen
- **Ambient loops** — background audio (rain, crowd, etc.) that crossfades between scenes
- **session.json** — manifest linking everything together

## App flow

1. **Load** — browse your local Flask Studio server or pick a stored ZIP
2. **Discover** — app finds the H6047 via UDP multicast or hotspot scan
3. **Navigate** — swipe left/right through arc scenes; each scene fires the light effect, Spotify playlist, and ambient loop automatically
4. **Trigger** — tap trigger buttons to fire one-shot sounds and light flashes
5. **Mix** — three sliders: Spotify volume, ambient volume, trigger volume

## Light effects

| Effect | Description |
|---|---|
| **Police Siren** | Red / blue per-segment rotation |
| **Emergency Alarm** | Orange per-segment rotating beacon |
| **Techno Club** | Hot pink & neon green strobe |
| **Flickering Light** | Organic damaged fluorescent |
| **Disian Encounter** | Deep purple sine-wave pulse with cold white flashes |
| **Off** | Turns the bar off cleanly |

Burst/flash overlays (white, orange, purple) can be assigned to trigger buttons and fire on top of the current scene effect.

## Scene transitions

On scene change, the ambient track fades out (400 ms), the new track starts at zero and fades in. Spotify switches context immediately (no SDK crossfade available).

## Discovery

Tries hotspot scan first (`getHotspotIp` via the WiFi channel), falls back to UDP multicast on 239.255.255.250:4001. Works on both regular Wi-Fi and phone hotspot — useful for events without a shared network.

## Audio

- **Ambient**: looping `audioplayers` player, software gain independent of system volume. Uses `AudioFocus.none` so Spotify is not interrupted.
- **Triggers**: pool of 6 `audioplayers` instances, round-robin. Same audio focus config.
- **Spotify**: controlled via Spotify App Remote SDK (local Android module). Volume slider currently uses `AudioManager.setStreamVolume`; Web API decoupling is planned.

## Build

Requirements: Flutter 3.41+, Android SDK 36, Java 21.

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Per-segment control

The H6047 has 10 physical segments — 5 per bar — addressed via bitmask in `ptReal` LAN commands:

```dart
const _leftMask  = 0x01F;  // segments 0-4
const _rightMask = 0x3E0;  // segments 5-9
```

Swap if bars feel reversed.
