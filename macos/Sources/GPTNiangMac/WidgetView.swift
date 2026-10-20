import SwiftUI
import AppKit
import GPTNiangCore

// Coordinates, colors and timing are taken from widget.xaml/widget.ps1 (v1.2.5).
struct WidgetView: View {
    @ObservedObject var model: WidgetModel
    let onDrag: (CGSize) -> Void
    let onSettings: () -> Void
    let onContextMenu: (NSEvent, NSView) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var near: Double = 0
    @State private var tail: Double = 0
    @State private var cloud: Double = 0
    @State private var text: Double = 0
    @State private var displayedMessage: String?
    @State private var animationGeneration = 0
    @State private var sceneGeneration = 0
    @State private var hovering = false
    @State private var frozenPhase: Double = 0
    private let ink = Color(hex: "745A98")
    private let ease = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)
    private let rebound = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.22)

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.colorScope == .none || model.colorPaused || reduceMotion ? 1 : 1 / 30)) { context in
            let phase = model.colorPaused || reduceMotion ? frozenPhase : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
            stage(date: context.date, phase: phase)
        }
        .frame(width: 378 * model.displayScale, height: 378 * model.displayScale, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        .onAppear { animateBubble(model.bubble); displayedMessage = model.message }
        .onChange(of: model.colorPaused) { paused in
            if paused { frozenPhase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6 }
        }
        .onChange(of: reduceMotion) { value in
            if value { frozenPhase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6 }
        }
        .onChange(of: model.bubble) { animateBubble($0) }
        .onChange(of: model.message) { next in
            sceneGeneration += 1
            let generation = sceneGeneration
            if !model.bubble || reduceMotion { displayedMessage = next; return }
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12)) { text = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard generation == sceneGeneration, model.bubble else { return }
                displayedMessage = next
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.16)) { text = 1 }
            }
        }
        .contextMenu {
            Button(model.text("查看額度")) { model.toggleQuota() }
            Button(model.text("刷新額度")) { model.refresh() }
            Button(model.text("來一句語錄")) { model.showQuote() }
            Divider()
            Toggle(model.text("回答结束提醒"), isOn: Binding(get: { model.completionEnabled }, set: { model.completionEnabled = $0; model.savePreferences() }))
            WidgetAudioMenu(audio: model.audio)
            Button(model.text("設定…"), action: onSettings)
            Button(model.text("退出 GPT 娘")) { NSApp.terminate(nil) }
        }
    }
    private func stage(date: Date, phase: Double) -> some View {
        let mirrored = model.facingLeft
        return ZStack(alignment: .topLeading) {
            OriginalBubbleShape().fill(style("surface", phase: phase))
                .overlay(OriginalBubbleShape().stroke(style("accent", phase: phase), lineWidth: 4))
                .frame(width: 350, height: 239)
                .scaleEffect(0.7 + 0.3 * cloud, anchor: UnitPoint(x: 0.4425, y: 0.36)).opacity(cloud)
                .contentShape(OriginalBubbleShape()).onTapGesture { model.clickBubble() }
                .allowsHitTesting(model.bubble)
            Ellipse().fill(style("surface", phase: phase)).overlay(Ellipse().stroke(style("accent", phase: phase), lineWidth: 4))
                .frame(width: 25, height: 18).scaleEffect(0.7 + 0.3 * tail).opacity(tail)
                .offset(x: 108, y: 182).onTapGesture { model.clickBubble() }.allowsHitTesting(model.bubble)
            Ellipse().fill(style("surface", phase: phase)).overlay(Ellipse().stroke(style("accent", phase: phase), lineWidth: 4))
                .frame(width: 17, height: 12).scaleEffect(0.7 + 0.3 * near).opacity(near)
                .offset(x: 142, y: 214).onTapGesture { model.clickBubble() }.allowsHitTesting(model.bubble)
            scene(now: date, phase: phase)
                .frame(width: displayedMessage == nil ? 184 : 218, height: displayedMessage == nil ? 115 : 126)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .opacity(text).offset(x: displayedMessage == nil ? 63 : 46, y: displayedMessage == nil ? 22 : 22)
                .allowsHitTesting(model.bubble).contentShape(Rectangle()).onTapGesture { model.clickBubble() }
            if model.bubble && displayedMessage == nil {
                Button { model.refresh(renewBubble: true) } label: { Image(systemName: model.refreshing ? "hourglass" : "arrow.clockwise").font(.system(size: 12)).foregroundStyle(style("ink", phase: phase)) }
                    .buttonStyle(.plain).disabled(model.refreshing).frame(width: 20, height: 20)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1).opacity(text).offset(x: 184, y: 20)
                    .help(model.text("立即刷新額度")).accessibilityLabel(model.text("刷新額度"))
            }
            if let image = model.characterImage {
                let girl = Image(nsImage: image).resizable().interpolation(.high).scaledToFill().frame(width: 208, height: 208)
                ZStack {
                    if model.colorScope == .full { Rectangle().fill(style("accent", phase: phase)).mask(girl).opacity(0.62).blur(radius: 7) }
                    girl
                    if model.colorScope == .full { Rectangle().fill(style("accent", phase: phase)).mask(girl).opacity(0.34).allowsHitTesting(false) }
                }
                .frame(width: 208, height: 208).contentShape(Rectangle())
                .overlay(CharacterInteraction(onPress: { down in
                    model.interactionActive = down
                    withAnimation(reduceMotion ? nil : rebound) { pressed = down }
                    model.play(down ? "press" : "release")
                }, onDrag: { translation in
                    onDrag(translation)
                    if translation == .zero { model.savePreferences() }
                }, onClick: { model.characterClick() }, onMenu: onContextMenu))
                .onHover { hovering = $0 }.offset(x: 142, y: 142)
                .accessibilityElement().accessibilityLabel(model.text("GPT 娘：點擊查看額度，拖動調整位置"))
                .accessibilityAddTraits(.isButton).accessibilityAction { model.characterClick() }
            }
            if hovering && !model.hideMenu {
                Button(action: onSettings) { Image(systemName: "line.3.horizontal").font(.system(size: 15)).foregroundStyle(ink).frame(width: 24, height: 24).background(Color(hex: "EDE7F6"), in: RoundedRectangle(cornerRadius: 6)) }
                    .buttonStyle(.plain).scaleEffect(x: mirrored ? -1 : 1, y: 1).offset(x: 320, y: 162)
                    .help(model.text("掛件設定")).accessibilityLabel(model.text("掛件設定"))
            }
        }
        .frame(width: 350, height: 350, alignment: .topLeading)
        .scaleEffect(x: pressed ? 1.05 : 1, y: pressed ? 0.88 : 1, anchor: .bottom)
        .scaleEffect(x: mirrored ? -1 : 1, y: 1, anchor: .bottom)
        .padding(14).scaleEffect(model.displayScale, anchor: .topLeading)
    }
    private func scene(now: Date, phase: Double) -> some View {
        Group {
            if let quote = displayedMessage {
                if model.isCompletionMessage {
                    VStack(spacing: 0) { Text("Codex"); Text(model.text("有回复已结束")) }.font(.system(size: 30, weight: .bold)).lineLimit(1).fixedSize().foregroundStyle(ink)
                } else {
                Text(quote).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.3).lineLimit(6).padding(.horizontal, 12)
                    .foregroundStyle(model.colorScope == .none ? AnyShapeStyle(ink) : style("ink", phase: phase))
                    .help(quote)
                }
            } else {
                VStack(spacing: 2) {
                    Text(quotaTitle(now: now)).font(.system(size: 12, weight: .semibold)).foregroundStyle(style("ink", phase: phase))
                        .help(quotaDetails(now: now))
                    if model.snapshot.displayWindows.isEmpty {
                        Text(model.snapshot.error ?? model.text("目前帳戶未提供額度視窗"))
                            .font(.system(size: 12)).foregroundStyle(Color(hex: "7D6B91")).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(model.snapshot.displayWindows) { window in
                            VStack(spacing: 1) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(window.title(language: model.language)).font(.system(size: 13))
                                        Text(model.text(window.expired(at: now) ? "上次 %@%%" : "已用 %@%%", String(format: "%.1f", 100-window.remaining).replacingOccurrences(of: ".0", with: "")))
                                            .font(.system(size: 9))
                                    }.foregroundStyle(Color(hex: "76638D"))
                                    Spacer()
                                    Text(window.expired(at: now) ? "—" : "\(window.percentageText)%")
                                        .font(.system(size: 24, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(quotaStyle(window, now: now, phase: phase))
                                }.frame(height: 25)
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color(hex: "EAE4F3"))
                                        Capsule().fill(quotaStyle(window, now: now, phase: phase))
                                            .frame(width: geometry.size.width * (window.expired(at: now) ? 0 : max(0, min(1, window.remaining / 100))))
                                    }
                                }.frame(height: 4)
                                Text(window.resetText(at: now, countdown: now.timeIntervalSince(model.sceneStarted) < 2, language: model.language))
                                    .font(.system(size: 11)).foregroundStyle(Color(hex: "7D6B91"))
                                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).minimumScaleFactor(0.85)
                            }
                        }
                        if model.snapshot.stale(at: now) {
                            Text(model.text("舊快照 · 刷新後確認")).font(.system(size: 9)).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
    private func quotaTitle(now: Date) -> String {
        if !model.snapshot.ok { return model.text("暂无法读取") }
        return model.snapshot.stale(at: now) ? model.text("上次剩余额度") : model.text("剩餘額度")
    }
    private func quotaDetails(now: Date) -> String {
        var rows = [model.text("目前方案：%@", model.snapshot.planLabel ?? model.text("未知套餐"))]
        for window in model.snapshot.validWindows {
            rows.append("\(window.title(language: model.language))：\(window.percentageText)% · \(window.resetText(at: now, language: model.language))")
            if window.isIndividual {
                rows.append(model.text("个人额度，非公司总余额"))
                if let total = window.total, let used = window.amountUsed, total.isFinite, used.isFinite {
                    rows.append(model.text("已用 %@ / %@", String(used), String(total)))
                }
            }
        }
        if let at = model.snapshot.observedAt, at.isFinite {
            rows.append(model.text("更新时间：%@", Date(timeIntervalSince1970: at/1000).formatted(date: .abbreviated, time: .standard)))
        }
        if let error = model.snapshot.error { rows.append(error) }
        return rows.joined(separator: "\n")
    }
    private func quotaStyle(_ window: QuotaWindow, now: Date, phase: Double) -> AnyShapeStyle {
        if window.expired(at: now) { return AnyShapeStyle(Color(hex: "95889F")) }
        if window.remaining <= 10 { return AnyShapeStyle(Color(hex: "B74839")) }
        if window.remaining <= 25 { return AnyShapeStyle(Color(hex: "A06C1C")) }
        return model.colorScope == .full ? style("ink", phase: phase) : AnyShapeStyle(ink)
    }
    private func style(_ role: String, phase: Double) -> AnyShapeStyle {
        guard model.colorScope == .full || (model.colorScope == .text && role == "ink") else {
            return AnyShapeStyle(role == "surface" ? Color.white : ink)
        }
        let colors = Appearance.palette(for: model.message ?? "", rainbow: model.colorMode == .rainbow || model.message == nil)
        let loop = Array(colors.dropLast())
        let repeated = loop + loop + loop + [colors.last!]
        let stops = repeated.enumerated().map { index, hex in Gradient.Stop(color: Color(hex: hex, role: role), location: Double(index) / Double(repeated.count - 1)) }
        return AnyShapeStyle(LinearGradient(gradient: Gradient(stops: stops), startPoint: UnitPoint(x: -1 - phase, y: 0.5), endPoint: UnitPoint(x: 2 - phase, y: 0.5)))
    }
    private func animateBubble(_ opening: Bool) {
        animationGeneration += 1; sceneGeneration += 1
        let generation = animationGeneration
        if reduceMotion { near = opening ? 1 : 0; tail = near; cloud = near; text = near; return }
        if opening {
            displayedMessage = model.message
            near = 0; tail = 0; cloud = 0; text = 0
            for (delay, part) in [(0.0, 0), (0.13, 1), (0.26, 2), (0.36, 3)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard generation == animationGeneration, model.bubble else { return }
                    withAnimation(part == 3 ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.16) : ease) {
                        switch part { case 0: near = 1; case 1: tail = 1; case 2: cloud = 1; default: text = 1 }
                    }
                }
            }
        } else {
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.16)) { text = 0 }
            for (delay, part) in [(0.1, 2), (0.2, 1), (0.3, 0)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard generation == animationGeneration, !model.bubble else { return }
                    withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.18)) {
                        switch part { case 0: near = 0; case 1: tail = 0; default: cloud = 0 }
                    }
                }
            }
        }
    }
}

private extension Color {
    init(hex: String, role: String = "accent") {
        let value = UInt64(hex, radix: 16) ?? 0
        var components = [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { $0 / 255 }
        let other = role == "surface" ? [1.0, 1, 1] : [39.0 / 255, 25.0 / 255, 56.0 / 255]
        let amount = role == "surface" ? 0.92 : role == "ink" ? 0.44 : 0
        for index in 0..<3 { components[index] = components[index] * (1 - amount) + other[index] * amount }
        self.init(red: components[0], green: components[1], blue: components[2])
    }
}
