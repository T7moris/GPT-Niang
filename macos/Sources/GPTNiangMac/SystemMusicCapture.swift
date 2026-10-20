import AppKit
import CoreAudio
import AudioToolbox
import GPTNiangCore

struct MusicCaptureSnapshot {
    var audio = MusicAudioFrame()
    var capturedAt = 0.0
    var receivedAt = 0.0
}

protocol MusicAudioSource: AnyObject {
    func start()
    func stop()
    func snapshot() -> MusicCaptureSnapshot
}

/// A private, unmuted Core Audio tap. It never changes the user's default output
/// and never requests a microphone. Its only output is the derived beat state.
@available(macOS 14.2, *)
final class SystemMusicCapture: MusicAudioSource {
    private let control = DispatchQueue(label: "GPTNiang.music.capture")
    private let audioQueue = DispatchQueue(label: "GPTNiang.music.analysis", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = MusicCaptureSnapshot()
    private var tap: AudioObjectID = 0, device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var stopped = false
    private let onState: (String, String?) -> Void

    init(onState: @escaping (String, String?) -> Void) { self.onState = onState }
    func snapshot() -> MusicCaptureSnapshot { lock.lock(); defer { lock.unlock() }; return latest }
    func start() {
        control.async { [self] in
            guard !stopped else { return }
            do {
                try open()
                var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    guard let self, !self.stopped else { return }
                    self.close()
                    do { try self.open() } catch { self.close(); self.onState("failed",error.localizedDescription) }
                }
                outputListener = listener
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,control,listener)
            } catch { close(); onState("failed",error.localizedDescription) }
        }
    }
    func stop() {
        control.async { [self] in
            stopped = true
            if let outputListener {
                var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,control,outputListener)
                self.outputListener = nil
            }
            close()
        }
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,mScope: kAudioObjectPropertyScopeGlobal,mElement: kAudioObjectPropertyElementMain)
    }
    private struct CaptureError: LocalizedError {
        let operation: String
        let code: OSStatus
        var errorDescription: String? { "\(operation)（\(code)）。请检查「系统音频录制」权限，或重试。" }
    }
    private func check(_ code: OSStatus, _ operation: String) throws {
        if code != noErr { throw CaptureError(operation: operation,code: code) }
    }
    private func open() throws {
        onState("starting",nil)
        var pid = getpid(), process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,UInt32(MemoryLayout<pid_t>.size),&pid,&size,&process)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: process == 0 ? [] : [process])
        description.name = "GPT 娘音乐律动"; description.uuid = UUID()
        description.isPrivate = true; description.muteBehavior = .unmuted
        if #available(macOS 26.0, *) { description.bundleIDs = [Bundle.main.bundleIdentifier ?? "io.github.t7moris.GPTNiangMac"] }
        try check(AudioHardwareCreateProcessTap(description,&tap),"无法建立系统音频采集")
        var tapUID: CFString = "" as CFString
        address = Self.address(kAudioTapPropertyUID); size = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(tap,&address,0,nil,&size,pointer)
        }
        try check(uidStatus,"无法读取音频采集标识")
        var format = AudioStreamBasicDescription()
        address = Self.address(kAudioTapPropertyFormat); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap,&address,0,nil,&size,&format),"无法读取系统音频格式")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, (8000...384000).contains(format.mSampleRate),
              (1...32).contains(format.mChannelsPerFrame) else {
            throw CaptureError(operation: "暂不支持当前输出设备的音频格式",code: kAudioHardwareUnsupportedOperationError)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GPT 娘音乐律动",
            kAudioAggregateDeviceUIDKey: "GPTNiang.music."+UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            // Do not block AudioDeviceStart waiting for music to begin.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID as String,
                                               kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary,&device),"无法建立音频分析设备")
        let channels = Int(format.mChannelsPerFrame), rate = format.mSampleRate
        var detector = MusicBeatDetector(sampleRate: rate,channels: channels), lastPacket = 0.0, lastPublish = 0.0
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc,device,audioQueue) { [weak self] _, input, timestamp, _, _ in
            guard let self else { return }
            let samples = MusicPCM.interleavedFloat32(input,channels: channels)
            guard !samples.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if lastPacket > 0 && now-lastPacket > 0.25 { detector = MusicBeatDetector(sampleRate: rate,channels: channels) }
            lastPacket = now
            detector.push(interleaved: samples)
            guard now-lastPublish >= 1/60.0 else { return }
            lastPublish = now
            var capturedAt = now
            if timestamp.pointee.mFlags.contains(.hostTimeValid) {
                let host = Double(AudioConvertHostTimeToNanos(timestamp.pointee.mHostTime))/1e9 + Double(samples.count/channels)/rate
                if abs(host-now) < 2 { capturedAt = host }
            }
            let snapshot = MusicCaptureSnapshot(audio: detector.frame,capturedAt: capturedAt,receivedAt: now)
            self.lock.lock(); self.latest = snapshot; self.lock.unlock()
        },"无法连接音频分析回调")
        try check(AudioDeviceStart(device,ioProc),"无法开始系统音频采集")
        onState("running",nil)
    }
    private func close() {
        if device != 0 {
            if let ioProc { AudioDeviceStop(device,ioProc); AudioDeviceDestroyIOProcID(device,ioProc) }
            ioProc = nil
            AudioHardwareDestroyAggregateDevice(device); device = 0
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        lock.lock(); latest = MusicCaptureSnapshot(); lock.unlock()
    }
}

enum MusicPCM {
    /// Handles both planar and interleaved float32, including disabled buffers.
    static func interleavedFloat32(_ list: UnsafePointer<AudioBufferList>, channels: Int) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard channels > 0, channels <= 32, !buffers.isEmpty else { return [] }
        var frames = Int.max, actualChannels = 0
        for buffer in buffers where buffer.mNumberChannels > 0 {
            frames = min(frames,Int(buffer.mDataByteSize)/MemoryLayout<Float>.size/Int(buffer.mNumberChannels))
            actualChannels += Int(buffer.mNumberChannels)
        }
        guard actualChannels == channels, frames > 0, frames <= 32768 else { return [] }
        var samples = [Float](repeating: 0,count: frames*channels), channel = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<frames {
                    for c in 0..<count { samples[f*channels+channel+c] = data[f*count+c] }
                }
            }
            channel += count
        }
        return samples
    }
}
