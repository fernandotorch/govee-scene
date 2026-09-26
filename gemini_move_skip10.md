# Task: Move the +10 s control into the Spotify mixer row and drop the top transport row

The `+10 s` button was placed next to the master pause at the top of the scene screen. It belongs
with the other music transport controls in the Live Mixer's Spotify row, next to pause and skip.
The top transport row goes away entirely.

One file: `lib/main.dart`. Four edits. No Kotlin changes — `spotifySeekRelative` stays exactly
as it is.

---

## Edit 1 — delete the top transport row

In `build`, find and delete this entire `Row` (it sits directly above
`const Divider(color: Colors.white12),` and the trigger grid):

```dart
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 32),
                  color: _isPaused ? const Color(0xFF63B8DE) : Colors.white54,
                  tooltip: _isPaused ? 'Resume' : 'Pause',
                  onPressed: _togglePause,
                ),
                const SizedBox(width: 24),
                IconButton(
                  icon: const Icon(Icons.forward_10, size: 32),
                  color: Colors.white54,
                  tooltip: 'Skip music forward 10 s',
                  onPressed: _skipForward,
                ),
              ],
            ),
```

Keep the `const Divider(color: Colors.white12),` that follows it.

## Edit 2 — add +10 s to the Spotify row

In the Live Mixer, find the Spotify row's pause and skip buttons:

```dart
                  IconButton(
                    icon: Icon(
                      _spotifyPaused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                    ),
                    color: _spotifyPaused ? const Color(0xFF63B8DE) : Colors.grey,
                    onPressed: _toggleSpotify,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 20),
                    color: Colors.grey,
                    onPressed: () => _wifiChannel.invokeMethod('spotifySkip'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
```

Insert a third `IconButton` **between** the pause and the skip, so the order reads
pause → +10 s → next track:

```dart
                  IconButton(
                    icon: Icon(
                      _spotifyPaused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                    ),
                    color: _spotifyPaused ? const Color(0xFF63B8DE) : Colors.grey,
                    onPressed: _toggleSpotify,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.forward_10, size: 20),
                    color: Colors.grey,
                    onPressed: _skipForward,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 20),
                    color: Colors.grey,
                    onPressed: () => _wifiChannel.invokeMethod('spotifySkip'),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
```

## Edit 3 — remove the now-dead master pause

Nothing calls `_togglePause` any more, and `_isPaused` is no longer read. Leaving them produces
new analyzer warnings, so remove both.

Delete the whole method:

```dart
  void _togglePause() {
    setState(() => _isPaused = !_isPaused);
    if (_isPaused) {
      _runner.stop();
      _audio.pauseAmbient();
      _wifiChannel.invokeMethod('spotifyPause', null).catchError((_) {});
    } else {
      _runner.setByRef(widget.pack.scenes[_currentIndex].goveeRef);
      _audio.resumeAmbient();
      _wifiChannel.invokeMethod('spotifyResume', null).catchError((_) {});
    }
  }
```

Delete the field declaration:

```dart
  bool _isPaused = false;
```

And in `_enterScene`, delete the line that assigns it:

```dart
    _isPaused = false;
```

so the method now begins:

```dart
    void _enterScene(int index) {
    // _activeDucks deliberately survives the scene change: a trigger that is
    // still playing must keep the new scene's bed ducked until it finishes.
    final scene = widget.pack.scenes[index];
```

Keep the odd indentation of the `void _enterScene(int index) {` line as it is.

## Edit 4 — leave `_skipForward` where it is

`_skipForward` and `_spotifyNudgeMs` stay exactly as written. Only the button that calls
`_skipForward` moved.

---

## What must NOT change

- `_toggleSpotify`, and the Spotify pause/skip behaviour.
- `_skipForward`, `_spotifyNudgeMs`, and the `spotifySeekRelative` handler in `MainActivity.kt`.
- All ambient-duck code: `_duckAmbientFor`, `_activeDucks`, `_ambientDuckFactor`, `_rampAmbient`,
  `_performAmbientTransition`, the `AudioEngine` constructor.
- `_audio.pauseAmbient()` / `resumeAmbient()` in `AudioEngine` — those methods stay defined even
  though `_togglePause` was their only caller. Do not delete them.
- The ambient and trigger volume sliders, the trigger grid, scene navigation.

## How to sanity-check after building

1. The top of the scene screen no longer has a pause or a +10 s button; the trigger grid sits
   directly under the divider.
2. The Live Mixer's Spotify row reads: ♪ Spotify … pause ▸ +10 ▸ skip.
3. +10 s still nudges the track forward, repeatably.
4. Spotify pause/resume and skip still work from that row.
