import Foundation

// Swift port of T7moris/GPT-Niang v1.3.5 runtime/music-audio.cs.
// Preserve the original bass gate, four drum bands, tempo fit and beat phase.
// Only derived energy/novelty is retained; no audio is recorded or transmitted.
private func bounded(_ x: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, x)) }
private func rounded(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

public struct MusicAudioFrame: Equatable {
    public var level = 0.0, lowLevel = 0.0, strength = 0.0, drive = 0.0
    public var locked = false, period = 0.0, nextBeat = 0.0, confidence = 0.0
    public var time = 0.0, onsetTime = -10.0
    public var onsets = 0, beats = 0
    public init() {}
    public var bpm: Double { locked && period > 0 ? 60 / period : 0 }
}

private struct MusicBiquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0
    init(rate: Double, cutoff: Double, high: Bool) {
        let w = 2 * Double.pi * cutoff / rate, c = cos(w)
        let alpha = sin(w) / (2 * 0.707106781186548), a0 = 1 + alpha
        b0 = (high ? (1 + c) / 2 : (1 - c) / 2) / a0
        b1 = (high ? -(1 + c) : 1 - c) / a0; b2 = b0
        a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }
    mutating func next(_ x: Double) -> Double {
        let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y
        return y
    }
}

public final class MusicBeatDetector {
    private var high: [MusicBiquad], low: [MusicBiquad]
    private var rhythmHigh: [MusicBiquad], rhythmLow: [MusicBiquad]
    private var rhythmEnergy = [Double](repeating: 0, count: 4)
    private var rhythmPrevious = [Double](repeating: 0, count: 4)
    private let rate: Double, channels: Int, window: Int
    private var count = 0
    private var sum = 0.0, broad = 0.0, baseline = 0.0, lastLow = 0.0
    private var peak = 0.0, gainPeak = 0.0, signalPeak = 0.0
    private var armed = true
    public private(set) var frame = MusicAudioFrame()
    public let tempo = MusicTempoTracker()

    public init(sampleRate: Double, channels: Int) {
        precondition(sampleRate >= 8000 && sampleRate <= 384000 && (1...32).contains(channels))
        rate = sampleRate; self.channels = channels; window = max(64, Int(sampleRate / 100))
        high = (0..<channels).map { _ in MusicBiquad(rate: sampleRate, cutoff: 40, high: true) }
        low = (0..<channels).map { _ in MusicBiquad(rate: sampleRate, cutoff: 220, high: false) }
        rhythmHigh = (0..<4*channels).map { MusicBiquad(rate: sampleRate, cutoff: 220 * pow(2, Double($0/channels)), high: true) }
        rhythmLow = (0..<4*channels).map { MusicBiquad(rate: sampleRate, cutoff: 440 * pow(2, Double($0/channels)), high: false) }
    }

    public func push(interleaved samples: [Float]) {
        guard samples.count >= channels else { return }
        for offset in stride(from: 0, through: samples.count - channels, by: channels) {
            for c in 0..<channels {
                let value = Double(samples[offset + c])
                let x = value.isFinite ? bounded(value, -1, 1) : 0
                let filtered = low[c].next(high[c].next(x))
                for band in 0..<4 {
                    let index = band * channels + c
                    let v = rhythmLow[index].next(rhythmHigh[index].next(x))
                    rhythmEnergy[band] += v*v
                }
                broad += x*x; sum += filtered*filtered
            }
            count += 1; frame.time += 1/rate
            if count >= window { analyzeWindow() }
        }
    }

    private func analyzeWindow() {
        let dt = Double(count)/rate, divisor = Double(count*channels)
        let raw = sqrt(sum/divisor); frame.level = sqrt(broad/divisor)
        frame.lowLevel += (raw-frame.lowLevel)*(1-exp(-dt/0.030))
        signalPeak = max(frame.level, signalPeak*exp(-dt/0.05))
        let scale = bounded(signalPeak/0.01, 0.001, 1)
        let threshold = max(0.00018*scale, baseline*0.90), rise = frame.lowLevel-lastLow
        peak *= exp(-dt)
        gainPeak = max(frame.lowLevel, min(gainPeak*exp(-dt/2), signalPeak*1.5))
        frame.drive = frame.lowLevel > 0.00008*scale && frame.lowLevel > frame.level*0.10 ?
            min(1,frame.lowLevel/max(0.0006*scale,gainPeak))*min(1,frame.lowLevel/(0.0005*scale)) : 0
        if frame.lowLevel < peak*0.86 || frame.lowLevel < 0.00008*scale { armed = true }
        var onset = 0.0
        if armed && frame.time-frame.onsetTime >= 0.17 && frame.lowLevel > threshold &&
            frame.lowLevel > frame.level*0.16 && rise > max(0.00004*scale,baseline*0.065) {
            frame.onsets += 1; frame.onsetTime = frame.time; peak = frame.lowLevel; armed = false
            frame.strength = bounded(0.45+0.55*frame.lowLevel/max(0.0006*scale,gainPeak),0.35,1)
            onset = frame.strength
        }
        baseline += (frame.lowLevel-baseline)*(1-exp(-dt/(frame.lowLevel < baseline ? 0.04 : 0.4)))
        peak = max(peak,frame.lowLevel)
        var flux = 0.0
        for band in 0..<4 {
            let value = sqrt(rhythmEnergy[band]/divisor), floor = 0.0001*scale
            flux += max(0,log((floor+value)/(floor+rhythmPrevious[band])))*0.25
            rhythmPrevious[band] = value; rhythmEnergy[band] = 0
        }
        tempo.observeEnvelope(now: frame.time, low: frame.lowLevel, broad: frame.level, drumFlux: flux, signalScale: scale)
        tempo.step(now: frame.time, onset: onset, active: frame.level > 0.00012*scale)
        frame.locked = tempo.locked; frame.period = tempo.period; frame.nextBeat = tempo.nextBeat
        frame.confidence = tempo.confidence; frame.beats = tempo.sequence
        lastLow = frame.lowLevel; sum = 0; broad = 0; count = 0
    }
}

public final class MusicTempoTracker {
    private var times: [Double] = [], weights: [Double] = []
    private var lastActive = -10.0, lastConfirmed = -10.0, lastEmitted = -10.0
    private var novelty = [Double](repeating: 0, count: 800)
    private var noveltyCount = 0, noveltyWrite = 0
    private var previousLow = 0.0, previousFlux = 0.0, smoothedFlux = 0.0, noveltyMean = 0.0
    private var nextEstimate = 0.0, pendingPeriod = 0.0, pendingSince = 0.0, lastFlux = -10.0
    private var pendingMatches = 0, envelopeClock = false
    public private(set) var locked = false
    public private(set) var period = 0.0, nextBeat = 0.0, confidence = 0.0
    public private(set) var sequence = 0
    public var bpm: Double { locked ? 60/period : 0 }
    public var usesBassCycle: Bool { locked && envelopeClock }
    public init() {}

    public func reset() {
        locked = false; confidence = 0; times.removeAll(keepingCapacity: true); weights.removeAll(keepingCapacity: true)
        lastConfirmed = -10; lastFlux = -10; noveltyCount = 0; noveltyWrite = 0
        previousLow = 0; previousFlux = 0; smoothedFlux = 0; noveltyMean = 0; pendingPeriod = 0; envelopeClock = false
    }
    private func noveltyAt(_ ago: Double) -> Double {
        guard ago >= 0, ago+1 < Double(noveltyCount) else { return 0 }
        let n = Int(ago), a = (noveltyWrite-1-n+800)%800, b = (a-1+800)%800
        return novelty[a]+(novelty[b]-novelty[a])*(ago-Double(n))
    }
    private func correlation(_ lag: Int, _ length: Int) -> Double {
        guard length > lag else { return 0 }
        var mean = 0.0, xy = 0.0, xx = 0.0, yy = 0.0
        for i in 0..<length { mean += noveltyAt(Double(i)) }; mean /= Double(length)
        for i in 0..<length-lag {
            let a = noveltyAt(Double(i))-mean, b = noveltyAt(Double(i+lag))-mean
            xy += a*b; xx += a*a; yy += b*b
        }
        return xy/sqrt(max(1e-16,xx*yy))
    }
    private func onsetsSupportClock(_ now: Double) -> Bool {
        var total = 0.0, matched = 0.0, first = now, hits = 0
        for k in times.indices where now-times[k] <= 2.8 {
            total += weights[k]; first = min(first,times[k])
            let nearest = nextBeat+rounded((times[k]-nextBeat)/period)*period
            if abs(times[k]-nearest) < min(0.060,period*0.12) { matched += weights[k]; hits += 1 }
        }
        return hits >= 4 && now-first >= period*2.5 && matched > total*0.80 && now-lastConfirmed < period*1.4
    }
    private func peakSamples(_ lag: Int, _ length: Int) -> Double {
        let left = correlation(lag-1,length), center = correlation(lag,length), right = correlation(lag+1,length)
        let curve = left-2*center+right
        let offset = curve < 0 ? bounded(0.5*(left-right)/curve,-0.5,0.5) : 0
        return bounded(Double(lag)+offset,28,100)
    }
    private func coherence(_ samples: Double, _ length: Int) -> Double {
        let angle = 2*Double.pi/samples, cs = cos(angle), sn = sin(angle)
        var x = 1.0, y = 0.0, c = 0.0, s = 0.0, total = 0.0
        for i in 0..<length {
            let v = noveltyAt(Double(i)); c += v*x; s += v*y; total += v
            let next = x*cs-y*sn; y = x*sn+y*cs; x = next
        }
        return sqrt(c*c+s*s)/max(1e-12,total)
    }
    public func observeEnvelope(now: Double, low: Double, broad: Double, drumFlux: Double = -1, signalScale: Double = 1) {
        let scale = bounded(signalScale,0.001,1), floor = 0.0001*scale
        var flux = max(0,log((floor+low)/(floor+previousLow))); previousLow = low
        var bassEvidence = true
        if drumFlux >= 0 {
            bassEvidence = times.filter { now-$0 <= 3.3 }.count >= 3
            flux = 0.10*flux+0.90*drumFlux
        }
        if low < 0.00008*scale || low < broad*0.10 { flux = 0 }
        smoothedFlux += (flux-smoothedFlux)*(1-exp(-0.01/0.020)); flux = smoothedFlux
        novelty[noveltyWrite] = flux; noveltyWrite = (noveltyWrite+1)%800; noveltyCount = min(800,noveltyCount+1)
        noveltyMean += (flux-noveltyMean)*0.02
        if bassEvidence && flux > max(0.025,noveltyMean*0.9) { lastFlux = now }
        let peak = previousFlux; previousFlux = flux
        if locked {
            let at = now-0.040
            if bassEvidence && envelopeClock && peak > flux && peak > max(0.025,noveltyMean*0.9) && at-lastConfirmed > period*0.45 {
                let nearest = nextBeat+rounded((at-nextBeat)/period)*period, error = at-nearest
                if abs(error) < min(0.065,period*0.13) {
                    if lastConfirmed > 0 {
                        let n = rounded((at-lastConfirmed)/period)
                        if n >= 1 && n <= 3 { period += bounded((at-lastConfirmed)/n-period,-period*0.02,period*0.02)*0.06 }
                    }
                    period = bounded(period,0.28,1); nextBeat += error*0.10; lastConfirmed = at
                }
            }
        }
        if locked && !envelopeClock && onsetsSupportClock(now) { pendingPeriod = 0; return }
        guard bassEvidence, noveltyCount >= 160, now >= nextEstimate, now-lastFlux <= 0.25 else { return }
        nextEstimate = now+0.20
        let length = min(600,noveltyCount-1)
        var bestLag = 0, best = 0.0
        for lag in 28...100 {
            let fundamental = correlation(lag,length)
            if fundamental < 0.10 { continue }
            let score = fundamental+0.5*correlation(lag*2,length)
            if score > best { best = score; bestLag = lag }
        }
        if bestLag > 0 {
            let half = Int(rounded(peakSamples(bestLag,length)/2))
            if half >= 28 {
                let base = correlation(half,length), halfScore = base+0.5*correlation(half*2,length)
                if base >= 0.10 && base > correlation(bestLag,length)*0.50 && halfScore > best*0.50 { bestLag = half; best = halfScore }
            }
        }
        let required = noveltyCount < 320 ? 0.50 : 0.24
        guard bestLag > 0, best >= required, length >= bestLag*3 else { pendingPeriod = 0; return }
        let samples = peakSamples(bestLag,length), p = samples*0.01
        if locked {
            if abs(p-period) < period*0.05 { period += (p-period)*0.12; pendingPeriod = 0; return }
            let lag = Int(rounded(period*100))
            let current = (correlation(lag,length)+0.5*correlation(lag*2,length))*coherence(period*100,length)
            let subdivision = abs(period-2*p) < period*0.05 && correlation(bestLag,length) > correlation(lag,length)*0.50
            if !subdivision && best*coherence(samples,length) <= current { pendingPeriod = 0; return }
        }
        if pendingPeriod > 0 && abs(p-pendingPeriod) < pendingPeriod*0.05 { pendingMatches += 1 }
        else { pendingSince = now; pendingMatches = 1 }
        pendingPeriod = p
        guard now-pendingSince >= (locked ? 1.0 : 0.6), pendingMatches >= 3 else { return }
        var bestEnergy = 0.0, total = 0.0, bestAgo = 0
        for phase in 0..<bestLag {
            var energy = 0.0, beats = 0, ago = Double(phase)
            while ago < Double(length-2) {
                energy += noveltyAt(ago)+0.5*(noveltyAt(ago-1)+noveltyAt(ago+1)); beats += 1; ago += samples
            }
            energy /= Double(max(1,beats)); total += energy
            if energy > bestEnergy { bestEnergy = energy; bestAgo = phase }
        }
        guard bestEnergy >= max(0.025,total/Double(bestLag)*1.8) else { return }
        period = p; locked = true; envelopeClock = true; confidence = min(0.95,0.6+best*0.35); lastConfirmed = now
        nextBeat = now-Double(bestAgo)*0.01-0.030
        while nextBeat <= now { nextBeat += period }
    }
    public func step(now: Double, onset: Double, active: Bool) {
        if active { lastActive = now }
        if now-lastActive > max(1.2,period*1.6) { reset(); return }
        if onset >= 0.60 {
            while !times.isEmpty && (times.count == 32 || now-times[0] > 6) { times.removeFirst(); weights.removeFirst() }
            times.append(now); weights.append(pow(onset-0.35,3))
            if locked && !envelopeClock {
                let nearest = nextBeat+rounded((now-nextBeat)/period)*period, error = now-nearest
                if abs(error) < min(0.060,period*0.12) {
                    if lastConfirmed > 0 {
                        let n = rounded((now-lastConfirmed)/period)
                        if n >= 1 && n <= 3 { period += bounded((now-lastConfirmed)/n-period,-period*0.02,period*0.02)*0.18 }
                    }
                    nextBeat += error*0.15; lastConfirmed = now; confidence = min(1,confidence+0.025)
                }
            } else if !locked && times.count >= 4 { acquire(now) }
        }
        guard locked else { return }
        var expiry = lastConfirmed+period*(envelopeClock ? 2.6 : 1.6)
        expiry = max(expiry,min(lastConfirmed+period*4.2,lastFlux+period*1.1))
        if now > expiry { locked = false; confidence = 0; lastConfirmed = -10; envelopeClock = false; pendingPeriod = 0; return }
        if now >= nextBeat {
            if now-lastEmitted > period*0.55 { sequence += 1; lastEmitted = now }
            repeat { nextBeat += period } while nextBeat <= now
        }
    }
    private func acquire(_ now: Double) {
        let first = times.firstIndex { now-$0 <= 3.3 } ?? times.count
        guard times.count-first >= 4 else { return }
        var best = 0.86, bestPeriod = 0.0, bestOrigin = 0.0, bestLast = 0.0
        for i in first+1..<times.count {
            for j in max(first,i-5)..<i {
                for divisor in 1...3 {
                    let p = (times[i]-times[j])/Double(divisor)
                    if p < 0.28 || p > 1 { continue }
                    for anchor in max(0,times.count-4)..<times.count {
                        let origin = times[anchor]
                        var total = 0.0, matched = 0.0, latest = -10.0, hits = 0, slots = Set<Int>(), lo = 0, hi = 0
                        for k in first..<times.count {
                            total += weights[k]
                            let n = Int(rounded((times[k]-origin)/p))
                            if abs(times[k]-origin-Double(n)*p) > min(0.055,p*0.10) { continue }
                            hits += 1; matched += weights[k]; latest = times[k]; lo = min(lo,n); hi = max(hi,n)
                            if n >= -32 && n < 32 { slots.insert(n) }
                        }
                        let coverage = matched/total, occupancy = Double(slots.count)/Double(hi-lo+1)
                        if hits < 4 || hi-lo < 3 || coverage < 0.72 || occupancy < 0.72 || now-latest > 0.08 { continue }
                        let score = 0.6*coverage+0.4*occupancy-0.002*abs(log(p/0.5))
                        if score > best { best = score; bestPeriod = p; bestOrigin = origin; bestLast = latest }
                    }
                }
            }
        }
        guard bestPeriod > 0 else { return }
        var sw = 0.0, sn = 0.0, st = 0.0, snn = 0.0, snt = 0.0
        for k in first..<times.count {
            let n = rounded((times[k]-bestOrigin)/bestPeriod)
            if abs(times[k]-bestOrigin-n*bestPeriod) > min(0.055,bestPeriod*0.10) { continue }
            let w = weights[k]; sw += w; sn += w*n; st += w*times[k]; snn += w*n*n; snt += w*n*times[k]
        }
        let denominator = sw*snn-sn*sn
        if denominator > 0 {
            let fitted = (sw*snt-sn*st)/denominator
            if abs(fitted-bestPeriod) < bestPeriod*0.05 { bestPeriod = fitted; bestOrigin = (st-bestPeriod*sn)/sw }
        }
        period = bestPeriod; locked = true; confidence = best; lastConfirmed = bestLast
        nextBeat = bestOrigin+(floor((now-bestOrigin)/period)+1)*period
    }
}
