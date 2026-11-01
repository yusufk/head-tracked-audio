# Plan

## Decisions (2026-11)

| Question | Decision |
|---|---|
| Audio source | **Any audio** on the machine (system-wide) |
| Platform | **macOS app** first |
| Use case | **Screen as a window**: the sound stays anchored to the screen/room while you turn your head. Trigger example: a beach video that sounds flat because the waves turn with your head. |
| Tracking | **Webcam face tracking**, same idea as Viki ([yusufk/ai_mirror](https://github.com/yusufk/ai_mirror)) |
| Headphones | **Wired and Bluetooth** |
| Setting | **Desk** |

## What "realistic" will and won't mean for the beach video

A phone video's audio is stereo (Pixel 7) or mono. It holds left/right
information only, with nothing about what is behind or above you. So the app
turns that stereo into **two virtual speakers either side of the screen**.

- Turn your head left: the waves move to your right ear, as if the screen is
  a window onto the beach. That is the realism win, and it is the same model
  Apple uses for video on AirPods.
- It will **not** put waves behind you. That would need a spatial recording
  (ambisonics, or iPhone 16+ "Spatial Audio" video capture). Ambisonic input
  can come later, because rotating a sound field is actually easier than
  rotating virtual speakers.

## Reusing Viki

Viki (`web_graphics/js/face-tracker.js`) uses the legacy MediaPipe FaceMesh and
estimates yaw from nose-to-cheek distances, scaled by an arbitrary `* 5`.
Good enough to wobble particles, not for audio. Audio needs **real angles
in degrees**: 30° of head turn must move the virtual speakers by exactly 30°.

- Prototype (browser): swap to MediaPipe **Face Landmarker** with
  `outputFacialTransformationMatrixes: true`, then pull yaw/pitch/roll from the
  4x4 matrix. Reuse Viki's camera setup, smoothing and debug panel.
- Mac app (native): Apple **Vision** `VNDetectFaceRectanglesRequest`
  (revision 3, macOS 12+) returns continuous yaw/pitch/roll. On-device, no
  dependencies, no web view. Fall back to landmark maths if its precision
  disappoints (to verify in Phase 0b).

## Bluetooth: the honest bit

Normal Bluetooth headphones add 150-250 ms of output latency, which sits right
inside the head-turn to sound-moves loop (comfort limit is ~60-80 ms). Plan:

1. **AirPods / Beats**: use their own motion sensor via
   `CMHeadphoneMotionManager` (macOS 14+) rather than the camera, and turn off
   macOS's own spatial audio so the effect isn't applied twice.
2. **Other Bluetooth**: camera tracking + **motion prediction** (extrapolate
   yaw from angular velocity by the measured output latency). Read real device
   latency from Core Audio (`kAudioDevicePropertyLatency` + safety offset +
   stream latency) and show it in the UI.
3. If it still swims, offer a "gentle" mode: smaller rotation range and slower
   follow, which hides lag far better than full 1:1 tracking.

## Architecture (Mac)

```
HeadPoseSource (protocol)  -> yaw/pitch/roll + timestamp, recentre()
  ├─ CameraHeadPose      AVCaptureSession 30-60 fps -> Vision
  └─ AirPodsHeadPose     CMHeadphoneMotionManager
          │
          v  PosePredictor (latency compensation, smoothing, drift-to-centre)
          │
SystemAudioTap  ── Core Audio process tap (macOS 14.2+), original output muted
          │
          v
SpatialRenderer ── AVAudioEngine + AVAudioEnvironmentNode (HRTFHQ)
                   L/R as virtual speakers at ±30°, listenerAngularOrientation = -yaw
          │
          v
Headphones (selected output device)
```

App shape: menu bar app (like ZoomacIt), with an on/off toggle, recentre
hotkey, "speaker width" and "room" (reverb/dry-wet) sliders, tracking source
picker, and a live latency + yaw readout. Camera frames are processed in
memory and never stored.

## Phases

### Phase 0a: Browser proof of feel (one evening)
- Fork the Viki tracker into `prototype/`.
- Load the beach video into the page, route its audio through Web Audio:
  split L/R into two `PannerNode`s (HRTF) at ±30°, rotate the listener by
  head yaw.
- A/B toggle (tracked vs plain stereo) to judge whether it's worth it.
- Test wired first, then Bluetooth, to feel the latency difference.

### Phase 0b: Native spikes (Swift command-line, throwaway)
1. Vision head pose: print yaw at 30/60 fps, check it's continuous and smooth.
2. Process tap: capture system audio, mute the original, play it back
   unchanged. Measure added latency. Check what Netflix/Spotify (DRM) do.
3. `AVAudioEnvironmentNode`: two virtual speakers rotating with a slider.

### Phase 1: Mac MVP
Wire the three spikes together behind the architecture above. Distribute via
the existing Homebrew tap (`yusufk/tap`).

### Phase 2: Polish
AirPods motion source, motion prediction, presets (music / movie / call),
5.1/7.1 input, ambisonic input, auto-recentre.

### Later
DIY ESP32 + BNO085 clip-on tracker (full 360°, no camera), iOS player app.

## Open questions

- Sandboxing / App Store: process taps plus camera may push this to
  direct distribution (Homebrew + notarisation) rather than the Mac App Store.
- Name.
