import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

/// Decides when the live waveform's audio capture runs.
///
/// Rules:
/// 1. Capture runs only when the waveform is switched on, music is playing, and the notch is visible.
/// 2. It listens only to the music app's process, never to all system audio.
/// 3. Start and stop are debounced (0.4 s / 1.5 s), so a quick pause-and-play never restarts it.
/// 4. `update` is idempotent: calling it again with the same answer does nothing.
/// 5. After three failed starts it gives up until something actually changes. No retry loops.
/// 6. Turning the setting off stops capture immediately, with no delay.
@Observable @MainActor
final class Waveform {
    nonisolated static let bandCount = 9

    private(set) var levels: [Float] = Array(repeating: 0, count: Waveform.bandCount)
    private(set) var active = false
    private(set) var lastError: String?

    @ObservationIgnored private let tap = ProcessTap()
    @ObservationIgnored private var runningPID: pid_t?
    @ObservationIgnored private var pendingTarget: pid_t??
    @ObservationIgnored private var pendingWork: DispatchWorkItem?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastFailedTarget: pid_t?
    @ObservationIgnored private var outputListenerInstalled = false

    func level(_ index: Int, of count: Int) -> Float {
        guard count > 0 else { return 0 }
        let band = min(Self.bandCount - 1, index * Self.bandCount / count)
        return levels[band]
    }

    func update(enabled: Bool, playing: Bool, visible: Bool, pid: pid_t?) {
        let target: pid_t? = (enabled && playing && visible) ? pid : nil

        if !enabled, runningPID != nil {
            cancelPending()
            apply(nil) // switched off: stop right now
            return
        }
        if target == runningPID { cancelPending(); return }
        if let pending = pendingTarget, pending == target { return } // already scheduled
        if target != nil, target == lastFailedTarget, failures >= 3 { return }

        cancelPending()
        pendingTarget = .some(target)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingTarget = nil
                self?.apply(target)
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (target == nil ? 1.5 : 0.4), execute: work)
    }

    func shutdown() {
        cancelPending()
        apply(nil)
    }

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
        pendingTarget = nil
    }

    private func apply(_ target: pid_t?) {
        guard target != runningPID else { return }
        if runningPID != nil {
            tap.stop()
            runningPID = nil
            active = false
            levels = Array(repeating: 0, count: Self.bandCount)
        }
        guard let pid = target else { return }

        if lastFailedTarget != pid { failures = 0 }
        installOutputListener()
        tap.onLevels = { [weak self] lv in
            DispatchQueue.main.async { self?.levels = lv }
        }
        do {
            try tap.start(pid: pid)
            runningPID = pid
            active = true
            failures = 0
            lastFailedTarget = nil
            lastError = nil
        } catch {
            tap.stop()
            failures += 1
            lastFailedTarget = pid
            lastError = error.localizedDescription
            Log.waveform.error("Capture failed (\(self.failures)/3): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// When the output device changes (e.g. AirPods connect) rebuild the capture once.
    private func installOutputListener() {
        guard !outputListenerInstalled else { return }
        outputListenerInstalled = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let pid = self.runningPID else { return }
                self.apply(nil)
                self.apply(pid)
            }
        }
    }
}

enum Log {
    static let waveform = Logger(subsystem: "com.pergola.Pergola", category: "waveform")
    static let notch = Logger(subsystem: "com.pergola.Pergola", category: "notch")
    static let media = Logger(subsystem: "com.pergola.Pergola", category: "media")
}

struct TapError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (\(status))" }
}

/// A Core Audio process tap on a single app, feeding a small spectrum analyzer.
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.pergola.tap", qos: .userInteractive)
    var onLevels: (([Float]) -> Void)?

    func start(pid: pid_t) throws {
        let process = try Self.processObject(for: pid)

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "Pergola Waveform"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError(step: "Creating the audio tap", status: status) }
        tapID = tap

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pergola Waveform",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { throw TapError(step: "Creating the capture device", status: status) }
        aggregateID = agg

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)

        let analyzer = SpectrumAnalyzer(bands: Waveform.bandCount, sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000)
        let emit = onLevels
        var lastEmit = DispatchTime.now().uptimeNanoseconds
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, _, _ in
            guard let levels = analyzer.process(input) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastEmit > 16_000_000 { // ~60 fps
                lastEmit = now
                emit?(levels)
            }
        }
        guard status == noErr, let proc else { throw TapError(step: "Creating the audio callback", status: status) }
        ioProc = proc

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { throw TapError(step: "Starting capture", status: status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            throw TapError(step: "Finding the music app's audio", status: status)
        }
        return object
    }

    private static func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw TapError(step: "Finding the output device", status: status) }

        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError(step: "Reading the output device", status: status) }
        return uid.takeRetainedValue() as String
    }
}

/// Turns raw samples into a handful of smoothed, log-spaced frequency bands (0...1).
final class SpectrumAnalyzer {
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window: [Float]
    private var buffer: [Float] = []
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var smoothed: [Float]
    private let bands: Int
    private let sampleRate: Double

    init(bands: Int, sampleRate: Double) {
        self.bands = bands
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM))
        real = [Float](repeating: 0, count: 512)
        imag = [Float](repeating: 0, count: 512)
        mags = [Float](repeating: 0, count: 512)
        smoothed = [Float](repeating: 0, count: bands)
        buffer.reserveCapacity(4096)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ input: UnsafePointer<AudioBufferList>) -> [Float]? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return nil }
        let channels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            var s: Float = 0
            for c in 0..<channels { s += samples[i * channels + c] }
            buffer.append(s / Float(channels))
        }
        guard buffer.count >= n else { return nil }
        let frame = Array(buffer.suffix(n))
        buffer.removeAll(keepingCapacity: true)

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        let binHz = Float(sampleRate) / Float(n)
        for b in 0..<bands {
            let lo = 50 * powf(240, Float(b) / Float(bands))       // 50 Hz ... 12 kHz
            let hi = 50 * powf(240, Float(b + 1) / Float(bands))
            let i0 = max(1, Int(lo / binHz))
            let i1 = max(i0 + 1, min(n / 2, Int(hi / binHz)))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i]) }
            let db = 20 * log10f(peak / Float(n) + 1e-9)
            // Higher bands carry less energy; lift them so the bars look balanced.
            let lifted = db + Float(b) * 2.2
            let value = min(1, max(0, (lifted + 58) / 48))
            smoothed[b] = value > smoothed[b] ? value * 0.7 + smoothed[b] * 0.3 : smoothed[b] * 0.8 + value * 0.2
        }
        return smoothed
    }
}
