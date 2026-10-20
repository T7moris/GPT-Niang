import AppKit
import Combine
import GPTNiangCore

struct MusicPose: Equatable {
    var bend = 0.0, rock = 0.0, lamp = 0.0, pulse = 0.0, energy = 0.0, cycle = 0.0, props = 0.0, artTime = 0.0
}

@MainActor
final class MusicController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var running = false
    @Published private(set) var status = "音乐律动已关闭"
    @Published private(set) var error: String?
    @Published private(set) var pose = MusicPose()
    @Published private(set) var bpm = 0
    private var capture: MusicAudioSource?
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var motion: MusicMotion?
    private var lastTick = 0.0, lastStatus = 0.0, artTime = 0.0
    private var area = CGRect.zero, grabOffset = CGPoint.zero
    private var sleeping = false
    private let makeCapture: (@escaping (String, String?) -> Void) -> MusicAudioSource?
    var audio = MusicCaptureSnapshot()

    init(makeCapture: @escaping (@escaping (String, String?) -> Void) -> MusicAudioSource? = { callback in
        if #available(macOS 14.2, *) { return SystemMusicCapture(onState: callback) }
        return nil
    }) {
        self.makeCapture = makeCapture
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,object: nil,queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,object: nil,queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        })
    }
    deinit {
        capture?.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func setEnabled(_ value: Bool) {
        stopCapture(); enabled = value; error = nil
        if value && !sleeping { beginCapture() }
        else { status = value ? "休眠期间暂停" : "音乐律动已关闭" }
    }
    func retry() { setEnabled(true) }
    func stop() { setEnabled(false) }
    private func beginCapture() {
        let token = generation
        guard let source = makeCapture({ [weak self] state, message in
            Task { @MainActor in
                guard let self, self.generation == token, self.enabled else { return }
                if state == "running" { self.running = true; self.status = "等待音乐节拍…" }
                else if state == "failed" {
                    self.stopCapture(); self.enabled = false
                    self.error = message; self.status = "音乐律动暂时无法启动"
                } else { self.running = false; self.status = "正在连接系统音频…" }
            }
        }) else { enabled = false; status = "音乐律动需要 macOS 14.2 或更新版本"; return }
        capture = source; status = "正在连接系统音频…"; source.start()
    }
    private func stopCapture() {
        generation = UUID(); capture?.stop(); capture = nil
        running = false; motion = nil; pose = MusicPose(); audio = MusicCaptureSnapshot(); bpm = 0
        lastTick = 0; artTime = 0
    }
    func sleep() {
        sleeping = true; stopCapture()
        if enabled { status = "休眠期间暂停" }
    }
    func wake() {
        guard sleeping else { return }
        sleeping = false
        if enabled { beginCapture() }
    }
    func beginHold(pointer: CGPoint) {
        guard running, var motion else { return }
        let local = CGPoint(x: pointer.x-area.minX,y: area.maxY-pointer.y)
        grabOffset = CGPoint(x: motion.x-local.x,y: motion.y-local.y-min(52,motion.figure*0.45))
        motion.beginHold(pointer: local); self.motion = motion
    }
    func endHold() { motion?.release() }
    func pause(now: Double) {
        lastTick = now
        if var motion {
            motion.step(elapsed: 1/60,paused: true,locked: false,beatPhase: 0,period: 0)
            self.motion = motion; publish(motion)
        }
    }
    func frame(normal: CGRect, area: CGRect, layout: CompanionLayout, visibleRect: CGRect, now: Double, paused: Bool) -> CGRect {
        guard running else { return normal }
        let elapsed = lastTick > 0 ? max(0,now-lastTick) : 1/60
        lastTick = now; self.area = area
        let scale = layout.characterScale
        let anchorX = layout.padding+layout.character.minX+visibleRect.midX*scale
        let anchorY = layout.padding+layout.character.minY+visibleRect.maxY*scale
        let figure = visibleRect.width*scale
        if motion == nil {
            motion = MusicMotion(x: normal.minX-area.minX+anchorX,y: area.maxY-normal.maxY+anchorY,
                                 width: area.width,floor: area.height-6,figure: figure)
        }
        guard var m = motion else { return normal }
        if abs(m.width-area.width) > 0.5 || abs(m.floor-(area.height-6)) > 0.5 || abs(m.figure-figure) > 0.5 {
            m.resize(width: area.width,floor: area.height-6,figure: figure)
        }
        // A wake or stalled UI must not replay elapsed physics or old audio.
        if elapsed > 0.5 { m.endAfterDiscontinuity() }
        audio = capture?.snapshot() ?? MusicCaptureSnapshot()
        let fresh = audio.receivedAt > 0 && now-audio.receivedAt < 0.25
        let a = audio.audio, locked = fresh && a.locked
        let phase = locked ? 1+(a.time+now-audio.capturedAt-a.nextBeat)/a.period : 0
        if m.held && !paused {
            let pointer = NSEvent.mouseLocation
            let local = CGPoint(x: pointer.x-area.minX,y: area.maxY-pointer.y)
            m.moveHeld(x: local.x+grabOffset.x,y: local.y+grabOffset.y,pointer: local,dt: min(elapsed,0.12))
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        m.step(elapsed: elapsed > 0.5 ? 1/60 : elapsed,paused: paused || reduced,locked: locked,beatPhase: phase,period: a.period)
        if !paused && (m.energy > 0.005 || m.pulse > 0.005) { artTime += min(elapsed,0.12)*(0.3+0.7*m.energy) }
        motion = m; publish(m)
        if now-lastStatus > 0.3 {
            lastStatus = now
            let nextBPM = locked ? Int(a.bpm.rounded()) : 0
            if bpm != nextBPM { bpm = nextBPM }
            let nextStatus = reduced ? "已按「减少动态效果」暂停动作" : paused ? "操作期间暂停律动" :
                locked ? "正在跟随音乐节拍" : fresh && a.level > 0.00001 ? "正在识别音乐节拍…" : "等待音乐节拍…"
            if status != nextStatus { status = nextStatus }
        }
        // Bounds are resolved against the current validated host on every frame.
        // No queued absolute window coordinates can survive a Space transition.
        let proposed = CGRect(x: area.minX+m.x-anchorX,y: area.maxY-m.y+anchorY-normal.height,
                              width: normal.width,height: normal.height)
        return WidgetPlacement.desktopFrame(area: area,size: normal.size,origin: proposed.origin)
    }
    private func publish(_ motion: MusicMotion) {
        func q(_ value: Double) -> Double { (value*10000).rounded()/10000 }
        let next = MusicPose(bend: q(motion.bend),rock: q(motion.rock),lamp: q(motion.lamp),pulse: q(motion.pulse),
                             energy: q(motion.energy),cycle: q(motion.cycle),props: q(motion.props),artTime: q(artTime))
        if pose != next { pose = next }
    }
}

private extension MusicMotion {
    mutating func endAfterDiscontinuity() {
        release(); vx = 0; vy = 0; bend = 0; bendSpeed = 0; energy = 0; pulse = 0
    }
}

enum MusicCharacterBounds {
    static func visibleRect(_ image: NSImage?) -> CGRect {
        let fallback = CGRect(x: 0,y: 0,width: 208,height: 208)
        guard let image, image.size.width > 0, image.size.height > 0,
              let cg = image.cgImage(forProposedRect: nil,context: nil,hints: nil) else { return fallback }
        var bytes = [UInt8](repeating: 0,count: 128*128*4)
        var left = 128, top = 128, right = -1, bottom = -1
        bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress,width: 128,height: 128,bitsPerComponent: 8,
                bytesPerRow: 512,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cg,in: CGRect(x: 0,y: 0,width: 128,height: 128))
            for y in 0..<128 { for x in 0..<128 where data[(y*128+x)*4+3] > 12 {
                left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
            } }
        }
        guard right >= left, bottom >= top else { return fallback }
        let s = min(208/image.size.width,208/image.size.height)
        let w = image.size.width*s, h = image.size.height*s
        return CGRect(x: (208-w)/2+Double(left)/128*w,y: (208-h)/2+Double(top)/128*h,
                      width: Double(right-left+1)/128*w,height: Double(bottom-top+1)/128*h)
    }
}
