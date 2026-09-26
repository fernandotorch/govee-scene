# Task: Trigger buttons must not get huge on wide (desktop) windows

In `lib/main.dart`, find the trigger grid in the `SessionPerformanceScreen` build method (`GridView.builder`). Its delegate is currently `SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 1.8)`.

Replace it with:
```dart
SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 220,
  crossAxisSpacing: 16,
  mainAxisSpacing: 16,
  childAspectRatio: 1.8,
)
```
On a phone (about 390 dp wide) this still gives 2 columns. A wide desktop window gets as many columns as fit.

Change nothing else. Do not touch `android/`. Do not commit.

Verify:
- `flutter analyze`: no new issues.
- `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` must succeed.
