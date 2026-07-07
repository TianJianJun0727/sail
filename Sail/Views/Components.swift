import SwiftUI

/// 原生风格卡片容器：控件背景色 + 圆角 + 细描边
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var fillHeight: Bool = false   // 撑满父容器高度（用于并排卡片等高）
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
    }
}

/// 分区小标题：竖条 + 全大写间距字
struct SectionHeader<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    init(_ label: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 13)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
    }
}

private enum PageTopBarMetrics {
    static let height: CGFloat = 50
    static let horizontalPadding: CGFloat = 24
}

extension View {
    /// 页面标题下方的第一行工具区，统一各页的高度和左右边距。
    func pageTopBar(alignment: Alignment = .center) -> some View {
        self
            .padding(.horizontal, PageTopBarMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: PageTopBarMetrics.height,
                   maxHeight: PageTopBarMetrics.height, alignment: alignment)
    }

    /// 为无效输入添加红色边框
    func invalidInputBorder(_ invalid: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(invalid ? Color.red.opacity(0.75) : Color.clear, lineWidth: 1)
        )
    }
}

/// 表单字段错误提示
struct FieldError: View {
    var text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 集合扩展

extension Array where Element: Hashable {
    /// 去重保序：返回去除重复元素后的数组，保持首次出现的顺序
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
