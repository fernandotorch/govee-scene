# Task: Linux window title "Govee Scene"

In `linux/runner/my_application.cc`, change both window title strings from `"govee_light_theater"` to `"Govee Scene"`: the `gtk_header_bar_set_title` call and the `gtk_window_set_title` call.

Change nothing else:
- Do NOT change `BINARY_NAME` or `APPLICATION_ID` in `linux/CMakeLists.txt`. The app ID decides where saved data lives (the Spotify login and session packs).
- Do NOT touch `lib/`, `android/` or any other file.
- Do not commit.

Verify: `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` must succeed.
