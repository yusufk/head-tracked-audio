# HeadTrack

Head-tracked spatial audio for **any headphones** on macOS.

On headphones, sound is glued to your head: turn left and the whole mix turns
with you. HeadTrack uses your Mac's camera to follow your head and keeps the
sound anchored to the screen, the way real speakers behave. It works on
everything your Mac plays: music, YouTube, films, calls.

- Works with ordinary wired or Bluetooth headphones (no motion sensors needed)
- Tracks left/right turns and up/down tilt from the webcam
- Everything runs on your Mac: camera frames are analysed in memory and never
  stored or sent anywhere, audio never leaves the machine
- Lives in the menu bar; switch it off and your audio is untouched

## Install

```bash
brew tap yusufk/tap
brew install --cask headtrack
```

Or download the DMG from [Releases](https://github.com/yusufk/head-tracked-audio/releases),
drag HeadTrack to Applications, then run once (the app isn't notarised):

```bash
xattr -cr /Applications/HeadTrack.app
```

Requires macOS 15 (Sequoia) or later. On first use macOS asks for **camera**
and **system audio recording** permission.

## Use

1. Put on headphones.
2. Click the head-with-headset icon in the menu bar and switch HeadTrack on.
3. Play something and turn your head: the sound stays at the screen.
4. Hold **Compare** to hear ordinary headphone sound; let go to switch back.

Tips: wired headphones have the lowest delay. On Bluetooth, try
**Prediction > Auto**. If the radar turns the wrong way, use the **Flip**
toggles. Press **C** to recentre.

## How it works

```
Core Audio process tap (all system audio, original muted while tapped)
  -> lock-free ring buffer (~20 ms)
  -> AVAudioEngine: L/R as two HRTF sources in an AVAudioEnvironmentNode
  -> headphones
Camera -> Vision face detection + landmarks -> One Euro filter -> listener orientation
```

Up/down comes from facial landmarks (where the nose tip sits between the eyes
and mouth), because Vision's own pitch value turned out to follow left/right
turns on a real face.

Design notes and research: [docs/plan.md](docs/plan.md), [docs/research.md](docs/research.md).
Browser prototype: [yusufk/ai_mirror](https://github.com/yusufk/ai_mirror) (`feature/spatial-audio`).

## Build from source

```bash
brew install xcodegen
cd app
make run    # generate the Xcode project, build, launch
make test   # unit tests, including measured HRTF direction checks
make dmg    # universal, ad-hoc signed DMG
```

Releases are built by GitHub Actions when a `v*` tag is pushed.

## Licence

GPL-3.0 with an attribution requirement: see [LICENSE](LICENSE) and
[NOTICE](NOTICE). Copyright (C) 2026 Yusuf Kaka.
