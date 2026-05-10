# Task: Rename `arc` → `scenes` in lib/main.dart

The word "arc" was the old name for the list of scenes inside a session pack. Rename it to `scenes` throughout. Do NOT touch any `archive`/`Archive`/`ZipDecoder` references — those are a different library.

**File to edit:** `lib/main.dart`

## Changes

### 1. SessionPack field
Find:
```dart
  final List<SessionScene> arc;
```
Replace with:
```dart
  final List<SessionScene> scenes;
```

### 2. SessionPack constructor
Find:
```dart
  SessionPack({required this.name, required this.arc, required this.audioManifest, required this.directoryPath});
```
Replace with:
```dart
  SessionPack({required this.name, required this.scenes, required this.audioManifest, required this.directoryPath});
```

### 3. SessionPack.fromJson
Find:
```dart
      arc: (json['arc'] as List).map((s) => SessionScene.fromJson(s)).toList(),
```
Replace with:
```dart
      scenes: (json['scenes'] as List).map((s) => SessionScene.fromJson(s)).toList(),
```

### 4. All callsites — replace every occurrence of `pack.arc` with `pack.scenes` and every occurrence of `widget.pack.arc` with `widget.pack.scenes`. There are approximately 10 such references. Use replace_all.

### 5. Comment
Find:
```dart
            // Arc Nav
```
Replace with:
```dart
            // Scene Nav
```

## What must NOT change
- Anything referencing `archive`, `Archive`, `ZipDecoder`, `ArchiveFile` — those are the `archive` package, unrelated.
- All other code.

Run `flutter analyze` after the edits and fix any issues found.
