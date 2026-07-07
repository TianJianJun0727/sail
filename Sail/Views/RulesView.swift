import SwiftUI
import UniformTypeIdentifiers

/// 规则页：分「我的规则」（自定义编辑）、「订阅规则」（导入缓存，只读）与「生效规则」（内核当前实际加载，只读）。
struct RulesView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("我的规则").tag(0)
                Text("订阅规则").tag(1)
                Text("生效规则").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 360)
            .pageTopBar()
            Divider()
            switch tab {
            case 0: CustomRulesPane()
            case 1: SubscriptionRulesView()
            default: EffectiveRulesView()
            }
        }
    }
}

/// 我的规则：用户手动维护的分流规则（域名/IP → 代理/直连/拦截）。
private struct CustomRulesPane: View {
    @State private var store = RuleStore.shared
    @State private var editing: RoutingRule?
    @State private var adding = false
    @State private var search = ""
    @State private var draggingRuleID: UUID?
    @State private var dropTargetID: UUID?

    private var filtered: [RoutingRule] {
        guard !search.isEmpty else { return store.rules }
        return store.rules.filter {
            $0.value.localizedCaseInsensitiveContains(search)
                || $0.match.label.localizedCaseInsensitiveContains(search)
                || $0.action.label.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if store.rules.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    RuleListHeader(
                        count: filtered.count,
                        summary: "手动维护，优先匹配。",
                        searchPlaceholder: "搜索规则",
                        search: $search
                    ) {
                        Button {
                            adding = true
                        } label: {
                            Label("添加", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                        }
                            .help("添加规则")
                    }
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { rule in
                                NativeRuleRow(
                                    rule: rule,
                                    isDragging: draggingRuleID == rule.id,
                                    isDropTarget: dropTargetID == rule.id && draggingRuleID != rule.id,
                                    onDragStart: {
                                        draggingRuleID = rule.id
                                        return NSItemProvider(object: rule.id.uuidString as NSString)
                                    },
                                    onEdit: { editing = rule }
                                )
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: RuleListDropDelegate(
                                        targetID: rule.id,
                                        visibleIDs: filtered.map(\.id),
                                        draggingID: $draggingRuleID,
                                        dropTargetID: $dropTargetID,
                                        store: store
                                    )
                                )
                                if rule.id != filtered.last?.id {
                                    RuleListDivider()
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("添加规则")
            }
        }
        .sheet(isPresented: $adding) {
            RuleEditSheet(rule: RoutingRule()) { store.add($0) }
        }
        .sheet(item: $editing) { rule in
            RuleEditSheet(rule: rule) { store.update($0) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 88, height: 88)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                Text("还没有手动规则")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("为指定域名 / IP 指定走代理、直连或拦截")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { adding = true } label: {
                Label("添加规则", systemImage: "plus").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

nonisolated private func ruleKindLabel(_ kind: String, value: String = "") -> String {
    if kind == "rule_set" {
        if value.hasPrefix("geosite-") { return RuleMatch.geosite.label }
        if value.hasPrefix("geoip-") { return RuleMatch.geoip.label }
        return RuleMatch.ruleSetURL.label
    }
    if let match = RuleMatch(singBoxKey: kind) {
        return match.label
    }
    return switch kind {
    case "ip_is_private": RuleMatch.geoip.label
    case "port_range": "端口范围"
    case "source_ip_cidr": "源 IP 段"
    case "sniff": "嗅探"
    case "hijack-dns": "DNS 劫持"
    case "logical": RuleMatch.inline.label
    case "rule": "规则"
    default: kind
    }
}

nonisolated private func ruleTargetLabel(_ target: String) -> String {
    if let action = RuleAction(rawValue: target) {
        return action.label
    }
    return switch target {
    case "sniff": "嗅探"
    case "hijack-dns": "DNS 劫持"
    default: target
    }
}

nonisolated private func stripRuleSetPrefix(_ value: String) -> String {
    if value.hasPrefix("geosite-") { return String(value.dropFirst("geosite-".count)) }
    if value.hasPrefix("geoip-") { return String(value.dropFirst("geoip-".count)) }
    return value
}

private enum RuleListMetrics {
    static let horizontalPadding: CGFloat = 24
    static let interactiveContentPadding: CGFloat = 16
}

private struct RuleListDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, RuleListMetrics.horizontalPadding)
    }
}

private struct RuleListHeader<Trailing: View>: View {
    let count: Int
    let summary: String
    let searchPlaceholder: String
    @Binding var search: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            HStack {
                HStack(spacing: 10) {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    trailing()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4), in: Capsule())
            .frame(width: 260)
        }
        .pageTopBar()
    }
}

private extension RuleListHeader where Trailing == EmptyView {
    init(count: Int, summary: String, searchPlaceholder: String, search: Binding<String>) {
        self.count = count
        self.summary = summary
        self.searchPlaceholder = searchPlaceholder
        self._search = search
        self.trailing = { EmptyView() }
    }
}

private struct RuleListRow: View {
    let title: String
    let subtitle: String
    let target: String
    let targetColor: Color
    var isEnabled = true
    private let leading: AnyView
    private let actions: AnyView

    init<Leading: View, Actions: View>(
        title: String,
        subtitle: String,
        target: String,
        targetColor: Color,
        isEnabled: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.target = target
        self.targetColor = targetColor
        self.isEnabled = isEnabled
        self.leading = AnyView(leading())
        self.actions = AnyView(actions())
    }

    init(
        title: String,
        subtitle: String,
        target: String,
        targetColor: Color,
        isEnabled: Bool = true
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            target: target,
            targetColor: targetColor,
            isEnabled: isEnabled,
            leading: { EmptyView() },
            actions: { EmptyView() }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "（空）" : title)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(target)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(targetColor.opacity(0.15), in: Capsule())
                .foregroundStyle(targetColor)
                .lineLimit(1)
            actions
        }
        .padding(.horizontal, RuleListMetrics.interactiveContentPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
        .background(Color.clear)
        .padding(.horizontal, RuleListMetrics.horizontalPadding)
    }
}

private func ruleTargetColor(_ target: String) -> Color {
    switch target {
    case "direct": .blue
    case "proxy": .accentColor
    case "reject": .red
    case "sniff", "hijack-dns": .secondary
    default: .orange
    }
}

private func ruleListPlaceholder(_ title: String, _ desc: String, system: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: system).font(.system(size: 30)).foregroundStyle(.tertiary)
        VStack(spacing: 4) {
            Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(desc).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
}

// MARK: - 订阅规则（只读，来自 subrules/<subscription>/route.json）

private struct SubscriptionRulesView: View {
    @State private var subscriptions = SubscriptionStore.shared
    @State private var settings = SettingsStore.shared
    @State private var search = ""

    private struct SubRule: Identifiable {
        let id = UUID()
        let kind: String
        let value: String
        let rawValue: String
        let target: String
        var kindLabel: String { ruleKindLabel(kind, value: rawValue) }
        var targetLabel: String { ruleTargetLabel(target) }
    }

    private var imported: (rules: [[String: Any]], ruleSet: [[String: Any]], final: String?, groups: [[String: Any]])? {
        guard settings.importSubscriptionRules,
              let sub = subscriptions.selectedSubscription else { return nil }
        return ClashRuleImport.importedRoute(dir: SubscriptionStore.subrulesDir(sub.id))
    }

    private var rows: [SubRule] {
        guard let imported else { return [] }
        return imported.rules.map(Self.describeRule)
    }

    private var filtered: [SubRule] {
        guard !search.isEmpty else { return rows }
        return rows.filter {
            $0.kind.localizedCaseInsensitiveContains(search)
                || $0.kindLabel.localizedCaseInsensitiveContains(search)
                || $0.value.localizedCaseInsensitiveContains(search)
                || $0.rawValue.localizedCaseInsensitiveContains(search)
                || $0.target.localizedCaseInsensitiveContains(search)
                || $0.targetLabel.localizedCaseInsensitiveContains(search)
        }
    }

    private var currentSubscription: Subscription? {
        subscriptions.selectedSubscription
    }

    private var refreshing: Bool {
        currentSubscription.map { subscriptions.isBusy($0.id) } ?? false
    }

    var body: some View {
        Group {
            if !settings.importSubscriptionRules {
                ruleListPlaceholder("未开启订阅规则", "到「设置 > 高级」开启「应用订阅自带规则」并刷新订阅后查看", system: "switch.2")
            } else if subscriptions.selectedSubscription == nil {
                ruleListPlaceholder("未选择订阅", "选择一个 Clash/Stash 订阅后查看其导入规则", system: "tray")
            } else {
                // 只要已选择订阅且开启导入，就始终显示 header（包含刷新按钮）
                VStack(spacing: 0) {
                    header
                    Divider()
                    if imported == nil {
                        // 缓存不存在或已清空，显示空状态（刷新按钮仍在 header 中可用）
                        ruleListPlaceholder("暂无订阅规则", "刷新当前订阅后会生成导入规则缓存", system: "arrow.triangle.branch")
                    } else if rows.isEmpty {
                        // 缓存存在但无规则
                        ruleListPlaceholder("暂无订阅规则", "当前订阅没有可展示的 rules", system: "tray")
                    } else {
                        list
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        RuleListHeader(
            count: filtered.count,
            summary: "从当前订阅导入，只读。",
            searchPlaceholder: "搜索规则",
            search: $search
        ) {
            Button {
                guard let sub = currentSubscription else { return }
                Task { await subscriptions.refresh(sub.id, viaProxy: sub.updateViaProxy) }
            } label: {
                if refreshing {
                    HStack(spacing: 6) {
                        Spinner(size: 12)
                        Text("刷新")
                    }
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
            }
            .disabled(currentSubscription == nil || refreshing)
            .help("刷新当前订阅并重新导入规则")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, r in
                    RuleListRow(
                        title: r.value.isEmpty ? r.kindLabel : r.value,
                        subtitle: r.value.isEmpty ? "规则" : r.kindLabel,
                        target: r.targetLabel,
                        targetColor: ruleTargetColor(r.target)
                    )
                    if idx < filtered.count - 1 {
                        RuleListDivider()
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    nonisolated private static func describeRule(_ rule: [String: Any]) -> SubRule {
        let target: String
        if let outbound = rule["outbound"] as? String {
            target = outbound
        } else if let action = rule["action"] as? String {
            target = action == "reject" ? "reject" : action
        } else {
            target = "proxy"
        }
        let keys = ["rule_set", "domain", "domain_suffix", "domain_keyword", "ip_cidr",
                    "process_name", "source_ip_cidr", "port", "port_range", "protocol"]
        for key in keys {
            if let value = rule[key] {
                let rawValue = describeValue(value)
                return SubRule(kind: key, value: displayValue(rawValue, for: key), rawValue: rawValue, target: target)
            }
        }
        if (rule["ip_is_private"] as? Bool) == true {
            return SubRule(kind: "ip_is_private", value: "private", rawValue: "ip_is_private=true", target: target)
        }
        let rawValue = describeValue(rule)
        return SubRule(kind: "rule", value: rawValue, rawValue: rawValue, target: target)
    }

    nonisolated private static func describeValue(_ value: Any) -> String {
        if let values = value as? [String] { return values.joined(separator: ", ") }
        if let values = value as? [Int] { return values.map(String.init).joined(separator: ", ") }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(value)"
    }

    nonisolated private static func displayValue(_ text: String, for key: String) -> String {
        guard key == "rule_set" else { return text }
        return stripRuleSetPrefix(text)
    }
}

// MARK: - 生效规则（只读，来自 clash_api /rules）

private struct EffectiveRulesView: View {
    @State private var runner = KernelRunner.shared
    @State private var rules: [EffRule] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    struct EffRule: Identifiable {
        let id = UUID()
        let kind: String      // 如 domain_suffix / rule_set / ip_is_private
        let value: String     // 等号右侧；动作型规则为空
        let rawValue: String
        let target: String    // 去向：direct / proxy / sniff / reject …
        var kindLabel: String { ruleKindLabel(kind, value: rawValue) }
        var targetLabel: String { ruleTargetLabel(target) }
    }

    private var filtered: [EffRule] {
        guard !search.isEmpty else { return rules }
        return rules.filter {
            $0.value.localizedCaseInsensitiveContains(search)
                || $0.kind.localizedCaseInsensitiveContains(search)
                || $0.kindLabel.localizedCaseInsensitiveContains(search)
                || $0.target.localizedCaseInsensitiveContains(search)
                || $0.targetLabel.localizedCaseInsensitiveContains(search)
                || $0.rawValue.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if !runner.isRunning {
                ruleListPlaceholder("内核未运行", "启动内核后这里显示当前生效的最终规则", system: "bolt.horizontal.circle")
            } else if let error {
                ruleListPlaceholder("读取失败", error, system: "exclamationmark.triangle")
            } else if rules.isEmpty && !loading {
                ruleListPlaceholder("暂无生效规则", "内核未加载任何路由规则", system: "tray")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: runner.isRunning) { await reload() }
    }

    private var header: some View {
        RuleListHeader(
            count: filtered.count,
            summary: "内核当前加载的最终规则。",
            searchPlaceholder: "搜索规则",
            search: $search
        ) {
            Button { Task { await reload() } } label: {
                if loading {
                    HStack(spacing: 6) {
                        Spinner(size: 12)
                        Text("刷新")
                    }
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
            }
            .help("刷新")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, r in
                    RuleListRow(
                        title: r.value.isEmpty ? r.kindLabel : r.value,
                        subtitle: r.value.isEmpty ? "规则" : r.kindLabel,
                        target: r.targetLabel,
                        targetColor: ruleTargetColor(r.target)
                    )
                    if idx < filtered.count - 1 {
                        RuleListDivider()
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    @MainActor private func reload() async {
        guard runner.isRunning, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            rules = try await Self.fetch()
        } catch {
            self.error = "无法读取 clash_api /rules：\(error.localizedDescription)"
        }
    }

    // MARK: 拉取 /rules

    nonisolated private struct Payload: Decodable { let rules: [Item] }
    nonisolated private struct Item: Decodable { let type: String; let payload: String; let proxy: String }

    nonisolated private static func fetch() async throws -> [EffRule] {
        guard let url = URL(string: "http://127.0.0.1:\(TrafficMonitor.apiPort)/rules") else { return [] }
        let (data, resp) = try await session.data(for: ClashAPI.request(url, timeout: 5))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return decoded.rules.map { item in
            // payload 形如 "domain_suffix=example.com"；动作型（sniff）payload 为空
            let kind: String, value: String
            if let eq = item.payload.firstIndex(of: "=") {
                kind = String(item.payload[..<eq])
                value = String(item.payload[item.payload.index(after: eq)...])
            } else {
                kind = item.payload.isEmpty ? item.type : item.payload
                value = ""
            }
            // proxy 形如 "route(direct)" / "sniff" / "reject" → 取括号内或原值
            var target = item.proxy
            if let l = target.firstIndex(of: "("), let r = target.lastIndex(of: ")"), l < r {
                target = String(target[target.index(after: l)..<r])
            }
            return EffRule(kind: kind, value: displayValue(value, for: kind), rawValue: value, target: target)
        }
    }

    nonisolated private static func displayValue(_ value: String, for kind: String) -> String {
        if kind == "ip_is_private" { return "private" }
        guard kind == "rule_set" else { return value }
        return stripRuleSetPrefix(value)
    }

    nonisolated private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        return URLSession(configuration: cfg)
    }()
}

// MARK: - 我的规则行

private struct NativeRuleRow: View {
    let rule: RoutingRule
    var isDragging: Bool
    var isDropTarget: Bool
    var onDragStart: () -> NSItemProvider
    var onEdit: () -> Void
    @State private var store = RuleStore.shared
    @State private var hovering = false
    @State private var hoveringHandle = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .opacity(hovering ? 1 : 0)
                .onHover { inside in
                    hoveringHandle = inside
                    if inside {
                        NSCursor.openHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onDrag {
                    NSCursor.closedHand.set()
                    return onDragStart()
                }
                .help("拖拽排序")
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.value.isEmpty ? "（空）" : rule.value)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rule.match.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(rule.targetLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(ruleTargetColor(rule.targetColorKey).opacity(0.15), in: Capsule())
                .foregroundStyle(ruleTargetColor(rule.targetColorKey))
                .lineLimit(1)
            if hovering {
                HStack(spacing: 8) {
                    Button { onEdit() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .help("编辑")
                    Button(role: .destructive) { store.remove(rule.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .help("删除")
                }
                .frame(width: 64, alignment: .trailing)
            } else {
                Color.clear.frame(width: 64, height: 1)
            }
        }
        .padding(.horizontal, RuleListMetrics.interactiveContentPadding)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(rule.enabled ? (isDragging ? 0.45 : 1) : 0.45)
        .background(
            Group {
                if isDropTarget {
                    Color.accentColor.opacity(0.12)
                } else if hovering {
                    Color(nsColor: .quaternaryLabelColor).opacity(0.25)
                } else {
                    Color.clear
                }
            }
        )
        .padding(.horizontal, RuleListMetrics.horizontalPadding)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onEdit() }   // 双击编辑；日常也可用悬停出现的铅笔按钮
    }
}

private struct RuleListDropDelegate: DropDelegate {
    let targetID: UUID
    let visibleIDs: [UUID]
    @Binding var draggingID: UUID?
    @Binding var dropTargetID: UUID?
    let store: RuleStore

    func dropEntered(info: DropInfo) {
        guard draggingID != nil else { return }
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID {
            dropTargetID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
            NSCursor.openHand.set()
        }
        guard let draggingID,
              draggingID != targetID,
              let from = visibleIDs.firstIndex(of: draggingID),
              let target = visibleIDs.firstIndex(of: targetID) else { return false }
        let toOffset = target > from ? target + 1 : target
        store.moveVisible(visibleIDs, fromOffsets: IndexSet(integer: from), toOffset: toOffset)
        return true
    }
}

// MARK: - 添加 / 编辑弹窗

private struct RuleEditSheet: View {
    @State var rule: RoutingRule
    var onSave: (RoutingRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var proxyGroups = ProxyGroupStore.shared

    private let directDestination = "__builtin_direct__"
    private let rejectDestination = "__builtin_reject__"
    private let proxyDestination = "__builtin_proxy__"

    private var groupNames: [String] {
        proxyGroups.groups.map(\.name)
    }

    private var destinationSelection: Binding<String> {
        Binding {
            if let outbound = rule.outbound?.trimmingCharacters(in: .whitespaces), !outbound.isEmpty {
                return groupKey(outbound)
            }
            switch rule.action {
            case .direct: return directDestination
            case .reject: return rejectDestination
            case .proxy:
                if groupNames.contains(proxyGroups.masterGroupName) { return groupKey(proxyGroups.masterGroupName) }
                if let first = groupNames.first { return groupKey(first) }
                return proxyDestination
            }
        } set: { value in
            switch value {
            case directDestination:
                rule.action = .direct
                rule.outbound = nil
            case rejectDestination:
                rule.action = .reject
                rule.outbound = nil
            case proxyDestination:
                rule.action = .proxy
                rule.outbound = nil
            default:
                if let group = parseGroupKey(value) {
                    rule.action = .proxy
                    rule.outbound = group
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("分流规则").font(.system(size: 16, weight: .semibold, design: .rounded))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("匹配方式").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(RuleMatch.allCases) { m in matchChip(m) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("内容").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if rule.match.isInline, !rule.value.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(inlineValid ? "JSON 合法" : "JSON 语法错误",
                              systemImage: inlineValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(inlineValid ? .green : .red)
                    }
                }
                if rule.match.isInline {
                    TextEditor(text: $rule.value)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
                } else {
                    TextField(rule.match.placeholder, text: $rule.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focused)
                }
                if let hint = rule.match.hint {
                    Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("去向").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: destinationSelection) {
                    Text(RuleAction.direct.label).tag(directDestination)
                    Text(RuleAction.reject.label).tag(rejectDestination)
                    if groupNames.isEmpty {
                        Text("代理（暂无分组）").tag(proxyDestination)
                    } else {
                        Divider()
                        ForEach(groupNames, id: \.self) { group in
                            Text(group).tag(groupKey(group))
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
                if rule.match.isInline {
                    Text("若 JSON 已自带 outbound / action，此处选择将被忽略。").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if groupNames.isEmpty {
                    Text("当前订阅没有可用代理分组；选择代理时规则会在无代理出站时被跳过。").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rule.value.trimmingCharacters(in: .whitespaces).isEmpty || (rule.match.isInline && !inlineValid))
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            DispatchQueue.main.async { focused = false }
            Task {
                if KernelRunner.shared.isRunning {
                    await proxyGroups.refresh()
                } else {
                    proxyGroups.loadPersisted()
                }
            }
        }
    }

    /// INLINE 内容是否为合法 JSON 对象。
    private var inlineValid: Bool {
        guard let d = rule.value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) is [String: Any]
    }

    private func matchChip(_ m: RuleMatch) -> some View {
        let on = rule.match == m
        return Button {
            rule.match = m
        } label: {
            Text(m.label)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7).padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
                .foregroundStyle(on ? Color.white : .primary)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: on)
    }

    private func groupKey(_ group: String) -> String {
        "__group__\(group)"
    }

    private func parseGroupKey(_ key: String) -> String? {
        guard key.hasPrefix("__group__") else { return nil }
        return String(key.dropFirst("__group__".count))
    }
}

#Preview {
    RulesView().frame(width: 760, height: 520)
}
