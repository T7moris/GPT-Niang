import SwiftUI

// Shapes, colors and placement ported from upstream v1.3.5 MusicArt/MusicLamp.
struct MusicSpeakers: View {
    let pose: MusicPose
    let visible: CGRect
    var body: some View {
        Canvas { context, _ in
            // Canvas clips at its own bounds; reserve room for both rocking speakers.
            context.translateBy(x: 80,y: 0)
            let f = visible.width
            context.opacity = pose.props
            context.fill(Path(ellipseIn: CGRect(x: visible.midX-f*0.325,y: visible.maxY-2,
                                                width: f*0.65,height: 6)),with: .color(.purple.opacity(0.15)))
            for side in [-1.0, 1.0] {
                let angle = side < 0 ? pose.rock : -0.94*pose.rock
                var c = context
                let s = f/132, lift = 28*s*abs(sin(angle * .pi/180))
                c.translateBy(x: visible.midX+side*f*0.56,y: visible.maxY-lift)
                c.rotate(by: .degrees(angle)); c.scaleBy(x: s,y: s)
                let shell = Path(roundedRect: CGRect(x: -25,y: -90,width: 49,height: 90),cornerRadius: 8)
                c.fill(shell,with: .color(Color.music(0x272038))); c.stroke(shell,with: .color(Color.music(0xaa8ad9)),lineWidth: 2)
                c.stroke(Path(roundedRect: CGRect(x: -21,y: -86,width: 41,height: 82),cornerRadius: 5),with: .color(Color.music(0x16131f)),lineWidth: 1)
                c.fill(Path(roundedRect: CGRect(x: -16,y: -81,width: 30,height: 3.5),cornerRadius: 1.7),with: .color(Color.music(0x91e0e1)))
                for (y,r) in [(-63.0,8.0),(-28.0,18.0)] {
                    let circle = Path(ellipseIn: CGRect(x: -r,y: y-r,width: r*2,height: r*2))
                    c.fill(circle,with: .color(Color.music(0x16131f))); c.stroke(circle,with: .color(Color.music(0x91e0e1)),lineWidth: 1.7)
                    let radius = r*0.78*(1+pose.pulse*0.065)
                    c.fill(Path(ellipseIn: CGRect(x: -radius,y: y-radius,width: radius*2,height: radius*2)),with: .color(Color.music(0x403252)))
                    c.fill(Path(ellipseIn: CGRect(x: -r*0.39,y: y-r*0.39,width: r*0.78,height: r*0.78)),with: .color(Color.music(0xb89bd2)))
                }
            }
        }.allowsHitTesting(false)
    }
}

struct MusicGlasses: View {
    let visible: CGRect
    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: visible.midX+visible.width*0.008,y: visible.maxY-visible.height*0.376)
            context.rotate(by: .degrees(-7)); context.scaleBy(x: visible.width/256,y: visible.width/256)
            var arms = Path()
            arms.move(to: CGPoint(x: -56,y: -8)); arms.addQuadCurve(to: CGPoint(x: -73,y: -8),control: CGPoint(x: -66,y: -11))
            arms.move(to: CGPoint(x: 53,y: -8)); arms.addQuadCurve(to: CGPoint(x: 69,y: -19),control: CGPoint(x: 62,y: -14))
            arms.move(to: CGPoint(x: -11,y: -6)); arms.addQuadCurve(to: CGPoint(x: 12,y: -6),control: CGPoint(x: 0,y: -12))
            context.stroke(arms,with: .color(Color.music(0x36313f)),lineWidth: 2)
            for side in [-1.0,1.0] {
                var lens = Path()
                lens.move(to: CGPoint(x: side*10,y: -12))
                lens.addQuadCurve(to: CGPoint(x: side*57,y: -12),control: CGPoint(x: side*34,y: -17))
                lens.addLine(to: CGPoint(x: side*55,y: 6))
                lens.addQuadCurve(to: CGPoint(x: side*33,y: 21),control: CGPoint(x: side*53,y: 21))
                lens.addQuadCurve(to: CGPoint(x: side*12,y: 5),control: CGPoint(x: side*13,y: 21))
                lens.closeSubpath()
                context.fill(lens,with: .linearGradient(Gradient(colors: [.music(0x171527),.music(0x343044)]),startPoint: CGPoint(x: 0,y: -15),endPoint: CGPoint(x: 0,y: 22)))
                context.stroke(lens,with: .color(Color.music(0x302c3e)),lineWidth: 1.9)
                var shine = Path(); shine.move(to: CGPoint(x: side*22,y: -5)); shine.addLine(to: CGPoint(x: side*34,y: -6))
                context.stroke(shine,with: .color(Color.music(0xc4cfdf).opacity(0.3)),lineWidth: 1.9)
            }
        }.allowsHitTesting(false)
    }
}

struct MusicStageView: View {
    @ObservedObject var music: MusicController
    let following: Bool
    private let palette: [Color] = [0xf648c5,0x48def5,0xae64fd,0x91e0e1,0xffd876,0xff87b4].map(Color.music)
    var body: some View {
        Canvas { context, size in
            let m = music.pose, top = following ? 52.0 : 4.0, diameter = 56.0
            context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(Color.music(0x0a0717).opacity(0.48)))
            let origin = CGPoint(x: size.width/2,y: top+44), length = max(1,size.height-top)
            for (i,color) in palette.prefix(3).enumerated() {
                var c = context
                c.translateBy(x: origin.x,y: origin.y)
                c.rotate(by: .degrees(Double(i-1)*38+14*sin(.pi*m.cycle*0.5+Double(i)*1.8)*m.energy))
                var beam = Path(); beam.move(to: .zero)
                beam.addLine(to: CGPoint(x: -length*0.30,y: length)); beam.addLine(to: CGPoint(x: length*0.30,y: length)); beam.closeSubpath()
                c.fill(beam,with: .linearGradient(Gradient(colors: [color.opacity(0.27),color.opacity(0)]),startPoint: .zero,endPoint: CGPoint(x: 0,y: length)))
            }
            context.fill(Path(ellipseIn: CGRect(x: origin.x-diameter,y: origin.y-diameter,width: diameter*2,height: diameter*2)),
                         with: .radialGradient(Gradient(colors: [.cyan.opacity(0.25+0.2*m.pulse),.clear]),center: origin,startRadius: 0,endRadius: diameter))
            context.translateBy(x: size.width/2,y: top); context.rotate(by: .degrees(m.lamp))
            var wire = Path(); wire.move(to: .zero); wire.addLine(to: CGPoint(x: 0,y: 16))
            context.stroke(wire,with: .color(Color.music(0xaaa0b1)),lineWidth: 1)
            context.translateBy(x: 0,y: 44)
            let ball = Path(ellipseIn: CGRect(x: -28,y: -28,width: 56,height: 56))
            context.fill(ball,with: .color(Color.music(0x272038)))
            var tiles = context; tiles.clip(to: ball)
            let phase = (m.artTime*4).truncatingRemainder(dividingBy: 5)-2.5
            for row in 0..<12 { for col in 0..<15 {
                let color = palette[(row*7+col*3+col/3)%palette.count]
                tiles.fill(Path(CGRect(x: -37.5+Double(col)*5+phase,y: -30+Double(row)*5,width: 4.35,height: 4.35)),with: .color(color))
            } }
            context.fill(ball,with: .radialGradient(Gradient(colors: [.clear,.black.opacity(0.4)]),center: CGPoint(x: -10,y: -12),startRadius: 0,endRadius: 50))
            context.stroke(ball,with: .color(Color.music(0xaa8ad9)),lineWidth: 1.5)
            var star = Path()
            star.move(to: CGPoint(x: -10,y: -23)); star.addLine(to: CGPoint(x: -8,y: -16)); star.addLine(to: CGPoint(x: -1,y: -14))
            star.addLine(to: CGPoint(x: -8,y: -12)); star.addLine(to: CGPoint(x: -10,y: -5)); star.addLine(to: CGPoint(x: -12,y: -12))
            star.addLine(to: CGPoint(x: -19,y: -14)); star.addLine(to: CGPoint(x: -12,y: -16)); star.closeSubpath()
            context.fill(star,with: .color(.white))
        }.allowsHitTesting(false)
    }
}

private extension Color {
    static func music(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16)&255)/255,green: Double((hex >> 8)&255)/255,blue: Double(hex&255)/255)
    }
}
