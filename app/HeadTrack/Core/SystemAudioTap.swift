import AudioToolbox
import CoreAudio
import Foundation
import os

enum TapError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case let .coreAudio(what, status): "\(what) failed (OSStatus \(status))"
        case let .unsupportedFormat(why): "Unsupported tap format: \(why)"
        }
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw TapError.coreAudio(what, status) }
}

/// Captures everything the Mac is playing (except this app) through a Core
/// Audio process tap (macOS 14.2+) and writes it into a ring buffer.
///
/// The original output is muted while the tap is running, so you hear only the
/// spatialised version. `mutedWhenTapped` means sound returns automatically if
/// this app stops or crashes.
final class SystemAudioTap {
    let ring: StereoRingBuffer
    private(set) var sampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "headtrack.tap", qos: .userInteractive)
    private let log = Logger(subsystem: "com.yusufk.headtrack", category: "tap")

    // Scratch for de-interleaving in the IOProc (allocated once).
    private let scratchCapacity = 8192
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>

    init(ring: StereoRingBuffer) {
        self.ring = ring
        scratchL = .allocate(capacity: scratchCapacity)
        scratchR = .allocate(capacity: scratchCapacity)
    }

    deinit {
        stop()
        scratchL.deallocate()
        scratchR.deallocate()
    }

    var isRunning: Bool { ioProcID != nil }

    func start() throws {
        guard !isRunning else { return }
        do {
            try createTap()
            try createAggregate()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Setup

    private func createTap() throws {
        let ownProcess = try Self.processObjectID(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.name = "HeadTrack"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")
        tapUUID = description.uuid

        // Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Read tap format")
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            throw TapError.unsupportedFormat("expected Float32 PCM, got \(asbd)")
        }
        sampleRate = asbd.mSampleRate
        log.info("Tap format: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch")
    }

    private var tapUUID = UUID()

    private func createAggregate() throws {
        let outputUID = try Self.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HeadTrack Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "Create aggregate device")
    }

    private func startIO() throws {
        let ring = ring
        let sL = scratchL, sR = scratchR, cap = scratchCapacity

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count > 0 else { return }

            if buffers.count >= 2 {
                // Non-interleaved: one buffer per channel.
                guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                ring.write(left: l, right: r, frames: frames)
            } else {
                // Interleaved (or mono) in a single buffer.
                let b = buffers[0]
                guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { return }
                let channels = max(1, Int(b.mNumberChannels))
                let frames = min(cap, Int(b.mDataByteSize) / MemoryLayout<Float>.size / channels)
                for i in 0..<frames {
                    sL[i] = data[i * channels]
                    sR[i] = data[i * channels + (channels > 1 ? 1 : 0)]
                }
                ring.write(left: sL, right: sR, frames: frames)
            }
        }, "Create IOProc")

        try check(AudioDeviceStart(aggregateID, ioProcID), "Start capture")
    }

    // MARK: Helpers

    static func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID),
                  "Find own audio process")
        return objectID
    }

    static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size, &deviceID), "Find default output")
        return deviceID
    }

    static func defaultOutputDeviceUID() throws -> String {
        try deviceString(defaultOutputDeviceID(), kAudioDevicePropertyDeviceUID)
    }

    static func defaultOutputDeviceName() -> String {
        (try? deviceString(defaultOutputDeviceID(), kAudioObjectPropertyName)) ?? "Unknown output"
    }

    private static func deviceString(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value), "Read device property")
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}
