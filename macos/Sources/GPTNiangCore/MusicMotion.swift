import Foundation

/// Port of GptMusicMotion in upstream v1.3.5 music-visual.cs. Coordinates point
/// downwards, with the feet at `floor`; the host window remains the sole mover.
public struct MusicMotion {
    public var x: Double, y: Double, width: Double, floor: Double, figure: Double
    public var vx = 0.0, vy = 0.0, time = 0.0, bend = 0.0, bendSpeed = 0.0
    public var rock = 0.0, rockSpeed = 0.0, lamp = 0.0, lampSpeed = 0.0
    public var pulse = 0.0, energy = 0.0, cycle = 0.0, props = 0.0
    public var phase = 0, impacts = 0, direction = -1
    public private(set) var held = false
    public private(set) var throwX = 0.0, throwY = 0.0
    private var landed = 0.0, lockStartPose = 0.0, flightCeiling = 0.0, pointerIdle = 0.0
    private var lastPointer: CGPoint?
    private var wasLocked = false, throwMomentum = false
    public init(x: Double, y: Double, width: Double, floor: Double, figure: Double) {
        self.x = x; self.y = y; self.width = width; self.floor = floor; self.figure = figure
    }
    private func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double { max(low,min(high,x)) }
    public var margin: Double { min(width/2,24+figure*0.86) }
    public var flightMargin: Double { min(width/2,4+figure*0.52) }
    private static func spring(_ value: inout Double, _ speed: inout Double, _ target: Double, _ dt: Double, _ frequency: Double, _ damping: Double) {
        var remaining = dt
        while remaining > 0 {
            let step = min(remaining,1/240.0)
            speed += ((target-value)*frequency*frequency-2*damping*frequency*speed)*step
            value += speed*step; remaining -= step
        }
    }
    public static func beatPose(_ phase: Double) -> Double {
        let phase = phase-Foundation.floor(phase)
        if phase < 0.32 { return 0.12+0.28*cos(.pi*phase/0.32) }
        if phase < 0.66 { return -0.08*(1+cos(.pi*(phase-0.32)/0.34)) }
        if phase < 0.78 { return 0 }
        return 0.20*(1-cos(.pi*(phase-0.78)/0.22))
    }
    public mutating func beginHold(pointer: CGPoint) {
        held = true; wasLocked = false; energy = 0; bendSpeed = 4; vy = 0; props = 0
        throwX = 0; throwY = 0; pointerIdle = 0; lastPointer = pointer; throwMomentum = false
    }
    public mutating func moveHeld(x: Double, y: Double, pointer: CGPoint, dt: Double) {
        guard held, dt > 0 else { return }
        if let last = lastPointer {
            let dx = pointer.x-last.x, dy = pointer.y-last.y
            if abs(dx)+abs(dy) > 0.1 {
                pointerIdle = 0
                let vx = dx/dt, vy = dy/dt, limit = min(1,2000/max(1,hypot(vx,vy)))
                let blend = 1-exp(-dt/0.025)
                throwX += (vx*limit-throwX)*blend; throwY += (vy*limit-throwY)*blend
            } else {
                let old = pointerIdle; pointerIdle += dt
                let decay = exp(-(max(0,pointerIdle-0.080)-max(0,old-0.080))/0.025)
                throwX *= decay; throwY *= decay
            }
        }
        lastPointer = pointer
        self.x = clamp(x,flightMargin,max(flightMargin,width-flightMargin))
        Self.spring(&self.y,&vy,clamp(y,16,floor),dt,22,0.72)
        if self.y > floor { self.y = floor; vy = min(0,vy) }
    }
    public mutating func release() {
        guard held else { return }
        held = false; phase = 0; impacts = 0; props = 0; vx = throwX; vy = throwY
        throwMomentum = abs(vx) > 120
        flightCeiling = min(y,min(floor,figure*1.22+16))
        if abs(vx)+abs(vy) < 60 { vy = -90 }
        if abs(vx) > 5 { direction = vx > 0 ? 1 : -1 }
    }
    public mutating func resize(width: Double, floor: Double, figure: Double) {
        if self.width > 0 { x = x/self.width*width }
        y += floor-self.floor; self.width = width; self.floor = floor; self.figure = figure
        if phase > 0 && !held { y = floor }
        x = clamp(x,margin,max(margin,width-margin))
    }
    private mutating func moveAir(_ dt: Double, _ drag: Double) {
        x += vx*dt; vx *= exp(-dt*drag)
        let m = flightMargin
        if x < m { x = m; if vx < 0 { vx = -vx*0.62 }; direction = 1 }
        if x > width-m { x = width-m; if vx > 0 { vx = -vx*0.62 }; direction = -1 }
    }
    public mutating func step(elapsed: Double, paused: Bool, locked: Bool, beatPhase: Double, period: Double, strength: Double = 1) {
        let dt = clamp(elapsed,0,0.12)
        guard dt > 0 else { return }
        if paused {
            Self.spring(&bend,&bendSpeed,0,dt,20,0.8); Self.spring(&rock,&rockSpeed,0,dt,14,0.8)
            Self.spring(&lamp,&lampSpeed,0,dt,7,0.8)
            if phase >= 2 { vx *= exp(-dt*12) }
            pulse *= exp(-dt*10); energy = 0; wasLocked = false; return
        }
        time += dt
        if held { Self.spring(&bend,&bendSpeed,-0.045,dt,20,0.42); pulse = 0; return }
        if phase == 0 {
            var remaining = dt
            while remaining > 0 && phase == 0 {
                let s = min(remaining,1/240.0)
                moveAir(s,0.30); vy += 1180*s; y += vy*s
                var ceiling = min(floor,figure*1.22+16)
                if flightCeiling > 0 { ceiling = min(ceiling,flightCeiling) }
                if y < ceiling && vy < 0 { y = ceiling; vy = -vy*0.42 }
                if y >= floor && vy > 0 {
                    y = floor; impacts += 1; bend = min(0.30,vy/2500); bendSpeed = 0
                    vx *= throwMomentum ? 0.94 : 0.68
                    if impacts <= 2 { vy = -vy*0.52 } else { vy = 0; phase = 1; landed = time }
                }
                remaining -= s
            }
            Self.spring(&bend,&bendSpeed,0,dt,20,0.67); return
        }
        y = floor; vy = 0
        if phase == 1 {
            props = min(1,(time-landed)/0.25); moveAir(dt,throwMomentum ? 0.75 : 10)
            Self.spring(&bend,&bendSpeed,0,dt,20,0.67)
            if props >= 1 { phase = 2 }; return
        }
        let oldBend = bend, locked = locked && period >= 0.28 && period <= 1
        if locked {
            if !wasLocked { cycle = beatPhase; lockStartPose = bend; energy = 0 }
            else {
                let predicted = cycle+max(0,elapsed)/period
                var error = beatPhase-predicted; error -= error.rounded(.toNearestOrEven)
                cycle = predicted+clamp(error,-0.08,0.08)*(1-exp(-dt/0.12))
            }
            energy += (1-energy)*(1-exp(-dt/0.12))
            bend = lockStartPose*(1-energy)+Self.beatPose(cycle)*clamp(strength,0.8,1)*energy
        } else { energy *= exp(-dt/0.12); bend *= exp(-dt/0.10) }
        wasLocked = locked; bendSpeed = (bend-oldBend)/dt; pulse = clamp(bend/0.4,0,1)
        Self.spring(&rock,&rockSpeed,locked ? 7.5*sin(2 * .pi*(cycle-0.04))*energy : 0,dt,18,0.7)
        Self.spring(&lamp,&lampSpeed,locked ? 8*sin(.pi*cycle)*energy : 0,dt,9,0.75)
        if throwMomentum && abs(vx) > 35 { moveAir(dt,0.75); return }
        throwMomentum = false
        if x < margin { direction = 1 }; if x > width-margin { direction = -1 }
        let available = direction < 0 ? x-margin : width-margin-x, rate = locked ? 4.0 : 10.0
        let wanted = Double(direction)*25*energy*min(1,max(0,available)/28), decay = exp(-dt*rate), old = vx
        vx = wanted+(old-wanted)*decay; x += wanted*dt+(old-wanted)*(1-decay)/rate
        if x < margin+1 && direction < 0 { direction = 1 }
        if x > width-margin-1 && direction > 0 { direction = -1 }
        x = clamp(x,flightMargin,max(flightMargin,width-flightMargin))
        if abs(bend) < 0.00001 && abs(bendSpeed) < 0.0001 { bend = 0; bendSpeed = 0 }
        if energy < 0.00001 { energy = 0 }; if pulse < 0.00001 { pulse = 0 }
    }
}
