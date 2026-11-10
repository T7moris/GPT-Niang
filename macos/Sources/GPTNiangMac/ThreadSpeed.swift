import AppKit
import SwiftUI
import GPTNiangCore

struct ThreadSpeedRow: Decodable, Identifiable {
    let id: String
    let title: String
    let tokensPerSecond: Double?
    let sampleAt: Double?
    let state: String
    let outputTokens: Int?
    let intervalSeconds: Double?
}
private struct ThreadSpeedResponse: Decodable { let threads: [ThreadSpeedRow]; let error: String? }
@MainActor
final class ThreadSpeedStore: ObservableObject {
    @Published var rows: [ThreadSpeedRow] = []
    @Published var error: String?
    private var language: InterfaceLanguage = .system
    private var process: Process?
    private var output: Pipe?
    private var input: Pipe?
    private var pending = Data()
    private var generation = 0
    func start(model: WidgetModel) {
        language = model.language
        guard process?.isRunning != true else { return }
        guard let node = model.findNode() else { error = model.text("請先安裝 Node.js 20+"); return }
        start(executable: node, arguments: [model.resources.appendingPathComponent("Backend/runtime/thread-speed.mjs").path])
    }
    func start(executable: URL, arguments: [String]) {
        guard process?.isRunning != true else { return }
        rows = []; error = nil
        generation += 1
        let current = generation
        let task = Process(), output = Pipe(), input = Pipe()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = output; task.standardError = FileHandle.nullDevice; task.standardInput = input
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task { @MainActor in self?.ended(current) }
                return
            }
            Task { @MainActor in if self?.generation == current { self?.consume(data) } }
        }
        task.terminationHandler = { [weak self] _ in Task { @MainActor in self?.ended(current) } }
        do { try task.run(); process = task; self.output = output; self.input = input }
        catch { self.error = language.text("聊天速度面板無法啟動：%@", String(describing: error.localizedDescription)); output.fileHandleForReading.readabilityHandler = nil }
    }
    private func consume(_ data: Data) {
        pending.append(data)
        if pending.count > 512 * 1024 { pending.removeAll(); return }
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]; pending.removeSubrange(...end)
            if let response = try? JSONDecoder().decode(ThreadSpeedResponse.self, from: line) { rows = response.threads; error = response.error }
        }
    }
    private func ended(_ current: Int) {
        guard generation == current else { return }
        stop(); rows = []; error = language.text("本機指標程序已結束，請關閉並重新開啟面板。")
    }
    func stop() {
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }; process = nil; output = nil; input = nil; pending.removeAll()
    }
}
struct ThreadSpeedView: View {
    @ObservedObject var store: ThreadSpeedStore
    @ObservedObject var model: WidgetModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("聊天速度")).font(.system(size: 25, weight: .semibold, design: .rounded))
            Text(model.text("輸出 token/s · 記錄區間平均")).font(.headline)
            Text(model.text("以相鄰 token 計數紀錄的輸出增量 ÷ 時間間隔計算，包含推理、網路和工具等待；這不是模型即時解碼速度。只讀取本機資料，每 3 秒更新。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.error { Text(error).foregroundStyle(.orange) }
            List(store.rows) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.state == "running" ? model.text("進行中") : row.state == "idle" ? model.text("已完成") : row.state == "cancelled" ? model.text("已取消") : model.text("本機記錄"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        if let tokens = row.outputTokens, let interval = row.intervalSeconds, let at = row.sampleAt {
                            Text(model.text("%@ 輸出 tokens / %@ 秒 · %@", String(describing: tokens), String(describing: String(format: "%.1f", interval)), String(describing: Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .standard))))
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text(model.text("尚未有兩筆有效計數紀錄")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(row.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("tokens/s").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }.listStyle(.inset)
        }.padding(22).frame(width: 620, height: 580)
    }
}
