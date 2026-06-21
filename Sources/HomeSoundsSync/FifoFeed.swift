import Foundation
import Synchronization

/// Streams captured audio (real-time, no delay) to OwnTone via a named FIFO as
/// interleaved PCM16. OwnTone reads the pipe and AirPlays it to the HomePod.
///
/// The local EDIFIER leg (delayed) is handled separately by OutputRenderer; this
/// path feeds the HomePod leg. Float32 → Int16 conversion only (OwnTone is
/// configured for pipe_sample_rate=48000, pipe_bits_per_sample=16).
final class FifoFeed {

    private let path: String
    private let capacity: Int                    // Int16 samples (interleaved)
    private let storage: UnsafeMutablePointer<Int16>
    private let writeIndex = Atomic<Int64>(0)    // producer = capture IOProc
    private var readIndex: Int64 = 0             // writer-thread owned

    private var thread: Thread?
    private let runningFlag = Atomic<Bool>(false)
    private let chunkFrames = 512

    init(path: String, seconds: Double = 2.0, sampleRate: Int = 48000) {
        self.path = path
        self.capacity = Int(Double(sampleRate) * seconds) * 2
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Producer (capture IOProc): convert interleaved Float32 → Int16 and enqueue.
    func feed(interleaved src: UnsafePointer<Float>, frames: Int) {
        let n = frames * 2
        guard n > 0 else { return }
        let w = writeIndex.load(ordering: .relaxed)
        for i in 0..<n {
            var v = src[i]
            if v > 1 { v = 1 } else if v < -1 { v = -1 }
            storage[Int((w + Int64(i)) % Int64(capacity))] = Int16(v * 32767)
        }
        writeIndex.store(w + Int64(n), ordering: .releasing)
    }

    func start() {
        guard !runningFlag.load(ordering: .acquiring) else { return }
        runningFlag.store(true, ordering: .releasing)
        readIndex = writeIndex.load(ordering: .acquiring)
        let t = Thread { [weak self] in self?.writerLoop() }
        t.name = "com.techjuice.homesoundssync.fifo"
        t.stackSize = 1 << 20
        t.start()
        thread = t
    }

    func stop() {
        runningFlag.store(false, ordering: .releasing)
        thread = nil
    }

    // MARK: - Writer thread

    private func writerLoop() {
        let chunkSamples = chunkFrames * 2
        // Cap how far behind the live write head we ever fall, so latency to the
        // HomePod stays bounded (≈ OwnTone's AirPlay buffer) and never grows.
        let maxBacklog = Int64(48000 / 4 * 2)   // ~250 ms of stereo samples
        var chunk = [Int16](repeating: 0, count: chunkSamples)
        var fd: Int32 = -1

        while runningFlag.load(ordering: .acquiring) {
            if fd < 0 {
                // Blocks until OwnTone has the read end open (it watches the pipe).
                fd = open(path, O_WRONLY)
                if fd < 0 { usleep(200_000); continue }
            }

            let w = writeIndex.load(ordering: .acquiring)
            // If we've fallen behind (jitter), skip forward to the live edge so the
            // pipe stays real-time instead of accumulating delay.
            if w - readIndex > maxBacklog {
                readIndex = w - maxBacklog
            }
            if w - readIndex >= Int64(chunkSamples) {
                for i in 0..<chunkSamples {
                    chunk[i] = storage[Int((readIndex + Int64(i)) % Int64(capacity))]
                }
                readIndex += Int64(chunkSamples)
                // Blocking write back-pressures to OwnTone's read rate. We do NOT
                // inject silence on underrun — that would permanently push the
                // HomePod timeline later (latency leak). Brief gaps are absorbed by
                // OwnTone's own buffer; a real stop just stalls the pipe harmlessly.
                if !writeAll(fd, chunk) { close(fd); fd = -1 }
            } else {
                usleep(2000)   // wait for capture to produce more
            }
        }

        if fd >= 0 { close(fd) }
    }

    private func writeAll(_ fd: Int32, _ samples: [Int16]) -> Bool {
        return samples.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            let count = raw.count
            while off < count {
                let n = write(fd, base + off, count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { usleep(1000); continue }
                    return false   // EPIPE etc. → caller reopens
                }
                off += n
            }
            return true
        }
    }
}
