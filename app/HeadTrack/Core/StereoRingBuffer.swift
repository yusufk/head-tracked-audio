import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring of interleaved stereo
/// Float frames. Producer: the Core Audio tap IOProc. Consumer: the
/// AVAudioEngine render thread. Neither side blocks or allocates.
final class StereoRingBuffer: @unchecked Sendable {
    let capacity: Int // frames, power of two
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0) // total frames ever written
    private let readIndex = Atomic<Int>(0)  // total frames ever read

    /// Keep at most this many frames queued. Anything older is skipped so
    /// latency can't creep up if the two clocks drift.
    var maxLatencyFrames: Int

    init(capacityFrames: Int = 16384, maxLatencyFrames: Int = 1024) {
        var cap = 1
        while cap < capacityFrames { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        self.maxLatencyFrames = maxLatencyFrames
        storage = .allocate(capacity: cap * 2)
        storage.initialize(repeating: 0, count: cap * 2)
    }

    deinit { storage.deallocate() }

    var availableFrames: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    /// Producer: append frames from separate L/R channel pointers. Never
    /// blocks: if the consumer stalls, old frames are overwritten and the
    /// consumer skips past them on its next read.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let n = min(frames, capacity)
        for i in 0..<n {
            let slot = ((w + i) & mask) * 2
            storage[slot] = left[i]
            storage[slot + 1] = right[i]
        }
        writeIndex.store(w + n, ordering: .releasing)
    }

    /// Consumer: fill `frames` of L/R. Returns frames of real audio delivered
    /// (the rest is zero-filled on underrun).
    @discardableResult
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)

        // Skip backlog beyond the latency budget (and anything overwritten).
        let budget = max(frames, maxLatencyFrames)
        if w - r > budget { r = w - budget }

        let n = min(frames, w - r)
        for i in 0..<n {
            let slot = ((r + i) & mask) * 2
            left[i] = storage[slot]
            right[i] = storage[slot + 1]
        }
        for i in n..<frames {
            left[i] = 0
            right[i] = 0
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }
}
