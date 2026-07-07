import Foundation

/// 出站拓扑构建：把「选中订阅的节点 + 订阅自带 proxy-groups（或合成的默认组）」统一构建成
/// sing-box 出站数组 + 主选择器 tag。`KernelRunner.makeConfig`（运行配置）与
/// `ProxyGroupStore`（离线分组展示）共用同一套，保证运行态与离线态、配置与 UI 完全一致。
///
/// 核心原则：**分组永远存在，与路由模式 / 导入开关解耦**（对齐 Clash Verge / sing-box 官方）。
/// - 订阅自带 proxy-groups（已转换落盘到 route.json）→ 用机场原组，主选择器 = MATCH 去向组。
/// - 否则 → 合成 `Proxy`(selector, 含 `Auto` + 全部节点) + `Auto`(urltest, 全部节点)，主选择器 = `Proxy`。
enum ProxyTopology {
    /// 合成模式的主选择器 / 自动组 tag（机场模式用机场原组名，不走这俩）。
    nonisolated static let masterTag = "Proxy"
    nonisolated static let autoTag = "Auto"

    /// 正则表达式缓存（跨调用复用，避免重复编译相同 filter 模式）
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    /// LRU 双向链表节点（用 key 连接，避免引用类型在 Swift 并发检查下产生 actor 隔离 warning）。
    private struct LRUEntry {
        let key: String
        var prev: String?
        var next: String?
    }

    /// LRU 访问顺序跟踪（双向链表 + 字典，O(1) 访问和更新）
    nonisolated(unsafe) private static var lruHead: String? = nil  // 最旧
    nonisolated(unsafe) private static var lruTail: String? = nil  // 最新
    nonisolated(unsafe) private static var lruNodes: [String: LRUEntry] = [:]  // key -> 链表节点

    nonisolated private static let regexCacheLock = NSLock()
    nonisolated private static let regexCacheMaxSize = 50

    /// 验证正则模式复杂度，防止 ReDoS 攻击
    nonisolated private static func isRegexSafe(_ pattern: String) -> Bool {
        // 1. 拒绝反向引用（极高 ReDoS 风险）
        // 反向引用会导致回溯复杂度指数级增长，如 (a*)\\1+
        if pattern.contains("\\1") || pattern.contains("\\2") ||
           pattern.contains("\\3") || pattern.contains("\\4") {
            return false
        }

        // 2. 增强嵌套量词检测（ReDoS 的主要来源）
        let nestedPatterns = [
            #"\([^)]*[+*?]\)[+*?{]"#,        // 捕获组后量词: (a+)+
            #"\(\?:[^)]*[+*?]\)[+*?{]"#,     // 非捕获组后量词: (?:a+)+
            #"\|[^)]*[+*?]\)[+*?{]"#,        // 交替分支内量词: (a|b+)+
        ]
        for patternStr in nestedPatterns {
            if let re = try? NSRegularExpression(pattern: patternStr),
               re.firstMatch(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)) != nil {
                return false
            }
        }

        // 3. 允许 Clash/Stash 常见的地区筛选 + 排除订阅信息正则；过长模式仍拒绝。
        if pattern.count > 1024 {
            return false
        }

        // 4. 拒绝超过 3 层嵌套的括号（复杂度指标）
        var depth = 0, maxDepth = 0
        for ch in pattern {
            if ch == "(" { depth += 1; maxDepth = max(maxDepth, depth) }
            else if ch == ")" { depth -= 1 }
        }
        if maxDepth > 3 {
            return false
        }

        return true
    }

    /// 从 LRU 链表中移除节点
    nonisolated private static func removeLRUNode(_ key: String) {
        guard let node = lruNodes[key] else { return }
        if let prev = node.prev {
            lruNodes[prev]?.next = node.next
        } else {
            lruHead = node.next
        }

        if let next = node.next {
            lruNodes[next]?.prev = node.prev
        } else {
            lruTail = node.prev
        }

        lruNodes[key]?.prev = nil
        lruNodes[key]?.next = nil
    }

    /// 将节点移到 LRU 链表末尾（标记为最新访问）
    nonisolated private static func moveToTail(_ key: String) {
        if key == lruTail { return }  // 已在末尾

        removeLRUNode(key)

        // 追加到末尾
        lruNodes[key]?.prev = lruTail
        lruNodes[key]?.next = nil
        if let tail = lruTail {
            lruNodes[tail]?.next = key
        }
        lruTail = key

        if lruHead == nil {
            lruHead = key
        }
    }

    /// 添加新节点到 LRU 链表末尾
    nonisolated private static func addToTail(_ key: String) {
        lruNodes[key] = LRUEntry(key: key, prev: lruTail, next: nil)
        if let tail = lruTail {
            lruNodes[tail]?.next = key
        }
        lruTail = key

        if lruHead == nil {
            lruHead = key
        }
    }

    nonisolated private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }

        // 安全检查：拒绝可能导致 ReDoS 的模式
        guard isRegexSafe(pattern) else {
            return nil
        }

        if let cached = regexCache[pattern] {
            // O(1) 更新访问顺序（移到末尾）
            if lruNodes[pattern] != nil {
                moveToTail(pattern)
            }
            return cached
        }

        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        // 真正的 LRU：超过容量时删除最少使用的（链表头部）
        if regexCache.count >= regexCacheMaxSize, let oldest = lruHead {
            removeLRUNode(oldest)
            regexCache.removeValue(forKey: oldest)
            lruNodes.removeValue(forKey: oldest)
        }

        regexCache[pattern] = re
        addToTail(pattern)
        return re
    }

    struct Result {
        /// 节点出站 + 组出站（不含 direct，调用方自行追加）。
        var outbounds: [[String: Any]]
        /// 主选择器 tag：route.final / 「走代理」去向。无节点时为 "direct"。
        var master: String
        /// 仅组出站（供离线 UI 解析成 Group）。
        var groupOutbounds: [[String: Any]]
        /// 节点 tag → 协议类型（离线给成员标协议用）。
        var protoByTag: [String: String]
        /// 是否有可用节点（hasProxy）。
        var hasNodes: Bool
    }

    /// 构建出站拓扑。
    /// - nodes: 选中订阅的节点
    /// - importedGroups: route.json 里的 groups（机场自带，已转换）；空 → 合成默认组
    /// - importedFinal: route.json 的 final（机场 MATCH 去向，= 主选择器组）
    /// - overrides: 各组的手动选择（groupName → memberTag），作 selector 的 default
    nonisolated static func build(nodes: [ProxyNode],
                                  importedGroups: [[String: Any]],
                                  importedFinal: String?,
                                  overrides: [String: String],
                                  healthCheckURL: String = SettingsStore.defaultLatencyTestURL) -> Result {
        let (nodeOuts, nameToTag) = nodeOutbounds(nodes)
        let nodeTags = nodeOuts.compactMap { $0["tag"] as? String }
        var protoByTag: [String: String] = [:]
        for o in nodeOuts {
            if let t = o["tag"] as? String, let p = (o["type"] as? String)?.lowercased() { protoByTag[t] = p }
        }
        guard !nodeTags.isEmpty else {
            return Result(outbounds: [], master: "direct", groupOutbounds: [], protoByTag: [:], hasNodes: false)
        }
        var groupOuts: [[String: Any]]
        var master: String
        if !importedGroups.isEmpty {
            groupOuts = groupOutbounds(importedGroups, allNodeTags: nodeTags, nameToTag: nameToTag,
                                       overrides: overrides, healthCheckURL: healthCheckURL)
            if groupOuts.isEmpty {
                groupOuts = synthesizedGroups(nodeTags: nodeTags, overrides: overrides, healthCheckURL: healthCheckURL)
                master = masterTag
            } else {
                // master 必须指向实际存在的组：优先用 importedFinal（若存在），否则用第一个实际输出的组。
                let actualGroupTags = Set(groupOuts.compactMap { $0["tag"] as? String })
                master = importedFinal.flatMap { actualGroupTags.contains($0) ? $0 : nil }
                    ?? groupOuts.first?["tag"] as? String
                    ?? masterTag
            }
        } else {
            groupOuts = synthesizedGroups(nodeTags: nodeTags, overrides: overrides, healthCheckURL: healthCheckURL)
            master = masterTag
        }
        return Result(outbounds: nodeOuts + groupOuts, master: master,
                      groupOutbounds: groupOuts, protoByTag: protoByTag, hasNodes: true)
    }

    /// 合成默认组（机场没给 proxy-groups 时）：
    /// `Auto`(urltest, 全部节点) + `Proxy`(selector, [Auto] + 全部节点, default = override ?? Auto)。
    /// 用户在 `Proxy` 里点 `Auto` = 按延迟自动；点某节点 = 钉住该节点。
    nonisolated static func synthesizedGroups(nodeTags: [String], overrides: [String: String],
                                              healthCheckURL: String = SettingsStore.defaultLatencyTestURL) -> [[String: Any]] {
        let auto: [String: Any] = [
            "type": "urltest", "tag": autoTag, "outbounds": nodeTags,
            "url": healthCheckURL, "interval": "300s", "idle_timeout": "2100s",   // interval ≤ idle_timeout
        ]
        let proxyMembers = [autoTag] + nodeTags
        let sel = overrides[masterTag].flatMap { proxyMembers.contains($0) ? $0 : nil }
        let proxy: [String: Any] = [
            "type": "selector", "tag": masterTag, "outbounds": proxyMembers,
            "default": sel ?? autoTag,
        ]
        return [auto, proxy]
    }

    // MARK: 节点 → 出站

    /// 把订阅节点转成 sing-box 出站（tag 唯一化）；返回出站数组 + 「原始节点名 → 唯一 tag」映射（组按名引用）。
    nonisolated static func nodeOutbounds(_ nodes: [ProxyNode]) -> (outbounds: [[String: Any]], nameToTag: [String: String]) {
        var outs: [[String: Any]] = []
        var nameToTag: [String: String] = [:]
        var used = Set<String>()
        for node in nodes {
            guard let data = node.outboundJSON.data(using: .utf8),
                  var ob = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let base = node.label.isEmpty ? "node" : node.label
            var tag = base, i = 2
            while used.contains(tag) { tag = "\(base) \(i)"; i += 1 }
            used.insert(tag)
            ob["tag"] = tag
            outs.append(ob)
            if nameToTag[node.label] == nil { nameToTag[node.label] = tag }
        }
        return (outs, nameToTag)
    }

    /// 重建「成员 tag → 节点」映射，与 `nodeOutbounds` 的取 tag / 去重逻辑完全一致，
    /// 保证离线成员名能对回正确的节点（整组测速冷路径用）。
    nonisolated static func tagToNodeMap(_ nodes: [ProxyNode]) -> [String: ProxyNode] {
        var map: [String: ProxyNode] = [:]
        var used = Set<String>()
        for node in nodes {
            guard let data = node.outboundJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            let base = node.label.isEmpty ? "node" : node.label
            var tag = base, i = 2
            while used.contains(tag) { tag = "\(base) \(i)"; i += 1 }
            used.insert(tag)
            map[tag] = node
        }
        return map
    }

    nonisolated private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: proxy-group → 出站

    /// 把订阅 proxy-group 定义转成 sing-box selector / url-test 出站。成员名解析为节点 tag / 嵌套组 / direct；
    /// useAll 展开为全部节点；空组兜底为全部节点（或 direct）。
    /// url-test **永远只读自动**（sing-box / clash_api 不支持手动切 url-test）；要钉节点请切其父 selector。
    nonisolated static func groupOutbounds(_ groups: [[String: Any]], allNodeTags: [String], nameToTag: [String: String],
                                           overrides: [String: String] = [:],
                                           healthCheckURL: String = SettingsStore.defaultLatencyTestURL) -> [[String: Any]] {
        let groupTags = Set(groups.compactMap { $0["tag"] as? String })
        var outs: [[String: Any]] = []
        var skippedGroups: Set<String> = []  // 记录被跳过的组

        // 第一遍：构建所有组，记录被跳过的
        for g in groups {
            guard let tag = g["tag"] as? String, let type = g["type"] as? String else { continue }
            var members: [String] = []
            let declaredMembers = (g["members"] as? [String]) ?? []
            let hasFilter = g["filter"] != nil || g["excludeFilter"] != nil
            let shouldExpandNodePool = (g["useAll"] as? Bool) == true || (hasFilter && declaredMembers.isEmpty)
            if shouldExpandNodePool {
                // filter / exclude-filter（正则按节点名 = tag 筛选 use 展开的节点池）。
                var pool = allNodeTags
                if let f = g["filter"] as? String {
                    guard let re = cachedRegex(f) else {
                        skippedGroups.insert(tag)
                        continue
                    }
                    pool = pool.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                }
                if let ex = g["excludeFilter"] as? String {
                    guard let re = cachedRegex(ex) else {
                        skippedGroups.insert(tag)
                        continue
                    }
                    pool = pool.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
                }
                members += pool
            }
            for name in declaredMembers {
                if name.uppercased() == "DIRECT" { members.append(SpecialOutbound.direct) }
                else if SpecialOutbound.isBlocked(name) { continue }
                else if groupTags.contains(name) { members.append(name) }      // 嵌套组
                else if let t = nameToTag[name] { members.append(t) }          // 节点名
            }
            // 去重保序
            members = orderedUnique(members)
            // 空组兜底：有过滤器且筛选为空时跳过该组（避免静默回退直连），
            // 否则兜底为全部节点（无节点时才用 direct）。
            if members.isEmpty {
                if hasFilter && shouldExpandNodePool {
                    skippedGroups.insert(tag)
                    continue
                }
                members = allNodeTags.isEmpty ? ["direct"] : allNodeTags
            }
            var o: [String: Any] = ["type": type, "tag": tag, "outbounds": members]
            if type == "urltest" {
                o["url"] = healthCheckURL
                // 健康检查间隔限幅到 [60, 600]s：机场常把 interval 设得离谱（见过 36000s=10h），
                // 导致 url-test 几乎不重测、延迟一直显示「-」；过小又频繁耗流。统一收进合理区间。
                // sing-box 要求 interval ≤ idle_timeout，故 idle_timeout 按 interval+1800s 推算。
                let raw = (g["interval"] as? String).flatMap { Int($0.dropLast()) } ?? 300   // "Ns" → N
                let n = min(max(raw, 60), 600)
                o["interval"] = "\(n)s"
                o["idle_timeout"] = "\(n + 1800)s"
                if let tol = g["tolerance"] as? Int { o["tolerance"] = tol }
            } else {
                // selector：default 取用户手动选择（须在成员内），否则首个。
                o["type"] = "selector"
                let override = overrides[tag].flatMap { members.contains($0) ? $0 : nil }
                o["default"] = override ?? members.first
            }
            outs.append(o)
        }

        // 清理所有组对被跳过组的引用；父组被清空时也跳过，继续向上传播。
        var changed = true
        var iterations = 0
        let maxIterations = outs.count + 10  // 最多迭代次数 = 初始组数 + 安全边界
        while changed && iterations < maxIterations {
            iterations += 1
            changed = false
            for i in outs.indices.reversed() {
                guard let tag = outs[i]["tag"] as? String,
                      var members = outs[i]["outbounds"] as? [String] else { continue }
                members.removeAll { skippedGroups.contains($0) }
                if members.isEmpty {
                    skippedGroups.insert(tag)
                    outs.remove(at: i)
                    changed = true
                    continue
                }
                outs[i]["outbounds"] = members
                if outs[i]["type"] as? String == "selector",
                   let def = outs[i]["default"] as? String,
                   !members.contains(def) {
                    outs[i]["default"] = members.first
                }
            }
        }

        // 如果达到最大迭代次数，可能存在循环依赖（理论上不应发生）
        // 此处静默处理，避免阻塞订阅刷新
        if iterations >= maxIterations {
            // 循环依赖检测：已达到最大迭代次数，可能订阅中存在循环引用
            // 保留当前状态继续处理，避免完全失败
        }

        return outs
    }
}
