import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 内核运行日志页面：实时展示 sing-box 输出，支持自动滚动、复制、导出与清空。
struct LogsView: View {
    private let runner = KernelRunner.shared
    @State private var minLevel: LogLevel = .all
    @State private var searchText = ""
    @State private var atTop = true   // 最新日志在顶部：贴顶才自动跟随，用户下滚后停止（避免打断查看历史）
    @State private var paused = false
    @State private var pausedLogLines: [LogLine] = []

    /// 日志级别过滤：选中具体级别时只显示该级别，不按严重度合并。
    enum LogLevel: Int, CaseIterable, Identifiable {
        case all, trace, debug, info, warn, error, fatal, panic
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .trace: "跟踪"
            case .debug: "调试"
            case .info: "信息"
            case .warn: "警告"
            case .error: "错误"
            case .fatal: "致命"
            case .panic: "崩溃"
            }
        }
        /// 级别编码：trace=1、debug=2、info=3、warn=4、error=5、fatal=6、panic=7。
        var severity: Int {
            switch self {
            case .all: 0
            case .trace: 1
            case .debug: 2
            case .info: 3
            case .warn: 4
            case .error: 5
            case .fatal: 6
            case .panic: 7
            }
        }
    }

    /// 取一行日志的严重度：trace=1、debug=2、info=3、warn=4、error=5、fatal=6、panic=7。
    /// sing-box 带时间戳的格式为 `+0800 2026-… 22:30:04 LEVEL …`；App 自己的方括号前缀日志默认按信息处理。
    /// 内核堆栈续行通常没有独立级别，返回 nil 后由调用方继承上一行级别。
    static func explicitSeverity(of line: String) -> Int? {
        let clean = KernelRunner.stripANSI(line)
        if let severity = appSeverity(of: clean) { return severity }
        let fields = clean.split(whereSeparator: \.isWhitespace).prefix(8)
        for field in fields {
            let token = field.trimmingCharacters(in: .punctuationCharacters).uppercased()
            if let severity = severity(for: token) { return severity }
        }
        return nil
    }

    private static func severity(for token: String) -> Int? {
        switch token {
        case "PANIC": return 7
        case "FATAL": return 6
        case "ERROR": return 5
        case "WARN", "WARNING": return 4
        case "INFO": return 3
        case "DEBUG": return 2
        case "TRACE": return 1
        default: return nil
        }
    }

    private static func appSeverity(of clean: String) -> Int? {
        if clean.hasPrefix("[启动]") || clean.hasPrefix("[TUN]") || clean.hasPrefix("[监测]") {
            if clean.contains("失败") || clean.contains("错误") || clean.contains("异常") {
                return LogLevel.error.severity
            }
            if clean.contains("⚠️") || clean.contains("警告") {
                return LogLevel.warn.severity
            }
            return LogLevel.info.severity
        }
        if clean == "配置无变化，跳过重启" { return LogLevel.info.severity }
        return nil
    }

    private var visibleLogLines: [LogLine] {
        paused ? pausedLogLines : runner.logLines
    }

    /// 暂停期间累积的新日志数量
    private var newLogCountDuringPause: Int {
        guard paused, let pausedLast = pausedLogLines.last else { return 0 }
        return runner.logLines.filter { $0.id > pausedLast.id }.count
    }

    private var levelFiltered: [LogLine] {
        guard minLevel != .all else { return visibleLogLines }
        // 续行（无显式级别）继承上一行级别：否则 error 的多行堆栈会被当「信息」，筛「错误」时丢失关键细节。
        var carried = LogLevel.info.severity
        return visibleLogLines.filter { line in
            let sev = Self.explicitSeverity(of: line.text) ?? carried
            carried = sev
            return sev == minLevel.severity
        }
    }

    private var filtered: [LogLine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return levelFiltered }
        return levelFiltered.filter {
            KernelRunner.stripANSI($0.text).localizedCaseInsensitiveContains(query)
        }
    }

    private var filterDescription: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "没有「\(minLevel.label)」级别的日志"
        }
        if minLevel == .all {
            return "没有包含「\(query)」的日志"
        }
        return "没有「\(minLevel.label)」级别且包含「\(query)」的日志"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if visibleLogLines.isEmpty {
                emptyState
            } else {
                logScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runner.isRunning ? Color.accentColor : Color.secondary)
                .frame(width: 7, height: 7)
            Text(runner.isRunning ? "运行中" : "已停止")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text(filtered.count == visibleLogLines.count ? "\(visibleLogLines.count) 行"
                                                         : "\(filtered.count) / \(visibleLogLines.count) 行")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if paused {
                Text("已暂停")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if newLogCountDuringPause > 0 {
                    Text("(\(newLogCountDuringPause) 条新日志)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("暂停期间有 \(newLogCountDuringPause) 条新日志，点击继续按钮查看")
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 180, height: 26)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("搜索日志内容")

            Picker("", selection: $minLevel) {
                ForEach(LogLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("按日志级别过滤（只显示所选级别）")

            Button { togglePause() } label: {
                Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .disabled(runner.logLines.isEmpty && !paused)
            .help(paused ? "继续刷新日志视图" : "暂停日志视图刷新")

            Button { copyAll() } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .disabled(filtered.isEmpty)

            Button { exportAll() } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(filtered.isEmpty)

            Button { runner.clearLogs() } label: {
                Label("清空", systemImage: "trash")
            }
            .disabled(runner.logLines.isEmpty)
        }
        .pageTopBar()
    }

    private var displayed: [LogLine] {
        filtered.reversed()
    }

    // MARK: 日志列表（最新在前，自动跟随顶部）

    private var logScroll: some View {
        // 外层 GeometryReader 拿视口位置，喂给内层算「内容顶边距视口顶部的距离」→ 判断是否贴顶。
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        Color.clear.frame(height: 1).id("top")
                        ForEach(displayed) { line in
                            Text(ANSI.attributed(line.text))
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        // 内容顶边在视口坐标系的 Y：贴顶≈0，下滚看历史时为负。
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: TopDistanceKey.self,
                                value: inner.frame(in: .named("logScroll")).minY
                            )
                        }
                    )
                    .overlay {
                        if filtered.isEmpty {
                            Text(filterDescription)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                    }
                }
                .coordinateSpace(name: "logScroll")
                .scrollIndicators(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                .onPreferenceChange(TopDistanceKey.self) { dist in
                    // 容差 ~40pt（约两三行）：吸收追加新行时的瞬时抖动，只有真正下滚才停跟随。
                    atTop = dist > -40
                }
                // 监听最后一行的 id 而非行数：日志封顶后行数恒为 800 不变，但新行仍在进来，用 last?.id 才能持续跟随。
                // 仅当用户停在顶部看最新日志时才跟随；下滚查看历史时不打扰。
                .onChange(of: filtered.last?.id) {
                    if atTop { proxy.scrollTo("top", anchor: .top) }
                }
                // 切换过滤级别：视作重新看，跳到顶部并恢复跟随。
                .onChange(of: minLevel) {
                    atTop = true
                    proxy.scrollTo("top", anchor: .top)
                }
                .onChange(of: searchText) {
                    atTop = true
                    proxy.scrollTo("top", anchor: .top)
                }
                .onAppear { proxy.scrollTo("top", anchor: .top) }
                .overlay(alignment: .topTrailing) {
                    if !atTop {
                        Button {
                            atTop = true
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("top", anchor: .top) }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor, in: Circle())
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(14)
                        .help("回到最新日志并继续跟随")
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: atTop)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 4) {
                Text("暂无日志")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(runner.isRunning ? "等待内核输出 …" : "启动内核后将在此显示运行日志")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具

    private func copyAll() {
        // 复制时剥离颜色码，得到纯文本
        let text = plainLogText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.title = "导出日志"
        panel.nameFieldStringValue = "sail-log-\(Self.exportTimestamp()).log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try plainLogText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出日志失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func plainLogText() -> String {
        displayed.map { KernelRunner.stripANSI($0.text) }.joined(separator: "\n")
    }

    private func togglePause() {
        if paused {
            paused = false
            pausedLogLines = []
            atTop = true
        } else {
            pausedLogLines = runner.logLines
            paused = true
        }
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// 日志内容顶边距视口顶部的距离（贴顶≈0，下滚为负），用于判断是否仍跟随最新日志。
private struct TopDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 把含 ANSI SGR 转义序列的字符串解析为带前景色的 AttributedString。
enum ANSI {
    static func attributed(_ line: String) -> AttributedString {
        var result = AttributedString()
        var color: Color? = nil
        var bold = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var seg = AttributedString(buffer)
            if let color { seg.foregroundColor = color }
            if bold { seg.font = .system(size: 11.5, weight: .semibold, design: .monospaced) }
            result += seg
            buffer = ""
        }

        let chars = Array(line)
        var i = 0
        while i < chars.count {
            // ESC '[' … 'm' —— SGR 序列
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                var j = i + 2
                var code = ""
                while j < chars.count, chars[j] != "m" {
                    code.append(chars[j]); j += 1
                }
                apply(code, color: &color, bold: &bold)
                i = (j < chars.count) ? j + 1 : j
            } else {
                buffer.append(chars[i]); i += 1
            }
        }
        flush()
        return result
    }

    private static func apply(_ code: String, color: inout Color?, bold: inout Bool) {
        let parts = code.split(separator: ";").map { Int($0) ?? 0 }
        if parts.isEmpty { color = nil; bold = false; return }
        var k = 0
        while k < parts.count {
            switch parts[k] {
            case 0: color = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 39: color = nil
            case 30...37: color = basic(parts[k] - 30, bright: false)
            case 90...97: color = basic(parts[k] - 90, bright: true)
            case 38:
                if k + 2 < parts.count, parts[k + 1] == 5 {
                    color = xterm256(parts[k + 2]); k += 2
                } else if k + 4 < parts.count, parts[k + 1] == 2 {
                    color = Color(.sRGB,
                                  red: Double(parts[k + 2]) / 255,
                                  green: Double(parts[k + 3]) / 255,
                                  blue: Double(parts[k + 4]) / 255)
                    k += 4
                }
            default: break
            }
            k += 1
        }
    }

    /// 基础 8 色（30-37 / 90-97）——挑选在明暗背景下都清晰的近似色
    private static func basic(_ idx: Int, bright: Bool) -> Color {
        switch idx {
        case 0: return .secondary          // black
        case 1: return .red
        case 2: return .green
        case 3: return .orange             // yellow（白底上偏橙更清晰）
        case 4: return .blue
        case 5: return .purple             // magenta
        case 6: return .teal               // cyan（sing-box 的 INFO 用色）
        default: return .primary           // white
        }
    }

    /// xterm 256 调色板 → sRGB
    private static func xterm256(_ n: Int) -> Color {
        switch n {
        case 0...7: return basic(n, bright: false)
        case 8...15: return basic(n - 8, bright: true)
        case 16...231:
            let i = n - 16
            let r = i / 36, g = (i / 6) % 6, b = i % 6
            func comp(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + v * 40) / 255 }
            return Color(.sRGB, red: comp(r), green: comp(g), blue: comp(b))
        default: // 232...255 灰阶
            let level = Double(8 + (n - 232) * 10) / 255
            return Color(.sRGB, red: level, green: level, blue: level)
        }
    }
}

#Preview {
    LogsView().frame(width: 800, height: 600)
}
