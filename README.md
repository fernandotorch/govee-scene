# govee-scene

Android app for controlling Govee H6047 RGBIC gaming light bars during tabletop RPG sessions. Talks directly to the light bar over local Wi-Fi — no cloud, no laptop required during play.

Effects are designed in [govee-scene-web](https://github.com/fernandotorch/govee-scene-web) and ported here once finalised.

## Scenes

| Scene | Effect |
|---|---|
| **Police Siren** | Red / blue per-segment rotation |
| **Emergency Alarm** | Orange per-segment rotating beacon |
| **Techno Club** | Hot pink & neon green strobe |
| **Flickering Light** | Organic damaged fluorescent |
| **Disian Encounter** | Deep purple pulse with cold white intrusions |

## Build

Requirements: Flutter 3.41+, Android SDK 36, Java 21.

```bash
flutter build apk
adb push build/app/outputs/flutter-apk/app-release.apk /data/local/tmp/govee-scene.apk
adb shell pm install -r /data/local/tmp/govee-scene.apk
```

## How it works

On launch the app sends a UDP multicast discovery packet to 239.255.255.250:4001. The H6047 responds with its IP; from then on all commands go directly to the device on port 4003.

Per-segment colour control uses the `ptReal` command — base64-encoded 20-byte BLE packets sent over LAN. The H6047 has 10 physical segments (5 per bar), addressed via bitmask:

```dart
const _leftMask  = 0x01F;  // segments 0-4
const _rightMask = 0x3E0;  // segments 5-9
```

Swap these if the bars feel reversed.

## Adding a new scene

1. Add a loop method to `SceneRunner` in `lib/main.dart`
2. Add the scene to `_buildSceneList` with label, subtitle, and gradient colours
3. Build and install
