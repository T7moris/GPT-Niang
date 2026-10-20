import AppKit
import CoreAudio
import GPTNiangCore
#if !MUSIC_INTEGRATION_STANDALONE
import XCTest
@testable import GPTNiangMac
#endif

private final class FakeMusicAudio: MusicAudioSource {
    let callback: (String,String?) -> Void
    var starts = 0, stops = 0, value = MusicCaptureSnapshot()
    init(_ callback: @escaping (String,String?) -> Void) { self.callback = callback }
    func start() { starts += 1; callback("running",nil) }
    func stop() { stops += 1 }
    func snapshot() -> MusicCaptureSnapshot { value }
}

@MainActor enum MusicIntegrationChecks {
    static func run(_ expect: (Bool,String) -> Void) async {
        _ = NSApplication.shared
        var sources: [FakeMusicAudio] = []
        let music = MusicController { callback in
            let source = FakeMusicAudio(callback); sources.append(source); return source
        }
        expect(!music.enabled && sources.isEmpty,"startup never requests audio without opt-in")
        music.setEnabled(true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(music.running && sources.count == 1 && sources[0].starts == 1,"enable starts one capture")
        let layout = CompanionLayout(characterScale: 0.8,bubbleScale: 0.8,musicAccessories: true)
        let visible = CGRect(x: 0,y: 0,width: 208,height: 208)
        let area = CGRect(x: 1728,y: 0,width: 1280,height: 800)
        let normal = WidgetPlacement.frame(host: area,visibleScreen: area,size: layout.size,x: 1,y: 0)
        var within = true
        for i in 0..<300 {
            let now = 100+Double(i)/60
            var audio = MusicAudioFrame(); audio.locked = true; audio.period = 0.5
            audio.time = now; audio.nextBeat = floor(now/0.5+1)*0.5; audio.level = 0.02
            sources[0].value = MusicCaptureSnapshot(audio: audio,capturedAt: now,receivedAt: now)
            let frame = music.frame(normal: normal,area: area,layout: layout,visibleRect: visible,now: now,paused: false)
            within = within && area.insetBy(dx: -0.001,dy: -0.001).contains(frame)
        }
        expect(within && music.bpm == 120,"animated panel remains in validated host")
        music.pause(now: 200)
        let moved = area.offsetBy(dx: -3000,dy: 350)
        let after = music.frame(normal: normal.offsetBy(dx: -3000,dy: 350),area: moved,layout: layout,visibleRect: visible,now: 200.01,paused: true)
        expect(moved.insetBy(dx: -0.001,dy: -0.001).contains(after),"Space/display changes cannot replay old absolute positions")
        music.setEnabled(false)
        sources[0].callback("running",nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(!music.enabled && !music.running && music.pose == MusicPose() && sources[0].stops == 1,"stop releases capture and ignores stale success")
        expect(music.frame(normal: normal,area: area,layout: layout,visibleRect: visible,now: 201,paused: false) == normal,"disable restores original position")
        music.setEnabled(true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        music.sleep()
        expect(music.enabled && !music.running && sources[1].stops == 1,"sleep releases tap while retaining session intent")
        music.wake()
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(sources.count == 3 && music.running,"wake creates fresh capture and beat clock")
        sources[2].callback("failed","test failure")
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(!music.enabled && !music.running && music.error == "test failure" && sources[2].stops == 1,"capture failure cleans up and exposes retry state")
        let unavailable = MusicController { _ in nil }
        unavailable.setEnabled(true)
        expect(!unavailable.enabled && !unavailable.running,"unsupported OS leaves ordinary widget working")

        var stereo: [Float] = [0.1,-0.2,0.3,-0.4]
        stereo.withUnsafeMutableBytes { data in
            var list = AudioBufferList(mNumberBuffers: 1,mBuffers: AudioBuffer(mNumberChannels: 2,mDataByteSize: UInt32(data.count),mData: data.baseAddress))
            let decoded = MusicPCM.interleavedFloat32(&list,channels: 2)
            expect(decoded == [0.1,-0.2,0.3,-0.4],"interleaved Core Audio PCM")
            list.mBuffers.mData = nil
            expect(MusicPCM.interleavedFloat32(&list,channels: 2) == [0,0,0,0],"disabled buffer decodes as silence")
            expect(MusicPCM.interleavedFloat32(&list,channels: 1).isEmpty,"malformed channel count rejected")
        }
        var left: [Float] = [0.1,0.3], right: [Float] = [-0.2,-0.4]
        left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r in
            let memory = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size+MemoryLayout<AudioBuffer>.stride,
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            let pointer = memory.assumingMemoryBound(to: AudioBufferList.self)
            pointer.pointee.mNumberBuffers = 2
            let list = UnsafeMutableAudioBufferListPointer(pointer)
            list.unsafeMutablePointer.pointee.mNumberBuffers = 2
            list[0] = AudioBuffer(mNumberChannels: 1,mDataByteSize: UInt32(l.count),mData: l.baseAddress)
            list[1] = AudioBuffer(mNumberChannels: 1,mDataByteSize: UInt32(r.count),mData: r.baseAddress)
            expect(MusicPCM.interleavedFloat32(list.unsafeMutablePointer,channels: 2) == [0.1,-0.2,0.3,-0.4],"planar Core Audio PCM interleaves correctly")
        } }
    }
}
#if MUSIC_INTEGRATION_STANDALONE
@main struct MusicIntegrationRunner {
    @MainActor static func main() async {
        var count = 0, failures = 0
        await MusicIntegrationChecks.run { result, message in
            count += 1; if !result { failures += 1; print("FAIL: "+message) }
        }
        print("Music integration: \(count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#else
final class MusicIntegrationTests: XCTestCase {
    @MainActor func testCaptureLifecyclePCMAndPlacement() async {
        await MusicIntegrationChecks.run { XCTAssertTrue($0,$1) }
    }
}
#endif
