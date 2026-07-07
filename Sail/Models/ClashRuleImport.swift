import Foundation

/// 把 Clash 订阅自带的 rules + rule-providers + proxy-groups 转成 sing-box 路由。
/// - rule-provider（Clash 格式 domain/ipcidr/classical）下载后转成 sing-box rule_set 源文件(本地缓存)，
///   避免把成千上万条域名内联进配置(proxy.txt 就 2.6 万条)。
/// - 每条 Clash 规则的去向按 proxy-group 的默认指向(首个 proxies 选项)递归解析为 proxy/direct/reject——
///   Sail 无出站分组，故所有「走代理」的组都归到当前选中节点(proxy)。
enum ClashRuleImport {

    // MARK: 对外：转换并落盘

    /// 把订阅的路由转成 sing-box route 片段写进 dir/route.json，rule_set 源文件同目录。
    /// 返回是否产出了规则。hasProxy=false 时丢弃「走代理」类规则。
    @discardableResult
    nonisolated static func build(yaml: String,
                                  into dir: URL,
                                  hasProxy: Bool,
                                  proxyPort: Int?) async -> Bool {
        let clashRules = ClashYAMLParser.rules(yaml)
        guard !clashRules.isEmpty else { return false }
        let providers = ClashYAMLParser.ruleProviders(yaml)

        // 去向直接指向真实组名（该组会作为 selector/url-test 出站被生成）；DIRECT→直连，REJECT→拦截(nil)。
        func outboundFor(_ target: String) -> String? {
            let t = target.trimmingCharacters(in: .whitespaces)
            if t == "DIRECT" { return "direct" }
            if t == "REJECT" || t == "REJECT-DROP" || t == "PASS" { return nil }
            return t
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sbRules: [[String: Any]] = []
        var ruleSetDefs: [[String: Any]] = []
        var seenTags = Set<String>()
        var finalOutbound: String?
        var failedRuleSets: [String] = []  // 收集下载失败的 rule-set

        for raw in clashRules {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = parts.first?.uppercased() else { continue }

            if type == "MATCH" || type == "FINAL" {
                guard parts.count >= 2 else { continue }
                finalOutbound = outboundFor(parts[1]) ?? "direct"   // 兜底走 reject 极少见，退直连
                continue
            }
            guard parts.count >= 3 else { continue }
            let arg = parts[1], out = outboundFor(parts[2])

            switch type {
            case "RULE-SET":
                let tag = "sub-" + sanitize(arg)
                if !seenTags.contains(tag) {
                    guard let prov = providers[arg], let url = prov["url"] as? String else { continue }
                    let behavior = (prov["behavior"] as? String ?? "classical").lowercased()
                    let file = dir.appendingPathComponent("\(tag).json")
                    let cache = cacheFile(prefix: tag, key: "source|\(behavior)|\(url)", ext: "json")
                    guard await downloadAndConvert(url, behavior: behavior, to: file, cacheFile: cache, proxyPort: proxyPort) else {
                        failedRuleSets.append(tag)
                        continue
                    }
                    ruleSetDefs.append(["type": "local", "tag": tag, "format": "source", "path": file.lastPathComponent])
                    seenTags.insert(tag)
                }
                sbRules.append(withAction(["rule_set": [tag]], out))

            case "GEOIP":
                let code = sanitize(arg.lowercased())
                guard !code.isEmpty else { continue }
                if isPrivateGeoIP(code) {
                    continue
                }
                let tag = "geoip-\(code)"
                guard await addGeoRuleSet(tag, kind: "geoip", into: &ruleSetDefs, seen: &seenTags, dir: dir, proxyPort: proxyPort) else {
                    failedRuleSets.append(tag)
                    continue
                }
                sbRules.append(withAction(["rule_set": [tag]], out))

            case "GEOSITE":
                let code = sanitize(arg.lowercased())
                guard !code.isEmpty else { continue }
                if isPrivateGeo(code) {
                    continue
                }
                let tag = "geosite-\(code)"
                guard await addGeoRuleSet(tag, kind: "geosite", into: &ruleSetDefs, seen: &seenTags, dir: dir, proxyPort: proxyPort) else {
                    failedRuleSets.append(tag)
                    continue
                }
                sbRules.append(withAction(["rule_set": [tag]], out))

            default:
                var m = Matchers()
                guard addMatcher(type, arg, into: &m) else { continue }   // 不认识的类型跳过
                for obj in m.ruleObjects() { sbRules.append(withAction(obj, out)) }
            }
        }

        // 如果有任何 rule-set 下载失败，视为本次 build 失败，保留旧缓存
        // 防止部分成功的规则集替换完整的旧缓存，导致路由行为静默改变
        guard failedRuleSets.isEmpty else {
            return false
        }

        // 出站分组定义（makeConfig 据此 + 订阅节点生成 selector/url-test 出站）。
        var groups: [[String: Any]] = []
        for g in ClashYAMLParser.proxyGroupDefs(yaml) {
            guard let name = g["name"] as? String else { continue }
            let ctype = (g["type"] as? String ?? "select").lowercased()
            var gd: [String: Any] = [
                "tag": name,
                "type": ctype == "select" ? "selector" : "urltest",   // url-test/fallback/load-balance → urltest
                "members": (g["proxies"] as? [Any])?.compactMap { $0 as? String } ?? [],
                "useAll": !((g["use"] as? [Any])?.isEmpty ?? true) || (g["include-all"] as? Bool == true),
            ]
            // use/include-all + filter / exclude-filter（正则，按节点名筛选展开的节点池）：现代机场常用
            // Clash 常见 `use:[provider] + filter:香港|HK`，Stash 常见 `include-all:true + filter`。
            // Sail 已把订阅节点拍平成当前订阅节点池，因此两者都展开为当前订阅节点池后按名称正则筛选。
            if let f = g["filter"] as? String, !f.isEmpty { gd["filter"] = f }
            if let ex = g["exclude-filter"] as? String, !ex.isEmpty { gd["excludeFilter"] = ex }
            if gd["type"] as? String == "urltest" {
                gd["url"] = "http://cp.cloudflare.com/generate_204"   // 统一用更普遍可达的地址（运行时 groupOutbounds 也会覆盖）
                let iv = (g["interval"] as? Int) ?? (Int((g["interval"] as? String) ?? "") ?? 300)
                gd["interval"] = "\(iv)s"
                if let tol = g["tolerance"] as? Int { gd["tolerance"] = tol }
            }
            groups.append(gd)
        }

        var route: [String: Any] = ["rules": sbRules, "rule_set": ruleSetDefs, "groups": groups]
        if let f = finalOutbound { route["final"] = f }
        guard !sbRules.isEmpty || finalOutbound != nil,
              let data = try? JSONSerialization.data(withJSONObject: route) else { return false }
        try? data.write(to: dir.appendingPathComponent("route.json"), options: .atomic)
        return true
    }

    /// 读回某订阅已转换的 route 片段（makeConfig 用）。
    nonisolated static func importedRoute(dir: URL)
        -> (rules: [[String: Any]], ruleSet: [[String: Any]], final: String?, groups: [[String: Any]])? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("route.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ruleSet = normalizeLocalRuleSetPaths(
            obj["rule_set"] as? [[String: Any]] ?? [],
            dir: dir)
        let normalized = normalizePrivateGeoIP(
            rules: obj["rules"] as? [[String: Any]] ?? [],
            ruleSet: ruleSet)
        return (normalized.rules,
                normalized.ruleSet,
                obj["final"] as? String,
                obj["groups"] as? [[String: Any]] ?? [])
    }

    // MARK: 去向注入

    private nonisolated static func withAction(_ rule: [String: Any], _ outbound: String?) -> [String: Any] {
        var r = rule
        if let o = outbound { r["outbound"] = o } else { r["action"] = "reject" }
        return r
    }

    private nonisolated static func addGeoRuleSet(_ tag: String,
                                                  kind: String,
                                                  into defs: inout [[String: Any]],
                                                  seen: inout Set<String>,
                                                  dir: URL,
                                                  proxyPort: Int?) async -> Bool {
        guard !seen.contains(tag) else { return true }
        let file = dir.appendingPathComponent("\(tag).srs")
        let url = "https://raw.githubusercontent.com/SagerNet/sing-\(kind)/rule-set/\(tag).srs"
        let cache = cacheFile(prefix: tag, key: "binary|\(url)", ext: "srs")
        if await downloadSRS(url, to: file, cacheFile: cache, proxyPort: proxyPort) {
            defs.append(["type": "local", "tag": tag, "format": "binary", "path": file.lastPathComponent])
            seen.insert(tag)
            return true
        }
        // 已有全局本地副本时兜底使用，仍避免运行期 remote rule_set 初始化导致内核 FATAL。
        if let local = GeoData.localRuleSet(tag) {
            defs.append(["type": "local", "tag": tag, "format": "binary", "path": local.path])
            seen.insert(tag)
            return true
        }
        return false
    }

    private nonisolated static var ruleSetCacheDir: URL {
        KernelPaths.supportDir.appendingPathComponent("ruleset-cache", isDirectory: true)
    }

    private nonisolated static func cacheFile(prefix: String, key: String, ext: String) -> URL {
        ruleSetCacheDir.appendingPathComponent("\(prefix)-\(fnv1a64(key)).\(ext)")
    }

    private nonisolated static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private nonisolated static func copyRuleSet(from source: URL, to dest: URL) -> Bool {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: source, to: tmp)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    private nonisolated static func restoreCachedSRS(_ cacheFile: URL, to file: URL) -> Bool {
        FileManager.default.fileExists(atPath: cacheFile.path)
            && isValidSRS(cacheFile)
            && copyRuleSet(from: cacheFile, to: file)
    }

    private nonisolated static func restoreCachedSource(_ cacheFile: URL, to file: URL) -> Bool {
        FileManager.default.fileExists(atPath: cacheFile.path)
            && copyRuleSet(from: cacheFile, to: file)
    }

    private nonisolated static func normalizeLocalRuleSetPaths(_ ruleSet: [[String: Any]], dir: URL) -> [[String: Any]] {
        ruleSet.map { set in
            guard (set["type"] as? String) == "local",
                  let path = set["path"] as? String else { return set }
            if path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) { return set }
            let fallback = dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            guard FileManager.default.fileExists(atPath: fallback.path) else { return set }
            var fixed = set
            fixed["path"] = fallback.path
            return fixed
        }
    }

    private nonisolated static func downloadSRS(_ urlString: String,
                                                to file: URL,
                                                cacheFile: URL,
                                                proxyPort: Int?) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        if let port = proxyPort {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        do {
            let (tmp, resp) = try await URLSession(configuration: cfg).download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  isValidSRS(tmp) else {
                return restoreCachedSRS(cacheFile, to: file)
            }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            _ = copyRuleSet(from: file, to: cacheFile)
            return true
        } catch {
            return restoreCachedSRS(cacheFile, to: file)
        }
    }

    private nonisolated static func isValidSRS(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > 64 else { return false }
        let magic = handle.readData(ofLength: 3)
        return magic == Data([0x53, 0x52, 0x53])
    }

    private nonisolated static func isPrivateGeoIP(_ code: String) -> Bool {
        code == "private" || code == "lan"
    }

    private nonisolated static func isPrivateGeo(_ code: String) -> Bool {
        code == "private"
    }

    private nonisolated static func normalizePrivateGeoIP(rules: [[String: Any]], ruleSet: [[String: Any]])
        -> (rules: [[String: Any]], ruleSet: [[String: Any]]) {
        let privateTags = Set(["geoip-private", "geoip-lan", "geosite-private"])
        let filteredRuleSet = ruleSet.filter { set in
            guard let tag = set["tag"] as? String else { return true }
            return !privateTags.contains(tag)
        }
        var normalizedRules: [[String: Any]] = []
        for rule in rules {
            guard let tags = rule["rule_set"] as? [String],
                  tags.contains(where: { privateTags.contains($0) }) else {
                normalizedRules.append(rule)
                continue
            }
            let remaining = tags.filter { !privateTags.contains($0) }
            if !remaining.isEmpty {
                var kept = rule
                kept["rule_set"] = remaining
                normalizedRules.append(kept)
            }
        }
        return (normalizedRules, filteredRuleSet)
    }

    // MARK: Clash 规则体 → sing-box matcher

    private struct Matchers {
        var domain: [String] = [], domainSuffix: [String] = [], domainKeyword: [String] = []
        var ipCidr: [String] = [], process: [String] = [], sourceIPCidr: [String] = []
        var port: [Int] = []

        nonisolated init() {}

        nonisolated func ruleObjects() -> [[String: Any]] {
            var r: [[String: Any]] = []
            if !domain.isEmpty { r.append(["domain": domain]) }
            if !domainSuffix.isEmpty { r.append(["domain_suffix": domainSuffix]) }
            if !domainKeyword.isEmpty { r.append(["domain_keyword": domainKeyword]) }
            if !ipCidr.isEmpty { r.append(["ip_cidr": ipCidr]) }
            if !process.isEmpty { r.append(["process_name": process]) }
            if !sourceIPCidr.isEmpty { r.append(["source_ip_cidr": sourceIPCidr]) }
            if !port.isEmpty { r.append(["port": port]) }
            return r
        }
    }

    /// 把一条 Clash 规则体(TYPE, arg)累加进 matcher；识别返回 true。
    private nonisolated static func addMatcher(_ type: String, _ arg: String, into m: inout Matchers) -> Bool {
        switch type.uppercased() {
        case "DOMAIN": m.domain.append(arg)
        case "DOMAIN-SUFFIX": m.domainSuffix.append(arg)
        case "DOMAIN-KEYWORD": m.domainKeyword.append(arg)
        case "IP-CIDR", "IP-CIDR6": m.ipCidr.append(arg)
        case "PROCESS-NAME": m.process.append(arg)
        case "SRC-IP-CIDR": m.sourceIPCidr.append(arg)
        case "DST-PORT": if let p = Int(arg) { m.port.append(p) } else { return false }
        default: return false
        }
        return true
    }

    // MARK: rule-provider 下载 + 转 sing-box rule_set 源

    private nonisolated static func downloadAndConvert(_ urlString: String,
                                                       behavior: String,
                                                       to file: URL,
                                                       cacheFile: URL,
                                                       proxyPort: Int?) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        if let port = proxyPort {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }   // 用完主动关连接，经 7890 时不给它留 TIME_WAIT
        guard let (data, resp) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 30)),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let text = String(data: data, encoding: .utf8) else {
            return restoreCachedSource(cacheFile, to: file)
        }

        var m = Matchers()
        for entry in payloadEntries(text) {
            switch behavior {
            case "domain":
                if entry.hasPrefix("+.") { m.domainSuffix.append(String(entry.dropFirst(2))) }
                else if entry.hasPrefix("*.") { m.domainSuffix.append(String(entry.dropFirst(2))) }
                else { m.domain.append(entry) }
            case "ipcidr":
                m.ipCidr.append(entry)
            default: // classical：每条是「TYPE,arg[,...]」
                let p = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count >= 2 { _ = addMatcher(p[0], p[1], into: &m) }
            }
        }
        let objs = m.ruleObjects()
        guard !objs.isEmpty,
              let out = try? JSONSerialization.data(withJSONObject: ["version": 2, "rules": objs]) else {
            return restoreCachedSource(cacheFile, to: file)
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? out.write(to: file, options: .atomic)) != nil else {
            return restoreCachedSource(cacheFile, to: file)
        }
        _ = copyRuleSet(from: file, to: cacheFile)
        return true
    }

    /// 取 Clash provider 的 payload 列表项（`payload:` 下的 `- 'x'` 行；去引号）。纯行解析，足够稳。
    private nonisolated static func payloadEntries(_ text: String) -> [String] {
        var out: [String] = []
        var inPayload = false
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "payload:" || t.hasPrefix("payload:") { inPayload = true; continue }
            guard inPayload, t.hasPrefix("-") else {
                if !t.isEmpty && !t.hasPrefix("-") && !t.hasPrefix("#") && inPayload { break } // 离开 payload 块
                continue
            }
            var v = t.dropFirst().trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            if !v.isEmpty { out.append(v) }
        }
        return out
    }

    /// rule_set tag 只留合法字符。
    private nonisolated static func sanitize(_ s: String) -> String {
        String(s.lowercased().map { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}
