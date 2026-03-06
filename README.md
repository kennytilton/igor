# Igor Slept Here

Igor Slept Here is a **Dart/Flutter** application that aims to deliver an **MP4 slideshow on steroids**.

The repository also contains proof-of-concept (POC) work in shell scripts under `linux/` and `zsh/`, but for day-to-day development **`mpvgem/` is the beef**.

## Project layout

- `mpvgem/` — Flutter app + primary entry point for the project. See `mpvgem/README.md` for Flutter-specific notes.
- `linux/` — Linux POC utilities and prototypes.
- `zsh/` — Zsh POC utilities and prototypes.

## Quick start

> Requirements: Flutter SDK (Dart SDK >= 3.0). See `mpvgem/pubspec.yaml`.

```bash
cd mpvgem
flutter pub get
flutter run
```

## Build

Run from `mpvgem/`:

```bash
flutter build apk
# other targets as needed:
# flutter build ios|macos|windows|linux|web
```

## Notes

- The Flutter package name is `mpvgem` (see `mpvgem/pubspec.yaml`).
- `mpvgem` is described as "Igor playback engine for mpv" in `pubspec.yaml`.

## Status

Early-stage / evolving. POC scripts in `linux/` and `zsh/` may be folded into the Flutter app or retired over time.