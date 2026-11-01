# Head-Tracked Audio (working title)

Planning space for an app that makes audio on ordinary headphones behave like
audio in a real room: when you turn your head, the sound stays where it was.

## The idea

On headphones the whole sound stage is glued to your skull. Turn left and the
"speakers" turn with you, so nothing ever sounds like it is in front of you.
Real speakers don't do that. Your brain uses tiny changes as you move your head
to work out where a sound is, and headphones take that cue away.

The app tracks where your head is pointing and counter-rotates the sound field
so the sources stay fixed in the room.

## Files

- `research.md`: what exists, what the platforms allow, the technical pieces
- `plan.md`: proposed approach, phases, open questions

## Status

Research done, direction decided (2026-11): macOS menu bar app, any system
audio, webcam head tracking, wired and Bluetooth headphones, desk use.

- Phase 0a (browser prototype): built into Viki, `~/Development/web_graphics`,
  branch `feature/spatial-audio`.
- Phase 1 (Mac app): `app/`. Menu bar app "HeadTrack" (working title).

## Mac app

```bash
cd app
make run    # generate Xcode project (XcodeGen), build, launch
make test   # unit tests, incl. offline HRTF direction checks
```

Pipeline: Core Audio process tap (all system audio, original muted while
tapped) -> lock-free ring buffer -> AVAudioEngine with two HRTF sources in an
AVAudioEnvironmentNode -> headphones. Head pose from Vision face rectangles.

Known unknowns: Vision's yaw sign on a real face (use "Flip direction" if the
radar arrow turns the wrong way), pitch sign (pitch off by default).
