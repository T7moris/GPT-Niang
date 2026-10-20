import Foundation
#if !MUSIC_STANDALONE
import XCTest
@testable import GPTNiangCore
#endif

enum MusicRhythmChecks {
    static func run(_ expect: (Bool, String) -> Void) {
        // The same beat-clock scenarios as upstream Windows tests.
        for bpm in [90.0,120,170] {
            let clock = MusicTempoTracker(), period = 60/bpm
            var main = 0, noise = 0, locked = false, phaseError = 0.0, estimated = 0.0
            for i in 0..<1400 {
                let t = Double(i)*0.01
                var onset = 0.0
                if t >= 0.3+Double(main)*period && main < 18 { onset = main%2 == 0 ? 0.98 : 0.86; main += 1 }
                if t >= 0.3+Double(noise)*period+period*0.29 && noise < 18 { onset = 0.65; noise += 1 }
                let active = t < 0.3+18*period
                clock.step(now: t,onset: onset,active: active)
                if clock.locked && t > 3 && active {
                    locked = true; estimated = clock.bpm
                    let expected = 0.3+((clock.nextBeat-0.3)/period).rounded(.toNearestOrEven)*period
                    phaseError = max(phaseError,abs(expected-clock.nextBeat))
                }
            }
            expect(locked && abs(estimated-bpm) < 2 && phaseError < 0.045,"onset tempo/phase with off-grid interference \(bpm)")
            expect(!clock.locked,"silence stops beat clock \(bpm)")
            let envelope = MusicTempoTracker()
            var nextNoise = 0.2, count = 0, cycles = 0, envelopeError = 0.0, envelopeBPM = 0.0
            for i in 0..<2400 {
                let t = Double(i)*0.01, local = t-0.3-floor((t-0.3)/period)*period
                let low = t >= 0.3 && t < 20 ? 0.004*exp(-local/0.075) : 0
                var onset = 0.0
                if t >= nextNoise && t < 20 { onset = 0.85; count += 1; nextNoise += 0.18+Double((count*37)%51)*0.01 }
                envelope.observeEnvelope(now: t,low: low,broad: low*1.8)
                envelope.step(now: t,onset: onset,active: low > 0.00012)
                if envelope.locked && t > 8 && t < 20 {
                    if envelope.usesBassCycle { cycles += 1 }
                    envelopeBPM = envelope.bpm
                    let nearest = 0.3+((envelope.nextBeat-0.3)/period).rounded(.toNearestOrEven)*period
                    envelopeError = max(envelopeError,abs(envelope.nextBeat-nearest))
                }
            }
            expect(cycles >= 350 && abs(envelopeBPM-bpm) < 3 && envelopeError < 0.055,"bass envelope rejects irregular crossings \(bpm) [\(envelopeBPM), \(envelopeError), \(cycles)]")
            expect(!envelope.locked,"envelope stops after silence \(bpm)")
        }
        let irregular = MusicTempoTracker()
        let times = [0.30,0.49,1.13,1.36,2.07,2.48,3.31,3.54,4.17,4.42,5.24,5.61,6.36,6.63]
        var n = 0, any = false
        for i in 0..<800 {
            let t = Double(i)*0.01
            var onset = 0.0
            if n < times.count && t >= times[n] { onset = 1; n += 1 }
            irregular.step(now: t,onset: onset,active: true); any = any || irregular.locked
        }
        expect(!any,"irregular sounds do not invent a beat")
        let changed = MusicTempoTracker()
        var next = 0.3, adapted = false
        for i in 0..<1600 {
            let t = Double(i)*0.01
            var onset = 0.0
            if t >= next { onset = 1; next += t < 6 ? 0.5 : 0.375 }
            changed.step(now: t,onset: onset,active: true)
            if t > 12 && changed.locked && abs(changed.bpm-160) < 3 { adapted = true }
        }
        expect(adapted,"tempo changes reacquire at 160 BPM")

        // Exercise the full PCM filters, channel handling and quiet-volume gain.
        for rate in [44100.0,48000] {
            for amplitude in [0.2,0.0002] {
                let detector = MusicBeatDetector(sampleRate: rate,channels: 2)
                var samples: [Float] = []; samples.reserveCapacity(1024)
                for i in 0..<Int(rate*10) {
                    let t = Double(i)/rate, phase = t.truncatingRemainder(dividingBy: 0.5)
                    let x = Float(amplitude*exp(-phase/0.045)*sin(2 * .pi*80*t))
                    samples.append(x); samples.append(-x) // opposite phase must not cancel bass energy
                    if samples.count >= 1024 { detector.push(interleaved: samples); samples.removeAll(keepingCapacity: true) }
                }
                detector.push(interleaved: samples)
                expect(detector.frame.locked && abs(detector.frame.bpm-120) < 3,"PCM kick train \(rate) Hz amplitude \(amplitude): \(detector.frame.bpm)")
                detector.push(interleaved: [Float](repeating: 0,count: Int(rate*4)))
                expect(!detector.frame.locked,"PCM silence stops motion")
                detector.push(interleaved: [.nan,.infinity,-.infinity,.nan])
                expect(detector.frame.level.isFinite,"nonfinite PCM cannot corrupt detector")
            }
        }
        for hz in [30.0,60,144] {
            var motion = MusicMotion(x: 350,y: 188,width: 800,floor: 650,figure: 132)
            var maxBend = 0.0, minBend = 0.0, bounded = true
            for i in 0..<Int(12*hz) {
                let t = Double(i)/hz
                motion.step(elapsed: 1/hz,paused: false,locked: motion.phase == 2 && t < 8,beatPhase: t/0.5,period: 0.5)
                bounded = bounded && motion.y <= motion.floor+0.001 && motion.x >= motion.flightMargin-0.001 && motion.x <= motion.width-motion.flightMargin+0.001
                maxBend = max(maxBend,motion.bend); minBend = min(minBend,motion.bend)
            }
            expect(bounded && motion.impacts == 3 && motion.phase == 2,"three diminishing landings, host bounds \(hz) fps")
            expect(maxBend > 0.32 && minBend < -0.159,"original compression/rebound curve \(hz) fps")
            expect(abs(motion.bend) < 0.001 && motion.energy < 0.001 && abs(motion.vx) < 0.1,"settles after audio stops \(hz) fps")
            let x = motion.x, time = motion.time
            for _ in 0..<120 { motion.step(elapsed: 1/hz,paused: true,locked: true,beatPhase: 0,period: 0.5) }
            expect(motion.x == x && motion.time == time,"interaction pause freezes travel \(hz) fps")
        }
        expect(abs(MusicMotion.beatPose(0)-0.40) < 1e-9 && abs(MusicMotion.beatPose(0.32)+0.16) < 1e-9,"Windows key poses preserved exactly")
        var held = MusicMotion(x: 300,y: 300,width: 1000,floor: 800,figure: 132)
        held.beginHold(pointer: CGPoint(x: 300,y: 300))
        held.moveHeld(x: 380,y: 260,pointer: CGPoint(x: 380,y: 260),dt: 0.05)
        held.release()
        expect(held.vx > 500 && held.vy < -200 && !held.held,"release keeps pointer throw velocity")
    }
}

#if MUSIC_STANDALONE
@main struct MusicRhythmRunner {
    static func main() {
        var count = 0, failures = 0
        MusicRhythmChecks.run { success, message in
            count += 1
            if !success { failures += 1; print("FAIL: "+message) }
        }
        print("Music rhythm/motion: \(count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
#else
final class MusicRhythmTests: XCTestCase {
    func testWindowsRhythmAndMotionPort() { MusicRhythmChecks.run { XCTAssertTrue($0,$1) } }
}
#endif
