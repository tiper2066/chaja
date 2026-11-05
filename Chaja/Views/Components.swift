import SwiftUI

/// 칩을 가로로 늘어놓다가 폭이 모자라면 다음 줄로 넘긴다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct Chip: View {
    let title: String
    var symbol: String?
    var tint: Color = .accentColor
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOn ? .white : tint)
                }
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? .white : .primary)
            .background(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.7)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

struct SidebarSection<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
                Spacer()
                accessory
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            content
        }
    }
}

extension SidebarSection where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

enum DateText {
    static func short(_ date: Date?) -> String {
        guard let date else { return "--" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "오늘 \(time)" }
        if calendar.isDateInYesterday(date) { return "어제 \(time)" }
        return date.formatted(date: .numeric, time: .shortened)
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .long, time: .standard)
    }
}

extension Duration {
    var secondsText: String {
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return seconds.formatted(.number.precision(.fractionLength(2))) + "초"
    }
}
