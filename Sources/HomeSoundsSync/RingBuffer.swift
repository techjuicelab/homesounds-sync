import Foundation
import Synchronization

/// Single-producer / multi-consumer interleaved-stereo history buffer.
///
/// The capture (tap) IOProc is the sole producer. Any number of `DelayReader`s
/// (one per local output device) read from it independently, each a chosen
/// number of frames behind the newest write. Readers never consume: the buffer
/// is a rolling window of the last `capacityFrames` of audio, addressed by
/// absolute frame index. A slow or late reader can only read stale audio — it
/// can never corrupt the producer or another reader, because every reader's read
/// window sits strictly behind the write head (delay < capacity, by design), so
/// the producer's current write cell is never one a reader is touching.
final class DelayRingBuffer {
    let channels = 2
    let capacityFrames: Int

    /// Sample storage (L,R,L,R …). Producer overwrites the oldest cells; readers
    /// only read cells behind the write head. Same-module visibility lets
    /// `DelayReader` read directly without copying.
    let storage: UnsafeMutablePointer<Float>
    let storageCount: Int

    /// Absolute count of frames written so far (monotonically increasing).
    /// Published with release ordering so consumers see the audio data first.
    let writeFrame = Atomic<Int64>(0)

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        self.storageCount = capacityFrames * 2
        self.storage = .allocate(capacity: storageCount)
        self.storage.initialize(repeating: 0, count: storageCount)
    }

    deinit { storage.deallocate() }

    /// Newest absolute frame index written by the producer. Used to detect
    /// whether capture is actually flowing (e.g. audio-recording permission).
    var framesWritten: Int64 { writeFrame.load(ordering: .acquiring) }

    /// Producer: append `frames` interleaved-stereo samples (L,R,L,R …).
    func write(interleaved src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let w = writeFrame.load(ordering: .relaxed)
        var idx = Int(w % Int64(capacityFrames))
        var consumed = 0
        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - idx)
            (storage + idx * 2).update(from: src + consumed * 2, count: chunk * 2)
            idx += chunk
            if idx == capacityFrames { idx = 0 }
            consumed += chunk
            remaining -= chunk
        }
        writeFrame.store(w + Int64(frames), ordering: .releasing)
    }
}

/// One independent delayed read cursor into a `DelayRingBuffer`.
///
/// Each local output device owns exactly one reader and reads it only from its
/// own render callback (single consumer per reader), so the cursor state needs
/// no locking beyond the atomic resync flag the UI sets when that output's delay
/// changes. Multiple readers can share one buffer at different delays — that is
/// what lets several local speakers each line up with the AirPlay group on their
/// own offset.
final class DelayReader {
    private let ring: DelayRingBuffer

    /// Set on the main thread when this reader's delay changes; the consumer
    /// re-primes so the new delay takes effect immediately instead of drifting in.
    private let resyncRequested = Atomic<Bool>(false)

    /// Consumer-owned read cursor (absolute frame index). Render-thread only.
    private var readFrame: Int64 = 0
    private var primed = false
    /// Snapshot of the write head from the previous render, used to tell a
    /// resumed producer ("advanced") apart from a frozen one ("underrun").
    private var lastW: Int64 = 0

    init(ring: DelayRingBuffer) { self.ring = ring }

    /// Capacity of the shared buffer; callers clamp their delay below this so the
    /// read window can never reach the producer's write region.
    var capacityFrames: Int { ring.capacityFrames }

    /// Ask the consumer to re-establish the delay window on its next render
    /// (called when this output's delay value changes so it applies right away).
    func requestResync() { resyncRequested.store(true, ordering: .releasing) }

    /// Consumer: render `frames` interleaved-stereo samples that are `delayFrames`
    /// behind the newest write. Emits silence until enough audio has accumulated.
    ///
    /// Correctness guarantees (unchanged from the single-reader design — each
    /// reader is independent):
    /// - The effective delay is floored to one render block, so the read window
    ///   `[readFrame, readFrame+frames)` always sits behind the write head — a
    ///   delay of 0 (or any sub-block value) can never silence the output.
    /// - Resync is forward-only: if the consumer falls behind (or the producer
    ///   jumps ahead) by more than `resyncThreshold`, the cursor skips forward to
    ///   re-establish the delay. It is never snapped backward during steady play
    ///   (which would replay a loop).
    /// - On a producer underrun (write head frozen, e.g. Music quit) the cursor
    ///   rides past the write head into clean silence; the delay is re-established
    ///   ONLY once the producer is observed advancing again, so a frozen producer
    ///   can never trigger a replay loop.
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int, delayFrames: Int, resyncThreshold: Int) {
        if resyncRequested.exchange(false, ordering: .acquiringAndReleasing) {
            primed = false
        }

        let cap = Int64(ring.capacityFrames)
        let w = ring.writeFrame.load(ordering: .acquiring)
        let producerAdvanced = w > lastW
        lastW = w
        let safeDelay = max(Int64(delayFrames), Int64(frames))   // never less than one block
        let target = w - safeDelay

        if !primed {
            guard target > 0 else {
                dst.update(repeating: 0, count: frames * 2)
                return
            }
            readFrame = target
            primed = true
        } else if readFrame >= w {
            // Underrun region: re-establish the delay only if the producer is
            // alive and moving. If it is frozen, hold position (silence) rather
            // than snapping backward to old audio — that prevents a replay loop.
            if producerAdvanced && target > 0 {
                readFrame = target
            }
        } else {
            // Steady play: forward-only correction if we fell too far behind.
            let drift = target - readFrame
            if drift > Int64(resyncThreshold) {
                readFrame = target
            }
        }

        let storage = ring.storage
        for f in 0..<frames {
            let rf = readFrame + Int64(f)
            if rf < 0 || rf >= w {
                dst[f * 2] = 0
                dst[f * 2 + 1] = 0
            } else {
                let idx = Int(rf % cap)
                dst[f * 2] = storage[idx * 2]
                dst[f * 2 + 1] = storage[idx * 2 + 1]
            }
        }
        readFrame += Int64(frames)
    }

    /// Called when this output stops so the next start re-primes the delay window.
    func resetPrime() {
        primed = false
        readFrame = 0
        lastW = 0
    }
}
