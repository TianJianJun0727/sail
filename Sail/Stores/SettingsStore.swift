import Foundation
import Observation
import AppKit

/// 应用主题外观：跟随系统 / 强制浅色 / 强制深色。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    /// 对应的 NSAppearance；系统为 nil（跟随系统）。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 常用 DNS 服务。更复杂的 servers/rules 仍通过 Mixin 覆盖。
enum DNSProvider: String, CaseIterable, Identifiable, Codable {
    case system
    case alidnsDoh, alidnsUdp
    case dnspodDoh, dnspodUdp
    case cloudflareDoh, cloudflareUdp
    case googleDoh, googleUdp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "系统 DNS"
        case .alidnsDoh: "阿里 DoH"
        case .alidnsUdp: "阿里 UDP"
        case .dnspodDoh: "腾讯 DNSPod DoH"
        case .dnspodUdp: "腾讯 DNSPod UDP"
        case .cloudflareDoh: "Cloudflare DoH"
        case .cloudflareUdp: "Cloudflare UDP"
        case .googleDoh: "Google DoH"
        case .googleUdp: "Google UDP"
        }
    }

    func server(tag: String, detour: String? = nil, domainResolver: String? = "bootstrap") -> [String: Any] {
        if self == .system { return ["tag": tag, "type": "local"] }
        var object: [String: Any] = ["tag": tag]
        switch self {
        case .alidnsDoh:
            object.merge(doh(server: "dns.alidns.com", domainResolver: domainResolver)) { _, new in new }
        case .dnspodDoh:
            object.merge(doh(server: "doh.pub", domainResolver: domainResolver)) { _, new in new }
        case .cloudflareDoh:
            object.merge(doh(server: "cloudflare-dns.com", domainResolver: domainResolver)) { _, new in new }
        case .googleDoh:
            object.merge(doh(server: "dns.google", domainResolver: domainResolver)) { _, new in new }
        case .alidnsUdp:
            object.merge(udp(server: "223.5.5.5")) { _, new in new }
        case .dnspodUdp:
            object.merge(udp(server: "119.29.29.29")) { _, new in new }
        case .cloudflareUdp:
            object.merge(udp(server: "1.1.1.1")) { _, new in new }
        case .googleUdp:
            object.merge(udp(server: "8.8.8.8")) { _, new in new }
        case .system: break
        }
        if let detour { object["detour"] = detour }
        return object
    }

    private func doh(server: String, domainResolver: String?) -> [String: Any] {
        var object: [String: Any] = [
            "type": "https",
            "server": server,
            "server_port": 443,
            "path": "/dns-query",
        ]
        if let domainResolver { object["domain_resolver"] = domainResolver }
        return object
    }

    private func udp(server: String) -> [String: Any] {
        [
            "type": "udp",
            "server": server,
            "server_port": 53,
        ]
    }

    /// 是否适合作为 bootstrap DNS（不需要域名解析的 DNS）
    /// Bootstrap DNS 用于解析其他 DNS 服务器的域名，因此不能自身依赖域名解析。
    var isBootstrapSafe: Bool {
        switch self {
        case .system, .alidnsUdp, .dnspodUdp, .cloudflareUdp, .googleUdp:
            return true  // 系统 DNS 和 UDP DNS 不需要域名解析
        case .alidnsDoh, .dnspodDoh, .cloudflareDoh, .googleDoh:
            return false  // DoH 需要先解析 DNS 服务器域名
        }
    }
}

/// 指定域名匹配使用指定 DNS。普通域名、*.domain、+.domain 都会转成 domain_regex。
struct DomainDNSRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var provider: DNSProvider = .system
    var patterns: [String] = []
    var suffixes: [String] = []
    var regexes: [String] = []
}

/// 域名 DNS 输入校验结果。invalid 非空时 UI 不应保存，避免把用户草稿静默丢弃。
struct DomainDNSMatcherValidation: Equatable {
    var patterns: [String] = []
    var suffixes: [String] = []
    var regexes: [String] = []
    var invalid: [String] = []

    var isValid: Bool { invalid.isEmpty && !patterns.isEmpty && !regexes.isEmpty }
}

/// sing-box 内核日志级别。
enum KernelLogLevel: String, CaseIterable, Identifiable, Codable {
    case trace, debug, info, warn, error, fatal, panic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .trace: "跟踪"
        case .debug: "调试"
        case .info: "信息"
        case .warn: "警告"
        case .error: "错误"
        case .fatal: "致命"
        case .panic: "崩溃"
        }
    }
}

/// TUN 虚拟网卡详细配置。
struct TUNConfig: Codable, Equatable {
    var stack: String = "gvisor"          // system / gvisor / mixed
    var interfaceName: String = "utun996" // 空 = 自动
    var autoRoute: Bool = true
    var strictRoute: Bool = false
    var autoDetectInterface: Bool = true
    var dnsHijack: Bool = true
    var mtu: Int = 9000
    var excludeCIDR: [String] = []        // route_exclude_address

    static let stacks = ["system", "gvisor", "mixed"]
}

/// 应用偏好的持久化存储，落盘到 <应用支持目录>/Sail/config.json。
///
/// 网络接管对齐 Clash Verge：「系统代理」与「虚拟网卡(TUN)」是两个相互独立、
/// 可同时开启的开关，而非二选一。系统代理走 networksetup；TUN 往运行配置注入
/// tun inbound。内核在任一开关开启时运行，两个都关则停止。
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    nonisolated static let defaultPort = 7890
    nonisolated static let defaultLatencyTestURL = "http://cp.cloudflare.com/generate_204"
    /// sing-box DNS 解析策略（全局，非 TUN 专有）。
    static let dnsStrategies = ["ipv4_only", "prefer_ipv4", "prefer_ipv6"]

    private(set) var mixedPort: Int = defaultPort
    private(set) var allowLan: Bool = false
    /// 静默启动：开 app 时不弹主窗，直接挂菜单栏（托盘）。
    private(set) var silentStart: Bool = false
    /// 主题外观：系统 / 浅色 / 深色。
    private(set) var appearance: AppearanceMode = .system
    /// 系统代理开关（独立于 TUN）。
    private(set) var systemProxyEnabled: Bool = false
    /// 虚拟网卡(TUN)开关（独立于系统代理）。
    private(set) var tunEnabled: Bool = false
    private(set) var routeMode: ProxyMode = .rule
    /// DNS 解析策略：ipv4_only / prefer_ipv4 / prefer_ipv6。
    private(set) var dnsStrategy: String = "ipv4_only"
    private(set) var remoteDNSProvider: DNSProvider = .alidnsDoh
    private(set) var directDNSProvider: DNSProvider = .system
    private(set) var bootstrapDNSProvider: DNSProvider = .system
    private(set) var domainDNSRules: [DomainDNSRule] = []
    private(set) var kernelLogLevel: KernelLogLevel = .info
    private(set) var tun = TUNConfig()
    // 高级：测速超时（毫秒）/ 自动延迟检查 / 检测间隔（秒）
    private(set) var latencyTimeoutMs: Int = 10000
    private(set) var latencyTestURL: String = defaultLatencyTestURL
    private(set) var autoLatencyCheck: Bool = false
    private(set) var latencyIntervalSec: Int = 300
    private(set) var importSubscriptionRules: Bool = true   // 导入订阅自带的 rules/rule-providers

    private var fileURL: URL { KernelPaths.supportDir.appendingPathComponent("config.json") }

    // DNS 配置变更防抖：300ms 内多次修改只触发一次重启
    private var dnsRestartTask: Task<Void, Never>?

    private init() { load() }

    // MARK: 修改（自动落盘）

    /// 设置混合代理端口。仅供内部 UI 使用，调用前必须已校验范围。
    /// 直接传入无效值会被拒绝（不会校正为默认值）。
    func setMixedPort(_ port: Int) {
        guard (1...65535).contains(port), port != mixedPort else { return }
        mixedPort = port
        save()
    }

    /// 带防御性校正的端口设置，供外部调用（如未来的 API/插件集成）
    func setMixedPortSafe(_ port: Int) {
        let validated = (1...65535).contains(port) ? port : Self.defaultPort
        setMixedPort(validated)
    }

    func setAllowLan(_ value: Bool) {
        guard value != allowLan else { return }
        allowLan = value
        save()
    }

    func setSilentStart(_ value: Bool) {
        guard value != silentStart else { return }
        silentStart = value
        save()
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        applyAppearance()
        save()
    }

    /// 把当前主题应用到 NSApp（启动恢复与切换时调用）。
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// 设置延迟检测超时。仅供内部 UI 使用，调用前必须已校验范围。
    /// 直接传入无效值会被拒绝（不会校正为默认值）。
    func setLatencyTimeout(_ ms: Int) {
        guard Self.validLatencyTimeoutRange.contains(ms), ms != latencyTimeoutMs else { return }
        latencyTimeoutMs = ms
        save()
    }

    /// 带防御性校正的超时设置，供外部调用（如未来的 API/插件集成）
    func setLatencyTimeoutSafe(_ ms: Int) {
        let validated = min(max(ms, 1000), 60000)
        setLatencyTimeout(validated)
    }

    func setRemoteDNSProvider(_ provider: DNSProvider) {
        guard provider != remoteDNSProvider else { return }
        remoteDNSProvider = provider
        save()
        scheduleRestartForDNSChange()
    }

    func setDirectDNSProvider(_ provider: DNSProvider) {
        guard provider != directDNSProvider else { return }
        directDNSProvider = provider
        save()
        scheduleRestartForDNSChange()
    }

    func setBootstrapDNSProvider(_ provider: DNSProvider) {
        // 验证是否适合作为 bootstrap DNS（防止循环依赖）
        // Bootstrap DNS 用于解析其他 DNS 服务器的域名，不能自身依赖域名解析
        guard provider.isBootstrapSafe else {
            // DoH 需要先解析 DNS 服务器域名，不能作为 bootstrap DNS
            // UI 层应该已经过滤了不合适的选项，这里是防御性检查
            return
        }
        guard provider != bootstrapDNSProvider else { return }
        bootstrapDNSProvider = provider
        save()
        scheduleRestartForDNSChange()
    }

    func setDomainDNSRules(_ rules: [DomainDNSRule]) {
        let normalized = Self.normalizedDomainDNSRules(rules)
        guard normalized != domainDNSRules else { return }
        domainDNSRules = normalized
        save()
        scheduleRestartForDNSChange()
    }

    /// 直接设置已验证的域名 DNS 规则（跳过重复验证）
    func setDomainDNSRulesDirectly(_ rules: [DomainDNSRule]) {
        guard rules != domainDNSRules else { return }
        domainDNSRules = rules
        save()
        scheduleRestartForDNSChange()
    }

    /// DNS 配置变更防抖：300ms 内多次修改只触发一次内核重启
    private func scheduleRestartForDNSChange() {
        guard KernelRunner.shared.isRunning else { return }
        dnsRestartTask?.cancel()
        dnsRestartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await KernelRunner.shared.restart()
        }
    }

    static func normalizedDomainDNSRules(_ rules: [DomainDNSRule]) -> [DomainDNSRule] {
        rules.compactMap { rule in
            // 如果 patterns 为空，则从 suffixes/regexes 重建
            let rawPatterns = rule.patterns.isEmpty
                ? rule.suffixes + rule.regexes.map { "regex:\($0)" }
                : rule.patterns
            // 统一校验和规范化（只调用一次 validatedDomainMatchers）
            let validation = validatedDomainMatchers(rawPatterns)
            guard validation.isValid else { return nil }

            var normalized = rule
            normalized.patterns = validation.patterns
            normalized.suffixes = []  // 已合并到 regexes
            normalized.regexes = validation.regexes
            return normalized
        }
    }

    static func normalizedDomainPatterns(_ values: [String]) -> [String] {
        values
            .flatMap { $0.split { ch in ch == "," || ch == "\n" || ch == "，" }.map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
    }

    static func normalizedDomainSuffixes(_ values: [String]) -> [String] {
        normalizedDomainMatchers(values).suffixes
    }

    static func normalizedDomainMatchers(_ values: [String]) -> (suffixes: [String], regexes: [String]) {
        let validation = validatedDomainMatchers(values)
        return (validation.suffixes, validation.regexes)
    }

    static func validatedDomainMatchers(_ values: [String]) -> DomainDNSMatcherValidation {
        var seen = Set<String>()
        var seenRegex = Set<String>()
        var seenPattern = Set<String>()
        var result = DomainDNSMatcherValidation()
        let items = values
            .flatMap { $0.split { ch in ch == "," || ch == "\n" || ch == "，" }.map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for raw in items {
            guard !raw.isEmpty else { continue }
            let lower = raw.lowercased()
            if lower.hasPrefix("regex:") || lower.hasPrefix("regexp:") {
                let pattern = String(raw.dropFirst(lower.hasPrefix("regex:") ? 6 : 7))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidDomainRegex(pattern) else {
                    result.invalid.append(raw)
                    continue
                }
                if seenRegex.insert(pattern).inserted { result.regexes.append(pattern) }
                if seenPattern.insert(raw).inserted { result.patterns.append(raw) }
                continue
            }
            if raw.hasPrefix("/"), raw.hasSuffix("/"), raw.count > 2 {
                let pattern = String(raw.dropFirst().dropLast())
                guard isValidDomainRegex(pattern) else {
                    result.invalid.append(raw)
                    continue
                }
                if seenRegex.insert(pattern).inserted { result.regexes.append(pattern) }
                if seenPattern.insert(raw).inserted { result.patterns.append(raw) }
                continue
            }

            var value = lower
            if value.hasPrefix("+.") || value.hasPrefix("*.") {
                value.removeFirst(2)
            } else if value.hasPrefix(".") {
                value.removeFirst()
            }
            // 增强域名验证：拒绝空值、单点号、连续点号、仅空格、不含点号
            guard !value.isEmpty,
                  value != ".",
                  !value.contains(".."),
                  value.contains("."),
                  !value.contains(" "),
                  value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                result.invalid.append(raw)
                continue
            }
            // 基本域名格式验证：至少包含一个字母/数字
            guard value.rangeOfCharacter(from: .alphanumerics) != nil else {
                result.invalid.append(raw)
                continue
            }
            if seen.insert(value).inserted { result.suffixes.append(value) }
            let escaped = nsRegularExpressionEscapedPattern(value)
            let pattern = #"^(.+\.)?\#(escaped)$"#
            if seenRegex.insert(pattern).inserted { result.regexes.append(pattern) }
            if seenPattern.insert(raw).inserted { result.patterns.append(raw) }
        }
        return result
    }

    nonisolated private static func nsRegularExpressionEscapedPattern(_ value: String) -> String {
        NSRegularExpression.escapedPattern(for: value)
    }

    private static func isValidDomainRegex(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    func setKernelLogLevel(_ level: KernelLogLevel) {
        guard level != kernelLogLevel else { return }
        kernelLogLevel = level
        save()
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    func setLatencyTestURL(_ raw: String) {
        guard let v = Self.validLatencyTestURL(raw), v != latencyTestURL else { return }
        latencyTestURL = v
        save()
        // url-test 出站的健康检查地址写在运行配置里，改动后需重启内核才能生效。
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    static func validLatencyTestURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return nil
        }
        return trimmed
    }

    static func normalizedLatencyTestURL(_ raw: String) -> String {
        Self.validLatencyTestURL(raw) ?? defaultLatencyTestURL
    }

    func setAutoLatencyCheck(_ value: Bool) {
        guard value != autoLatencyCheck else { return }
        autoLatencyCheck = value
        save()
        LatencyTester.shared.restartAuto()
    }

    /// 设置延迟检测间隔。仅供内部 UI 使用，调用前必须已校验范围。
    /// 直接传入无效值会被拒绝（不会校正为默认值）。
    func setLatencyInterval(_ sec: Int) {
        guard Self.validLatencyIntervalRange.contains(sec), sec != latencyIntervalSec else { return }
        latencyIntervalSec = sec
        save()
        LatencyTester.shared.restartAuto()
    }

    /// 带防御性校正的间隔设置，供外部调用（如未来的 API/插件集成）
    func setLatencyIntervalSafe(_ sec: Int) {
        let validated = min(max(sec, 10), 3600)
        setLatencyInterval(validated)
    }

    nonisolated static let validLatencyTimeoutRange = 1000...60000
    nonisolated static let validLatencyIntervalRange = 10...3600

    func setRouteMode(_ mode: ProxyMode) {
        guard mode != routeMode else { return }
        routeMode = mode
        save()
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    func setImportSubscriptionRules(_ on: Bool) {
        guard on != importSubscriptionRules else { return }
        importSubscriptionRules = on
        save()
        // 打开时刷新当前订阅以下载/转换其规则；关闭时重启内核去掉已注入的订阅规则。
        Task {
            if on, let id = SubscriptionStore.shared.selectedSubscription?.id {
                await SubscriptionStore.shared.refresh(id, viaProxy: KernelRunner.shared.isRunning)
            } else if KernelRunner.shared.isRunning {
                await KernelRunner.shared.restart()
            }
        }
    }

    func setDnsStrategy(_ strategy: String) {
        guard strategy != dnsStrategy, Self.dnsStrategies.contains(strategy) else { return }
        dnsStrategy = strategy
        save()
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    /// 系统代理开关：与 TUN 独立，可共存。内核随 app 常驻，这里只接管/释放系统代理。
    func setSystemProxy(_ on: Bool) async {
        guard on != systemProxyEnabled else { return }
        systemProxyEnabled = on
        save()
        let runner = KernelRunner.shared
        if runner.isRunning {
            if on { SystemProxy.enable(port: mixedPort) } else { SystemProxy.disable() }
        } else {
            await runner.start()   // 内核应常驻；若没在跑则拉起，start() 会按当前开关接管
        }
        IPInfo.shared.scheduleRefresh()   // 出口 IP 可能变了，5s 后自动刷一次（仅此一处触发自动刷新）
    }

    /// 虚拟网卡(TUN)开关：与系统代理独立，可共存。增删 tun inbound 需重启内核生效。
    func setTunEnabled(_ on: Bool) async {
        guard on != tunEnabled else { return }
        tunEnabled = on
        save()
        let runner = KernelRunner.shared
        if runner.isRunning { await runner.restart() }  // start() 会按需申请 TUN 权限
        else { await runner.start() }
        IPInfo.shared.scheduleRefresh()   // 出口 IP 可能变了，5s 后自动刷一次
    }

    func setTUN(_ config: TUNConfig) {
        guard config != tun else { return }
        tun = config
        save()
        if KernelRunner.shared.isRunning, tunEnabled {
            Task { await KernelRunner.shared.restart() }
        }
    }

    // MARK: 落盘模型（嵌套 app，便于日后扩展 window 等字段）

    private struct Persisted: Codable {
        struct App: Codable {
            var mixedPort: Int = SettingsStore.defaultPort
            var allowLan: Bool = false
            var silentStart: Bool = false
            var appearance: String = AppearanceMode.system.rawValue
            var systemProxyEnabled: Bool = false
            var tunEnabled: Bool = false
            var routeMode: String = ProxyMode.rule.rawValue
            var dnsStrategy: String = "ipv4_only"
            var bootstrapDNSProvider: String = DNSProvider.system.rawValue
            var remoteDNSProvider: String = DNSProvider.alidnsDoh.rawValue
            var directDNSProvider: String = DNSProvider.system.rawValue
            var domainDNSRules: [DomainDNSRule] = []
            var kernelLogLevel: String = KernelLogLevel.info.rawValue
            var tun = TUNConfig()
            var latencyTimeoutMs: Int = 10000
            var latencyTestURL: String = SettingsStore.defaultLatencyTestURL
            var autoLatencyCheck: Bool = false
            var latencyIntervalSec: Int = 300
            var importSubscriptionRules: Bool = true

            init() {}

            init(mixedPort: Int, allowLan: Bool, silentStart: Bool, appearance: String,
                 systemProxyEnabled: Bool, tunEnabled: Bool, routeMode: String, dnsStrategy: String,
                 bootstrapDNSProvider: String, remoteDNSProvider: String, directDNSProvider: String,
                 domainDNSRules: [DomainDNSRule], kernelLogLevel: String, tun: TUNConfig,
                 latencyTimeoutMs: Int, latencyTestURL: String, autoLatencyCheck: Bool,
                 latencyIntervalSec: Int, importSubscriptionRules: Bool) {
                self.mixedPort = mixedPort
                self.allowLan = allowLan
                self.silentStart = silentStart
                self.appearance = appearance
                self.systemProxyEnabled = systemProxyEnabled
                self.tunEnabled = tunEnabled
                self.routeMode = routeMode
                self.dnsStrategy = dnsStrategy
                self.bootstrapDNSProvider = bootstrapDNSProvider
                self.remoteDNSProvider = remoteDNSProvider
                self.directDNSProvider = directDNSProvider
                self.domainDNSRules = domainDNSRules
                self.kernelLogLevel = kernelLogLevel
                self.tun = tun
                self.latencyTimeoutMs = latencyTimeoutMs
                self.latencyTestURL = latencyTestURL
                self.autoLatencyCheck = autoLatencyCheck
                self.latencyIntervalSec = latencyIntervalSec
                self.importSubscriptionRules = importSubscriptionRules
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                mixedPort = try c.decodeIfPresent(Int.self, forKey: .mixedPort) ?? SettingsStore.defaultPort
                allowLan = try c.decodeIfPresent(Bool.self, forKey: .allowLan) ?? false
                silentStart = try c.decodeIfPresent(Bool.self, forKey: .silentStart) ?? false
                appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? AppearanceMode.system.rawValue
                systemProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled) ?? false
                tunEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? false
                routeMode = try c.decodeIfPresent(String.self, forKey: .routeMode) ?? ProxyMode.rule.rawValue
                dnsStrategy = try c.decodeIfPresent(String.self, forKey: .dnsStrategy) ?? "ipv4_only"
                bootstrapDNSProvider = try c.decodeIfPresent(String.self, forKey: .bootstrapDNSProvider) ?? DNSProvider.system.rawValue
                remoteDNSProvider = try c.decodeIfPresent(String.self, forKey: .remoteDNSProvider) ?? DNSProvider.alidnsDoh.rawValue
                directDNSProvider = try c.decodeIfPresent(String.self, forKey: .directDNSProvider) ?? DNSProvider.system.rawValue
                domainDNSRules = try c.decodeIfPresent([DomainDNSRule].self, forKey: .domainDNSRules) ?? []
                kernelLogLevel = try c.decodeIfPresent(String.self, forKey: .kernelLogLevel) ?? KernelLogLevel.info.rawValue
                tun = try c.decodeIfPresent(TUNConfig.self, forKey: .tun) ?? TUNConfig()
                latencyTimeoutMs = try c.decodeIfPresent(Int.self, forKey: .latencyTimeoutMs) ?? 10000
                latencyTestURL = try c.decodeIfPresent(String.self, forKey: .latencyTestURL) ?? SettingsStore.defaultLatencyTestURL
                autoLatencyCheck = try c.decodeIfPresent(Bool.self, forKey: .autoLatencyCheck) ?? false
                latencyIntervalSec = try c.decodeIfPresent(Int.self, forKey: .latencyIntervalSec) ?? 300
                importSubscriptionRules = try c.decodeIfPresent(Bool.self, forKey: .importSubscriptionRules) ?? true
            }
        }
        var app = App()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        mixedPort = (1...65535).contains(p.app.mixedPort) ? p.app.mixedPort : Self.defaultPort
        allowLan = p.app.allowLan
        silentStart = p.app.silentStart
        appearance = AppearanceMode(rawValue: p.app.appearance) ?? .system
        routeMode = ProxyMode(rawValue: p.app.routeMode) ?? .rule
        dnsStrategy = Self.dnsStrategies.contains(p.app.dnsStrategy) ? p.app.dnsStrategy : "ipv4_only"
        bootstrapDNSProvider = DNSProvider(rawValue: p.app.bootstrapDNSProvider) ?? .system
        remoteDNSProvider = DNSProvider(rawValue: p.app.remoteDNSProvider) ?? .alidnsDoh
        directDNSProvider = DNSProvider(rawValue: p.app.directDNSProvider) ?? .system
        domainDNSRules = Self.normalizedDomainDNSRules(p.app.domainDNSRules)
        kernelLogLevel = KernelLogLevel(rawValue: p.app.kernelLogLevel) ?? .info
        tun = p.app.tun
        latencyTimeoutMs = min(max(p.app.latencyTimeoutMs, 1000), 60000)
        latencyTestURL = Self.normalizedLatencyTestURL(p.app.latencyTestURL)
        autoLatencyCheck = p.app.autoLatencyCheck
        latencyIntervalSec = min(max(p.app.latencyIntervalSec, 10), 3600)
        importSubscriptionRules = p.app.importSubscriptionRules
        // 内核随 app 常驻，启动后由 start() 按这些开关接管，故直接恢复上次状态。
        systemProxyEnabled = p.app.systemProxyEnabled
        tunEnabled = p.app.tunEnabled
    }

    /// 原子写入：写临时文件 → rename，避免写到一半损坏。
    private func save() {
        var p = Persisted()
        p.app = .init(mixedPort: mixedPort, allowLan: allowLan, silentStart: silentStart,
                      appearance: appearance.rawValue,
                      systemProxyEnabled: systemProxyEnabled, tunEnabled: tunEnabled,
                      routeMode: routeMode.rawValue, dnsStrategy: dnsStrategy,
                      bootstrapDNSProvider: bootstrapDNSProvider.rawValue,
                      remoteDNSProvider: remoteDNSProvider.rawValue,
                      directDNSProvider: directDNSProvider.rawValue,
                      domainDNSRules: domainDNSRules,
                      kernelLogLevel: kernelLogLevel.rawValue,
                      tun: tun,
                      latencyTimeoutMs: latencyTimeoutMs, latencyTestURL: latencyTestURL,
                      autoLatencyCheck: autoLatencyCheck,
                      latencyIntervalSec: latencyIntervalSec,
                      importSubscriptionRules: importSubscriptionRules)
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(p)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            // 落盘失败时尽力而为，不阻断使用
        }
    }
}
