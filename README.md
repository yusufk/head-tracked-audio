# HeadTrack

[![Release](https://img.shields.io/github/v/release/yusufk/head-tracked-audio)](https://github.com/yusufk/head-tracked-audio/releases/latest)
[![Licence: GPL-3.0](https://img.shields.io/badge/licence-GPL--3.0-blue)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-lightgrey)
![Apple Silicon and Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-lightgrey)

**Head-tracked spatial audio for any headphones on macOS, using your webcam.**

On headphones, sound is glued to your head: turn left and the whole mix turns
with you, so nothing ever sounds like it's really in the room. HeadTrack
follows your head with the Mac's camera and keeps the sound anchored to the
screen, the way real speakers behave. It works on everything your Mac plays:
music, YouTube, films, calls.

AirPods and a few other headphones already do this, using motion sensors
built into the earbuds. HeadTrack brings it to the headphones you already
own, wired or Bluetooth.

## Features

- **Any headphones.** No motion sensors needed; the webcam does the tracking.
- **Any audio.** Captures everything the Mac plays, system-wide.
- **Left/right and up/down.** Turn or tilt your head and the sound stays put.
- **Instant comparison.** Hold *Compare* to hear ordinary headphone sound.
- **Private.** Camera frames are analysed in memory and never stored or sent
  anywhere. Audio never leaves your Mac.
- **Out of the way.** Lives in the menu bar. Switch it off and your audio
  and camera are untouched.

## Install

With [Homebrew](https://brew.sh):

```bash
brew tap yusufk/tap
brew install --cask headtrack
```

Or download the DMG from [Releases](https://github.com/yusufk/head-tracked-audio/releases/latest),
drag HeadTrack to Applications, then run this once (the app isn't notarised,
and this clears macOS's "damaged app" warning):

```bash
xattr -cr /Applications/HeadTrack.app
```

**Requirements:** macOS 15 (Sequoia) or later, a camera facing you, and
headphones. On first use macOS asks for **camera** and **screen & system
audio recording** permission.

## Use

1. Put on headphones.
2. Click the head-with-headset icon in the menu bar and switch HeadTrack on.
3. Play something and turn your head: the sound stays at the screen.
4. Hold **Compare** to hear normal headphone sound; let go to switch back.

The panel shows two radars, one from above (left/right) and one from the
side (up/down), so you can see exactly what the camera is tracking.

| Control | What it does |
|---|---|
| Speaker width | How far apart the two virtual speakers are |
| Room | How much room echo surrounds the sound |
| Prediction | Looks ahead to hide delay; *Auto* matches the measured lag |
| Use pitch | Include up/down head movement |
| Flip left/right, Flip up/down | Fix the direction if a radar turns the wrong way |
| Recentre (C) | Treat where you're looking now as straight ahead |

## Tips and troubleshooting

- **Wired headphones give the best result.** Bluetooth adds 150 to 250 ms of
  delay on its own; try *Prediction > Auto*.
- **Turn properly to test.** At 30° the speaker on that side ends up straight
  in front of you. Small glances only shift the sound slightly, just like real
  speakers.
- **Good light on your face** helps the camera track you.
- **No sound or no capture?** Check *System Settings > Privacy & Security >
  Screen & System Audio Recording* and *Camera*. After updating, macOS may ask
  for these permissions again.
- **Tracking feels slow?** The panel shows updates per second and latency.
  On a 2018 Intel MacBook Pro tracking runs at about 24 updates a second with
  roughly 95 ms from head movement to tracked result.

## How it works

```
Core Audio process tap (all system audio, original muted while tapped)
  -> lock-free ring buffer (~20 ms)
  -> AVAudioEngine: L/R as two HRTF sources in an AVAudioEnvironmentNode
  -> headphones

Camera -> Vision face detection (left/right, every frame)
       -> Vision landmarks on a second worker (up/down, ~8 Hz)
       -> One Euro filter + optional prediction
       -> listener orientation
```

Some findings from building it, measured on real hardware rather than assumed:

- Apple's `AVAudio3DAngularOrientation` yaw turns the listener the opposite way
  to what you'd expect, so the listener is oriented with forward/up vectors
  instead. Unit tests render a tone offline and check which ear it reaches.
- Vision's face pitch follows left/right turns on a real face, so up/down is
  taken from where the nose sits between the eyes and mouth.
- A fresh `VNImageRequestHandler` per frame is about 3x faster than
  `VNSequenceRequestHandler` for this workload.

Design notes and research: [docs/plan.md](docs/plan.md), [docs/research.md](docs/research.md).
The idea was first prototyped in the browser in
[yusufk/ai_mirror](https://github.com/yusufk/ai_mirror) (`feature/spatial-audio`).

## Build from source

```bash
brew install xcodegen
cd app
make run    # generate the Xcode project, build, launch
make test   # unit tests, including measured HRTF direction checks
make dmg    # universal, ad-hoc signed DMG
```

Releases are built by GitHub Actions when a `v*` tag is pushed.

## Contributing

Issues and pull requests are welcome. Improvements to tracking accuracy,
personalised HRTFs and multichannel (5.1/Atmos-style) input would be
especially interesting.

## Licence

GPL-3.0 with an attribution requirement: see [LICENSE](LICENSE) and
[NOTICE](NOTICE). If you distribute HeadTrack or a modified version, please
credit "HeadTrack by Yusuf Kaka". Copyright (C) 2026 Yusuf Kaka.
