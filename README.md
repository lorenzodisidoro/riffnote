# Riffnote

A macOS app for studying music by ear with waveform playback, loops, markers, speed controls, EQ, and spectrum analysis.

<a href="dist/Riffnote-Installer.pkg"><img src="https://img.shields.io/badge/Download-macOS%20Installer-blue?logo=apple" alt="Download the macOS installer"></a>

## Features

- Open audio files, seek on the waveform, and drag files into the app.
- Create, select, and rename loops; add and rename markers.
- Adjust playback speed and use track repeat.
- Shape bass, midrange, and treble with EQ; inspect the spectrum and piano keyboard.

## Run and build

Requires macOS 14 or later and Xcode with Swift 6.

```sh
swift run
bash scripts/build_installer.sh
```

The installer is saved to `dist/Riffnote-Installer.pkg`. It contains a universal build for Apple silicon and Intel. The package is not signed with an Apple Developer ID, so macOS may ask you to confirm opening it.
