# Research

## 1. Reality check: this already exists, but only in walled gardens

Head-tracked spatial audio is already shipping. It is just locked to specific
hardware/software combinations:

| Ecosystem | Needs | Notes |
|---|---|---|
| Apple | AirPods Pro / Max / 3 / 4, Beats with sensors, on Apple devices | Works in supported apps, best with Atmos content. Stereo gets "spatialised" too. |
| Android 13+ | Phone with an OEM spatializer + headset with a head-tracking sensor | Pixel Buds Pro, Galaxy Buds, recent Sony. Uses the Android Head Tracker HID protocol. |
| Samsung | Galaxy phone + Galaxy Buds | "360 Audio" |
| Pro audio | APL Virtuoso + HeadTrek (camera, macOS), Waves Nx (discontinued 2021) | Aimed at mix engineers |

So the real gap is:

- **Ordinary headphones** (wired, cheap Bluetooth, studio cans) with no sensors.
- **Cross-ecosystem**: AirPods on Android/Windows, Sony on a Mac, etc.
- **Any audio source**, not just apps that opted into spatial audio.

Notable precedent: **Waves Nx** did almost exactly this idea (webcam head
tracking, any headphones, Mac/PC/iOS) and Waves discontinued the consumer app in
November 2021 ([Waves support](https://waves.com/support/tag/waves-nx)). Worth
understanding why. Likely: niche market, and Apple shipping it free with AirPods
in 2020. That is the main commercial risk for this project.

Hobby proof that it works: [MeharPro/Spatial-Head-Tracking-Audio](https://github.com/MeharPro/Spatial-Head-Tracking-Audio)
(webcam + Python, any wired headphones).

## 2. How it works (the three building blocks)

```
 [Head tracker] --yaw/pitch/roll--> [Renderer] <--audio-- [Audio source]
                                        |
                                   binaural stereo
                                        v
                                   [Headphones]
```

### 2a. Head tracking options

| Source | Hardware | API | Pros | Cons |
|---|---|---|---|---|
| Headphone IMU (Apple) | AirPods Pro/Max/3/4, Beats | `CMHeadphoneMotionManager` (iOS 14+, macOS 14+) | Accurate, low latency, works anywhere | Apple headphones only. Known yaw drift/recentre jumps ([forum](https://developer.apple.com/forums/thread/844940)). |
| Headphone IMU (Android) | Pixel Buds Pro, Galaxy Buds, Sony | Head Tracker HID sensor via Sensor framework, `Spatializer` API (Android 13+) | Standard protocol | Patchy OEM support. Sony data has been tapped on PC by hobbyists. |
| Front camera (face pose) | Any webcam / phone selfie camera | ARKit `ARFaceTrackingConfiguration` (TrueDepth), Apple Vision, MediaPipe Face Mesh (cross-platform) | Works with ANY headphones, zero extra hardware | Only works while facing the screen (roughly ±60-70°). Camera frame rate adds latency. Privacy perception. |
| Clip-on DIY IMU | ESP32/nRF + BNO085/BNO055 over BLE, ~R300 | Custom BLE GATT, or emulate Android Head Tracker HID | Any headphones, full 360°, cheap | Extra gadget to charge and clip on. Many open designs exist ([Teensy Head Tracker](https://github.com/notam02/Teensy-Head-Tracker), [nvsonic](https://github.com/trsonic/nvsonic-head-tracker)). |
| Phone IMU | Phone | CoreMotion / Sensor API | Free | Phone is not on your head. Only useful for "point phone" interactions, not real head tracking. |

### 2b. Rendering (binaural with HRTF)

Two standard approaches:

1. **Virtual speakers**: place stereo L/R at ±30° (or 5.1/7.1 speakers in a
   circle), convolve each with an HRTF for its direction, rotate the directions
   by minus head yaw. Simple, perfect for music and movies.
2. **Ambisonics**: encode everything into a sound field (first or higher order),
   apply a rotation matrix (very cheap), decode binaurally. Best for 360 content
   and many sources. This is how YouTube 360 and Resonance Audio work.

Libraries:

| Library | Licence | Notes |
|---|---|---|
| Apple `AVAudioEnvironmentNode` / PHASE | Built in | HRTF rendering, `listenerAngularOrientation` is literally the head-yaw knob. Easiest on Apple. |
| Web Audio `PannerNode` (`panningModel: "HRTF"`) | Built in to browsers | Good enough to prototype in an evening. |
| [Resonance Audio](https://github.com/anokta/resonance-audio) | Apache 2.0 | Google's, ambisonic based, C++ with Android/Unity/Web. |
| [Steam Audio](https://github.com/ValveSoftware/steam-audio) | Apache 2.0 | Valve's, HRTF + room effects, accepts custom SOFA HRTFs. |
| [libspatialaudio](https://github.com/videolan/libspatialaudio) | LGPL | VideoLAN's, used by VLC, ambisonics + binaural. |
| [google/obr](https://github.com/google/obr) | Apache 2.0 | Newer Google binaural renderer. |

HRTF data: generic datasets (SADIE II, CIPIC, KEMAR) in SOFA format. Personal
HRTFs give better externalisation, but a generic one plus head tracking already
fixes most front/back confusion, because the movement itself disambiguates.

### 2c. Getting the audio (the hard platform problem)

This is the part that decides the architecture more than anything else.

| Platform | Can I process OTHER apps' audio? |
|---|---|
| iOS | **No.** Sandbox forbids it. The app must be the player (local files, podcasts, streams it fetches itself). |
| macOS 14.2+ | **Yes**, via Core Audio process taps (`AudioHardwareCreateProcessTap`) with user permission ([AudioCap sample](https://github.com/insidegui/AudioCap)). Or a virtual output device (BlackHole style). DRM streams may come through silent (to verify). |
| Android 10+ | **Partly**, via `AudioPlaybackCapture` + MediaProjection. Apps can opt out and only media/game usage is capturable. Still need to play it back yourself, so the original must be muted. |
| Windows | **Yes**, WASAPI loopback or a virtual audio device / APO. |
| Browser | Only audio the page itself plays. |

## 3. Latency (the make-or-break number)

Research on head-tracker latency in virtual audio:

- Listeners generally cannot detect motion-to-sound latency below about
  **60-80 ms** with a single source (Brungart et al.). Thresholds are a little
  higher in complex scenes ([HAL](https://hal.science/hal-01433873v1)).
- Beyond ~100 ms the sound visibly "swims" after your head and the illusion breaks.

Budget for each path:

| Path | Tracker | Render buffer | Output | Total |
|---|---|---|---|---|
| Webcam + wired headphones | ~33 ms (30 fps) + ~10 ms inference | ~5-10 ms | ~5 ms | **~55-60 ms. OK.** |
| Webcam + Bluetooth headphones | same | same | **150-250 ms** (A2DP/AAC/SBC) | **Too slow.** |
| AirPods IMU + AirPods | low | render happens on phone/Mac | Bluetooth | Works only because Apple tunes the whole chain. |

Key insight: **for ordinary Bluetooth headphones, the rendering is done on the
host and then sent over a slow radio link, so Bluetooth latency lands directly
in the motion-to-sound loop.** Wired (or low-latency codec like aptX LL / LE
Audio LC3) headphones are the sweet spot for the "any headphones" promise.
Prediction (extrapolating head motion ~50-100 ms ahead from angular velocity)
can claw some of this back, as most VR systems do.

## 4. Other gotchas found

- **Recentering**: users need a "this is forward" button and automatic slow
  drift-back to centre, or after 20 minutes the vocalist is behind you.
- **Camera range**: face tracking loses you when you look away from the screen.
  Need graceful hold/ease-back, not a snap.
- **Stereo music** was never mixed for virtual speakers, so some people dislike
  it ("sounds like a room, not like my headphones"). Needs a wet/dry or "room
  size" control. Apple added a "Fixed" vs "Head Tracked" toggle for this reason.
- **Privacy**: a camera-on audio app needs a very clear "all on-device, no
  frames stored" story. Fits the privacy-first principle anyway.
