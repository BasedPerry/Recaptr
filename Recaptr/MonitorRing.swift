//
//  MonitorRing.swift
//  Recaptr
//
//  Lock-free ring that feeds the live monitor straight from the input
//  I/O cycle (~10 ms), bypassing the 100 ms tap blocks.
//

import Foundation
import Synchronization

/// Single producer, single consumer. Both ends run on real-time audio
/// threads, so neither may lock or allocate.
nonisolated final class MonitorRing: @unchecked Sendable {

    /// Frames of audio kept queued in steady state (~20 ms): enough to
    /// ride out the input and output I/O cycles landing out of step.
    static let targetFrames = 960
    /// Past this (~60 ms) the reader skips back to `targetFrames`, so
    /// the monitor can't drift behind when the input and output
    /// devices run on slightly different clocks.
    static let highWaterFrames = 2_880

    /// Capacity in frames (power of two). Stereo interleaved storage.
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>

    /// Total frames written and read. Their difference is the fill.
    private let writePos = Atomic<Int>(0)
    private let readPos = Atomic<Int>(0)

    /// Channel gain as Float bits, so the output thread reads it lock-free.
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)

    /// Diagnostics: skips (drift or backlog trimmed) and underruns.
    private let skipCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)

    // Reader state. Touched only by the output thread.
    private var primed = false

    init(capacityFrames: Int = 8_192) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c * 2)
        storage.initialize(repeating: 0, count: c * 2)
    }

    deinit { storage.deallocate() }

    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var skips: Int { skipCount.load(ordering: .relaxed) }
    var underruns: Int { underrunCount.load(ordering: .relaxed) }

    // MARK: Producer (input audio thread)

    /// Append `frames` from planar channels. A mono source (`right`
    /// nil) plays in both ears. When full, the newest audio is
    /// dropped; the reader's skip logic recovers.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        let w = writePos.load(ordering: .relaxed)
        let r = readPos.load(ordering: .acquiring)
        let n = min(frames, capacity - (w - r))
        guard n > 0 else { return }
        let rightSource = right ?? left
        for i in 0..<n {
            let idx = ((w + i) & mask) &* 2
            storage[idx] = left[i]
            storage[idx + 1] = rightSource[i]
        }
        writePos.store(w + n, ordering: .releasing)
    }

    // MARK: Consumer (output audio thread)

    /// Fill `frames` of planar stereo output, applying the gain.
    /// Returns false when nothing was played (silence).
    @discardableResult
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        let w = writePos.load(ordering: .acquiring)
        var r = readPos.load(ordering: .relaxed)
        var available = w - r

        // Too far behind (startup backlog, or clock drift piled up):
        // jump to the target fill.
        if available > Self.highWaterFrames {
            r = w - Self.targetFrames
            available = Self.targetFrames
            skipCount.add(1, ordering: .relaxed)
        }
        // After a start or an underrun, wait for a small cushion so
        // playback doesn't stutter on every I/O cycle.
        if !primed {
            guard available >= Self.targetFrames else {
                readPos.store(r, ordering: .releasing)
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
                return false
            }
            primed = true
        }

        let n = min(frames, available)
        let g = gain
        for i in 0..<n {
            let idx = ((r + i) & mask) &* 2
            left[i] = storage[idx] * g
            right[i] = storage[idx + 1] * g
        }
        if n < frames {
            left.advanced(by: n).update(repeating: 0, count: frames - n)
            right.advanced(by: n).update(repeating: 0, count: frames - n)
            primed = false
            underrunCount.add(1, ordering: .relaxed)
        }
        readPos.store(r + n, ordering: .releasing)
        return n > 0
    }

    /// Frames currently queued. Diagnostic.
    var fill: Int { writePos.load(ordering: .acquiring) - readPos.load(ordering: .acquiring) }
}
