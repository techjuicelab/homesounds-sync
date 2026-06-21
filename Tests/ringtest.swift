import Foundation

// Standalone simulation of DelayRingBuffer (compiled together with RingBuffer.swift).
// Producer writes a stereo ramp where each frame's value == its absolute index,
// so we can read back exactly which input frame each output sample came from.

let cap = 96000 * 12
let ring = DelayRingBuffer(capacityFrames: cap)
let reader = DelayReader(ring: ring)   // one local-output cursor
let block = 512
let threshold = 12000

var absWrite = 0
func produce(_ n: Int) {
    var buf = [Float](repeating: 0, count: n * 2)
    for i in 0..<n {
        let v = Float(absWrite + i)
        buf[i * 2] = v
        buf[i * 2 + 1] = v
    }
    buf.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: n) }
    absWrite += n
}

var scratch = [Float](repeating: 0, count: block * 2)
func render(delay: Int) -> [Float] {
    scratch.withUnsafeMutableBufferPointer {
        reader.read(into: $0.baseAddress!, frames: block, delayFrames: delay, resyncThreshold: threshold)
    }
    return (0..<block).map { scratch[$0 * 2] }
}

func isSilent(_ a: [Float]) -> Bool { a.allSatisfy { $0 == 0 } }
func contiguous(_ a: [Float]) -> Bool {
    for i in 1..<a.count where a[i] != a[i - 1] + 1 { return false }
    return true
}

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "✅ PASS" : "❌ FAIL") + "  " + name + (detail.isEmpty ? "" : "  — \(detail)"))
    if !cond { failures += 1 }
}

// ── Test A: steady delay 4096 frames ───────────────────────────────
produce(8192)
var lastA: [Float] = []
for _ in 0..<40 { produce(block); lastA = render(delay: 4096) }
check("A delay=4096 not silent", !isSilent(lastA))
check("A delay=4096 contiguous (no clicks)", contiguous(lastA))
let measuredDelayA = absWrite - 1 - Int(lastA.last!)
check("A measured delay ≈ 4096", abs(measuredDelayA - 4096) <= block,
      "measured=\(measuredDelayA)")

// ── Test B: delay 0 must NOT be silent (sub-block floor) ────────────
reader.resetPrime()
absWrite = 0
produce(8192)
var lastB: [Float] = []
for _ in 0..<20 { produce(block); lastB = render(delay: 0) }
check("B delay=0 not silent (floored to one block)", !isSilent(lastB))
check("B delay=0 contiguous", contiguous(lastB))
let measuredDelayB = absWrite - 1 - Int(lastB.last!)
// delay=0 should be near-live (0..one block of latency) but NEVER silent.
check("B delay=0 near-live, not silent", measuredDelayB >= 0 && measuredDelayB <= block,
      "measured=\(measuredDelayB)")

// ── Test C: producer underrun → silence, NOT a replay loop ──────────
reader.resetPrime()
absWrite = 0
produce(8192)
for _ in 0..<10 { produce(block); _ = render(delay: 4096) }
// Freeze the producer; keep rendering until the buffer drains.
var sawSilence = false
var renderedDuringStall: [[Float]] = []
for _ in 0..<60 {
    let o = render(delay: 4096)            // producer NOT advancing
    renderedDuringStall.append(o)
    if isSilent(o) { sawSilence = true }
}
check("C underrun eventually emits silence", sawSilence)
// No replay loop: once silent, it must stay silent while frozen (no old audio returns).
let tail = renderedDuringStall.suffix(20)
check("C no replay loop (stays silent once drained)", tail.allSatisfy { isSilent($0) })
let maxBeforeResume = absWrite - 1   // highest valid index produced so far

// ── Test D: producer resumes → fresh audio, delay re-established ────
var lastD: [Float] = []
for _ in 0..<40 { produce(block); lastD = render(delay: 4096) }
check("D resumes with audio", !isSilent(lastD))
check("D plays FRESH frames (not replayed old)", Int(lastD.first!) > maxBeforeResume,
      "first=\(Int(lastD.first!)) maxOld=\(maxBeforeResume)")
let measuredDelayD = absWrite - 1 - Int(lastD.last!)
check("D delay re-established ≈ 4096", abs(measuredDelayD - 4096) <= block,
      "measured=\(measuredDelayD)")

// ── Test E: delay change applies immediately (requestResync) ───────
reader.resetPrime()
absWrite = 0
produce(48000)
for _ in 0..<10 { produce(block); _ = render(delay: 4096) }
reader.requestResync()                    // simulate slider moving delay → 24000
produce(block)
let afterChange = render(delay: 24000)
let measuredDelayE = absWrite - 1 - Int(afterChange.last!)
check("E delay change applied immediately", abs(measuredDelayE - 24000) <= 2 * block,
      "measured=\(measuredDelayE)")

// ── Test F: two independent readers at different delays ────────────
// The whole point of the multi-reader split: several local speakers each
// line up on their OWN delay from one shared capture buffer.
reader.resetPrime()
let reader2 = DelayReader(ring: ring)
absWrite = 0
produce(48000)
func renderWith(_ rd: DelayReader, delay: Int) -> [Float] {
    var s = [Float](repeating: 0, count: block * 2)
    s.withUnsafeMutableBufferPointer {
        rd.read(into: $0.baseAddress!, frames: block, delayFrames: delay, resyncThreshold: threshold)
    }
    return (0..<block).map { s[$0 * 2] }
}
var f1: [Float] = []
var f2: [Float] = []
for _ in 0..<60 { produce(block); f1 = renderWith(reader, delay: 4096); f2 = renderWith(reader2, delay: 12000) }
check("F reader1 contiguous", contiguous(f1))
check("F reader2 contiguous", contiguous(f2))
let dF1 = absWrite - 1 - Int(f1.last!)
let dF2 = absWrite - 1 - Int(f2.last!)
check("F reader1 delay ≈ 4096", abs(dF1 - 4096) <= block, "d1=\(dF1)")
check("F reader2 delay ≈ 12000", abs(dF2 - 12000) <= block, "d2=\(dF2)")
check("F readers independent (different positions)", Int(f1.last!) > Int(f2.last!),
      "r1=\(Int(f1.last!)) r2=\(Int(f2.last!))")

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
