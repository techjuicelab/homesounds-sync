import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

/// Plays the delayed copy of Music's audio to a chosen output device (e.g. the
/// EDIFIER M60) via an AUHAL output unit. Its render callback pulls samples from
/// the ring buffer `delayFrames` behind the live write head.
final class OutputRenderer {

    enum OutputError: Error, CustomStringConvertible {
        case noComponent
        case instantiate(OSStatus)
        case enableIO(OSStatus)
        case setDevice(OSStatus)
        case setFormat(OSStatus)
        case setCallback(OSStatus)
        case initialize(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .noComponent:        return "HAL 출력 컴포넌트를 찾을 수 없습니다."
            case .instantiate(let s): return "출력 유닛 생성 실패 (\(s))."
            case .enableIO(let s):    return "출력 IO 활성화 실패 (\(s))."
            case .setDevice(let s):   return "출력 장치 설정 실패 (\(s))."
            case .setFormat(let s):   return "출력 포맷 설정 실패 (\(s))."
            case .setCallback(let s): return "렌더 콜백 설정 실패 (\(s))."
            case .initialize(let s):  return "출력 유닛 초기화 실패 (\(s))."
            case .startFailed(let s): return "출력 시작 실패 (\(s))."
            }
        }
    }

    /// This output's own delayed read cursor into the shared capture buffer.
    /// Independent of every other output, so each local speaker lines up with the
    /// AirPlay group on its own offset.
    private let reader: DelayReader
    let delayFrames = Atomic<Int64>(0)

    /// Software volume for the local (EDIFIER) output, 0…1.5 (×1000, atomic).
    private let gainMilli = Atomic<Int>(1000)
    func setGain(_ g: Double) { gainMilli.store(Int(max(0, min(1.5, g)) * 1000), ordering: .releasing) }

    /// Invoked on the main queue if the bound output device disappears mid-playback.
    var onDeviceLost: (() -> Void)?

    private var unit: AudioUnit?
    private(set) var inputSampleRate: Double = 48000
    private(set) var resyncThreshold: Int = 12000

    private var listenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?

    // Diagnostics (render thread, throttled ~1/s).
    private var dbgAccum = 0
    private var dbgPeak: Float = 0

    init(ring: DelayRingBuffer) {
        self.reader = DelayReader(ring: ring)
    }

    func setDelayMs(_ ms: Double) {
        let frames = Int64(ms / 1000.0 * inputSampleRate)
        // Defend the buffer invariant regardless of caller, capture rate, or a
        // restored value: keep the read window strictly inside the buffer so it
        // can never alias the producer's write region (which would play garbage).
        let margin = Int64(resyncThreshold) + Int64(inputSampleRate * 0.1)
        let maxFrames = max(0, Int64(reader.capacityFrames) - margin)
        delayFrames.store(min(max(0, frames), maxFrames), ordering: .releasing)
        reader.requestResync()   // apply the new delay on the next render
    }

    func start(deviceID: AudioObjectID, inputSampleRate: Double, delayMs: Double) throws {
        self.inputSampleRate = inputSampleRate
        self.resyncThreshold = Int(inputSampleRate * 0.25) // 250 ms drift budget

        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &acd) else { throw OutputError.noComponent }

        var newUnit: AudioUnit?
        let instStatus = AudioComponentInstanceNew(component, &newUnit)
        guard instStatus == noErr, let unit = newUnit else { throw OutputError.instantiate(instStatus) }

        // Operate on the local `unit`; publish to self.unit only after a clean start
        // so any failure path can dispose it instead of leaking a HAL handle.
        do {
            var enableOutput: UInt32 = 1
            var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                              &enableOutput, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw OutputError.enableIO(status) }

            var disableInput: UInt32 = 0
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                          &disableInput, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw OutputError.enableIO(status) }

            var device = deviceID
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { throw OutputError.setDevice(status) }

            var asbd = AudioStreamBasicDescription(
                mSampleRate: inputSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0)
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                          &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            guard status == noErr else { throw OutputError.setFormat(status) }

            var callback = AURenderCallbackStruct(
                inputProc: renderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                          &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw OutputError.setCallback(status) }

            status = AudioUnitInitialize(unit)
            guard status == noErr else { throw OutputError.initialize(status) }

            // Configure the delay BEFORE the render callback can fire, so the first
            // callback never primes the ring at zero delay.
            setDelayMs(delayMs)

            status = AudioOutputUnitStart(unit)
            guard status == noErr else { throw OutputError.startFailed(status) }
        } catch {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }

        self.unit = unit
        installDeviceAliveListener(deviceID: deviceID)
    }

    func stop() {
        removeDeviceAliveListener()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        reader.resetPrime()
    }

    // MARK: - Device-loss detection

    private func installDeviceAliveListener(deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            var alive: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let st = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &alive)
            if st != noErr || alive == 0 {
                self.onDeviceLost?()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        if status == noErr {
            listenerDeviceID = deviceID
            deviceAliveListener = listener
        }
    }

    private func removeDeviceAliveListener() {
        guard let listener = deviceAliveListener, listenerDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(listenerDeviceID, &address, DispatchQueue.main, listener)
        deviceAliveListener = nil
        listenerDeviceID = kAudioObjectUnknown
    }

    fileprivate func render(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frames: Int) {
        guard let ioData else { return }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard list.count > 0, let data = list[0].mData else { return }
        let dst = data.assumingMemoryBound(to: Float.self)
        let delay = Int(delayFrames.load(ordering: .acquiring))
        reader.read(into: dst, frames: frames, delayFrames: delay, resyncThreshold: resyncThreshold)

        // Apply the local-output (EDIFIER) volume.
        let gain = Float(gainMilli.load(ordering: .acquiring)) / 1000.0
        if gain != 1.0 {
            let n = frames * 2
            for i in 0..<n {
                var v = dst[i] * gain
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                dst[i] = v
            }
        }

        var peak: Float = 0
        let n = frames * 2
        for i in 0..<n { let a = abs(dst[i]); if a > peak { peak = a } }
        dbgAccum += frames
        if peak > dbgPeak { dbgPeak = peak }
        if dbgAccum >= Int(inputSampleRate) {
            DBG.log("[HSS] output rendering: ~\(dbgAccum) frames/s, peak=\(String(format: "%.4f", dbgPeak)), delay=\(delay)")
            dbgAccum = 0
            dbgPeak = 0
        }
    }
}

/// C render callback bridged to `OutputRenderer.render`. Must capture nothing.
private func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let renderer = Unmanaged<OutputRenderer>.fromOpaque(inRefCon).takeUnretainedValue()
    renderer.render(ioData, frames: Int(inNumberFrames))
    return noErr
}
