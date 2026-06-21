import Foundation
import CoreAudio

/// Ties capture (Music tap) → shared delay buffer → N local outputs together,
/// while the same captured audio is streamed in real time to OwnTone (which
/// AirPlays it to the HomePod group).
///
/// Topology:
///   ProcessTapCapture ──┬──► DelayRingBuffer ──► OutputRenderer (local #1, delay A)
///                       │                    └──► OutputRenderer (local #2, delay B) …
///                       └──► FifoFeed ──► OwnTone ──► AirPlay 2 group (the reference)
///
/// AirPlay 2 keeps the HomePods sample-synced with each other, so they form one
/// reference timeline (the latest, because of AirPlay buffering). Each local
/// output is held back by its OWN delay to line up with that reference, which is
/// why every local speaker gets an independent `OutputRenderer`/`DelayReader`.
final class SyncEngine {

    private let ring: DelayRingBuffer
    private let fifo: FifoFeed
    private let capture: ProcessTapCapture

    /// Live local outputs, keyed by Core Audio device UID.
    private var outputs: [String: OutputRenderer] = [:]

    private(set) var running = false

    /// Real-time PCM16 pipe to OwnTone (which AirPlays it to the HomePods).
    static let fifoPath = NSHomeDirectory() + "/owntone_data/media/homesync.pipe"

    /// Invoked on the main queue when the engine stops itself unexpectedly
    /// (e.g. Music quit). The String is a user-facing reason.
    var onStopped: ((String) -> Void)?

    /// Invoked on the main queue when a single local output's device disappears
    /// (unplugged). The String is that output's device UID, so the UI can uncheck
    /// just that row while the rest keep playing.
    var onOutputLost: ((String) -> Void)?

    init() {
        // Size for the WORST-CASE capture rate, not a fixed 48 kHz. The delay is
        // specified in ms and converted to frames at the runtime capture rate
        // (hi-res/lossless playback can report 96 or 192 kHz), so the buffer must
        // hold 20 s + margin at 192 kHz for the read window to always stay behind
        // the producer's write cell (delay < capacity by construction).
        // 24 s × 192 kHz ≈ 4.6 M frames (~37 MB) — trivial on a Mac. OutputRenderer
        // also clamps delay defensively against this capacity.
        ring = DelayRingBuffer(capacityFrames: 192_000 * 24)
        fifo = FifoFeed(path: SyncEngine.fifoPath)
        capture = ProcessTapCapture(ring: ring, fifo: fifo)
    }

    /// Newest captured frame count — lets the UI verify audio is actually flowing
    /// (e.g. detect a pending/denied system-audio-recording permission).
    var framesCaptured: Int64 { ring.framesWritten }

    /// Capture sample rate (valid after `start()`); local outputs render at this rate.
    var captureSampleRate: Double { capture.sampleRate }

    var activeOutputUIDs: [String] { Array(outputs.keys) }
    func hasOutput(uid: String) -> Bool { outputs[uid] != nil }

    /// Master start: bring up the capture tap and the AirPlay (FIFO) feed. Local
    /// outputs are attached separately via `addOutput`, so the engine can run with
    /// AirPlay only, local only, or both.
    func start() throws {
        guard !running else { return }
        fifo.start()
        do {
            try capture.start()
        } catch {
            fifo.stop()
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        for (_, r) in outputs { r.stop() }
        outputs.removeAll()
        capture.stop()
        fifo.stop()
        running = false
    }

    /// Attach a local output device while the engine is running. No-op if the
    /// engine is off or this UID is already attached. Throws if the output unit
    /// fails to start (the caller should surface it and leave the row unchecked).
    func addOutput(uid: String, deviceID: AudioObjectID, delayMs: Double, gain: Double) throws {
        guard running, outputs[uid] == nil else { return }
        let renderer = OutputRenderer(ring: ring)
        renderer.onDeviceLost = { [weak self] in self?.handleOutputLost(uid) }
        try renderer.start(deviceID: deviceID, inputSampleRate: capture.sampleRate, delayMs: delayMs)
        renderer.setGain(gain)
        outputs[uid] = renderer
    }

    func removeOutput(uid: String) {
        outputs[uid]?.stop()
        outputs[uid] = nil
    }

    func setDelay(uid: String, ms: Double) { outputs[uid]?.setDelayMs(ms) }
    func setGain(uid: String, g: Double) { outputs[uid]?.setGain(g) }

    private func handleOutputLost(_ uid: String) {
        guard outputs[uid] != nil else { return }
        removeOutput(uid: uid)
        onOutputLost?(uid)
    }
}
