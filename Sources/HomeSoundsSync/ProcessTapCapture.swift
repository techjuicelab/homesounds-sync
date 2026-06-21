import Foundation
import CoreAudio
import AppKit

/// Captures Apple Music's audio with a Core Audio process tap (macOS 14.4+),
/// converts it to interleaved-stereo float and pushes it into the ring buffer.
///
/// No virtual driver, no kext. The only system gate is the "System Audio
/// Recording" TCC consent prompt that appears the first time the tap aggregate
/// device starts (driven by NSAudioCaptureUsageDescription in Info.plist).
final class ProcessTapCapture {

    enum CaptureError: Error, CustomStringConvertible {
        case musicNotRunning
        case translateFailed(OSStatus)
        case createTapFailed(OSStatus)
        case formatFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case ioProcFailed(OSStatus)

        var description: String {
            switch self {
            case .musicNotRunning:        return "Apple Music이 실행 중이 아닙니다. Music을 먼저 실행하세요."
            case .translateFailed(let s): return "Music 오디오 객체를 찾지 못했습니다 (\(s))."
            case .createTapFailed(let s): return "오디오 탭 생성 실패 (\(s))."
            case .formatFailed(let s):    return "탭 포맷 조회 실패 (\(s))."
            case .aggregateFailed(let s): return "집합 장치 생성 실패 (\(s))."
            case .ioProcFailed(let s):    return "캡처 시작 실패 (\(s))."
            }
        }
    }

    private let ring: DelayRingBuffer
    private let fifo: FifoFeed?
    private(set) var sampleRate: Double = 48000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private let scratchFrames = 16384
    private let scratch: UnsafeMutablePointer<Float>

    // Diagnostics (consumed by the render-thread IOProc; throttled to ~1/s).
    private var dbgAccum = 0
    private var dbgPeak: Float = 0

    init(ring: DelayRingBuffer, fifo: FifoFeed?) {
        self.ring = ring
        self.fifo = fifo
        self.scratch = .allocate(capacity: scratchFrames * 2)
    }

    deinit { scratch.deallocate() }

    func start() throws {
        // Idempotency guard: never overwrite live IDs (would orphan a tap/aggregate).
        guard tapID == kAudioObjectUnknown, aggregateID == kAudioObjectUnknown else { return }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else {
            throw CaptureError.musicNotRunning
        }
        let pid = app.processIdentifier
        let processObject = try translate(pid: pid)
        DBG.log("[HSS] Music pid=\(pid) processObject=\(processObject)")

        // Everything below creates HAL resources; on any failure tear down what was
        // built so a retry starts clean and no system-wide tap/aggregate leaks.
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
            description.uuid = UUID()
            description.name = "HomeSoundsSync Tap"
            description.isPrivate = true
            // Mute Music's LOCAL render (so the Computer/EDIFIER leg doesn't double
            // with our delayed copy) while still capturing it. The AirPlay/HomePod
            // leg is a separate path and is expected to keep playing.
            description.muteBehavior = .muted

            var newTap = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
            DBG.log("[HSS] createProcessTap status=\(tapStatus) tapID=\(newTap)")
            guard tapStatus == noErr else { throw CaptureError.createTapFailed(tapStatus) }
            tapID = newTap

            let asbd = try tapFormat(newTap)
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            DBG.log("[HSS] tapFormat sr=\(asbd.mSampleRate) ch=\(channels) nonInterleaved=\(nonInterleaved) flags=\(String(format: "0x%x", asbd.mFormatFlags))")

            try createAggregate(tapUID: description.uuid.uuidString)
            DBG.log("[HSS] aggregate created aggID=\(aggregateID)")
            try startIOProc(channels: channels, nonInterleaved: nonInterleaved)
            DBG.log("[HSS] IOProc started — waiting for tapped frames…")
        } catch {
            DBG.log("[HSS] start FAILED: \(error)")
            stop()   // self-guarded: destroys whatever was created so far
            throw error
        }
    }

    func stop() {
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        dbgAccum = 0
        dbgPeak = 0
    }

    // MARK: - Diagnostics

    private func dbgTick(frames: Int, peak: Float) {
        dbgAccum += frames
        if peak > dbgPeak { dbgPeak = peak }
        if dbgAccum >= Int(sampleRate) {
            DBG.log("[HSS] capture flowing: ~\(dbgAccum) frames/s, peak=\(String(format: "%.4f", dbgPeak))")
            dbgAccum = 0
            dbgPeak = 0
        }
    }

    // MARK: - Setup helpers

    private func translate(pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidVar = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidVar) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), pidPtr,
                &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else {
            throw CaptureError.translateFailed(status)
        }
        return object
    }

    private func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == noErr else { throw CaptureError.formatFailed(status) }
        return asbd
    }

    private func createAggregate(tapUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HomeSoundsSync Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard status == noErr else { throw CaptureError.aggregateFailed(status) }
        aggregateID = newAggregate
    }

    private func startIOProc(channels: Int, nonInterleaved: Bool) throws {
        let ring = self.ring
        let fifo = self.fifo
        let scratch = self.scratch
        let scratchFrames = self.scratchFrames

        var proc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) {
            [weak self] (_, inInputData, _, _, _) in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard list.count > 0 else { return }

            var producedFrames = 0
            if nonInterleaved && list.count >= 2 {
                let left = list[0]
                let right = list[1]
                guard let lData = left.mData, let rData = right.mData else { return }
                let frames = min(Int(left.mDataByteSize) / MemoryLayout<Float>.size, scratchFrames)
                let l = lData.assumingMemoryBound(to: Float.self)
                let r = rData.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    scratch[i * 2] = l[i]
                    scratch[i * 2 + 1] = r[i]
                }
                ring.write(interleaved: scratch, frames: frames)
                producedFrames = frames
            } else {
                let buffer = list[0]
                guard let data = buffer.mData else { return }
                let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let frames = min(totalFloats / channels, scratchFrames)
                let src = data.assumingMemoryBound(to: Float.self)
                if channels >= 2 {
                    for i in 0..<frames {
                        scratch[i * 2] = src[i * channels]
                        scratch[i * 2 + 1] = src[i * channels + 1]
                    }
                } else {
                    for i in 0..<frames {
                        let v = src[i]
                        scratch[i * 2] = v
                        scratch[i * 2 + 1] = v
                    }
                }
                ring.write(interleaved: scratch, frames: frames)
                producedFrames = frames
            }

            if producedFrames > 0 {
                fifo?.feed(interleaved: scratch, frames: producedFrames)
            }
            if let self, producedFrames > 0 {
                var peak: Float = 0
                let n = producedFrames * 2
                for i in 0..<n { let a = abs(scratch[i]); if a > peak { peak = a } }
                self.dbgTick(frames: producedFrames, peak: peak)
            }
        }
        guard createStatus == noErr, let proc else { throw CaptureError.ioProcFailed(createStatus) }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else { throw CaptureError.ioProcFailed(startStatus) }
    }
}
