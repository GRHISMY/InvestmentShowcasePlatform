import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Render a declared expression. The renderer knows geometry and interaction,
/// not the company, its argument or which financial numbers matter.
struct StudyDiagram: View {
    let view: ReadingView
    let focus: String
    let periods: [ResearchPeriod]
    let onSelect: (String) -> Void
    private let paper = Color(red: 0.965, green: 0.959, blue: 0.936)
    private let muted = Color.black.opacity(0.52)

    var body: some View {
        GeometryReader { geometry in
            let natural = naturalHeight(width: geometry.size.width)
            let scale = min(1, max(0.1, geometry.size.height / natural))
            content.frame(width: geometry.size.width / scale, height: natural, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .foregroundStyle(.black)
        .accessibilityElement(children: .contain)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !view.title.isEmpty { Text(view.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
            if !view.caption.isEmpty { Text(view.caption).font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
            Group {
                switch view.kind {
                case "relation_graph", "argument": graph
                case "comparison": comparison
                case "trend": trend
                case "timeline": timeline
                default: textView
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !view.annotations.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: min(3, view.annotations.count)), alignment: .leading, spacing: 8) {
                    ForEach(view.annotations) { annotation in
                        Button { onSelect(annotation.focusId) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Image(systemName: annotation.icon).font(.system(size: 14, weight: .light))
                                Text(annotation.label).font(.system(size: 11)).lineSpacing(2).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).contentShape(Rectangle())
                                .foregroundStyle(.black.opacity(focus == annotation.focusId ? 1 : 0.70))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !view.notes.isEmpty {
                Text(view.notes.joined(separator: "\n")).font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func naturalHeight(width: CGFloat) -> CGFloat {
        var result: CGFloat = 0
        var sections = 1
        if !view.title.isEmpty { result += textHeight(view.title, size: 12, width: width); sections += 1 }
        if !view.caption.isEmpty { result += textHeight(view.caption, size: 10, width: width); sections += 1 }
        switch view.kind {
        case "relation_graph", "argument": result += 220
        case "comparison":
            result += view.series.reduce(CGFloat(0)) { sum, series in sum + (series.values.count == 1 ? 51 : 27 + CGFloat(series.values.count) * 25) }
            result += CGFloat(max(0, view.series.count - 1)) * 13
        case "trend": result += max(120, CGFloat(view.series.count) * 120)
        case "timeline": result += CGFloat(view.events.count) * 46
        default: result += max(70, CGFloat(view.nodes.count) * 44)
        }
        if !view.annotations.isEmpty {
            let columns = min(3, view.annotations.count)
            let cellWidth = max(70, (width - CGFloat(columns - 1) * 12) / CGFloat(columns))
            let rows = (view.annotations.count + columns - 1) / columns
            let labelHeight = view.annotations.map { textHeight($0.label, size: 11, width: cellWidth, spacing: 2) }.max() ?? 14
            result += CGFloat(rows) * max(44, 21 + labelHeight) + CGFloat(max(0, rows - 1)) * 8
            sections += 1
        }
        if !view.notes.isEmpty {
            result += textHeight(view.notes.joined(separator: "\n"), size: 10, width: width, spacing: 3)
            sections += 1
        }
        return max(100, result + CGFloat(max(0, sections - 1)) * 9 + 5)
    }
    private func textHeight(_ text: String, size: CGFloat, width: CGFloat, spacing: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = spacing
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size)
        return ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph], context: nil).height)
        #else
        let font = NSFont.systemFont(ofSize: size)
        return ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph]).height)
        #endif
    }

    private var graph: some View {
        GeometryReader { geometry in
            let positions = graphPositions(geometry.size)
            let hasSelectedEdge = view.edges.contains { $0.focusId == focus }
            ZStack {
                ForEach(view.edges) { edge in
                    if let a = positions[edge.fromId], let b = positions[edge.toId] {
                        let active = !hasSelectedEdge || edge.focusId == focus
                        let path = edgeGeometry(edge, from: a, to: b)
                        GraphLine(start: path.start, end: path.end, control: path.control,
                                  arrow: !["unknown", "absent"].contains(edge.status))
                            .stroke(.black.opacity(active ? 0.8 : 0.13), style: StrokeStyle(
                                lineWidth: active ? 1.5 : 1,
                                dash: ["unknown", "inferred", "absent"].contains(edge.status) ? [3, 4] : []))
                            .allowsHitTesting(false)
                        if active {
                            Button { onSelect(edge.focusId) } label: {
                                VStack(spacing: 2) {
                                    Text(edge.label).font(.system(size: 11, weight: .medium))
                                    if edge.status == "unknown" { Text("待查").font(.system(size: 9)).foregroundStyle(muted) }
                                    if edge.status == "inferred" { Text("推断").font(.system(size: 9)).foregroundStyle(muted) }
                                    if edge.status == "absent" { Text("有依据表明不成立").font(.system(size: 9)).foregroundStyle(muted) }
                                }
                                .multilineTextAlignment(.center).padding(.horizontal, 4)
                                .frame(minHeight: 40).background(paper)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).position(path.label)
                        }
                    }
                }
                ForEach(view.nodes) { node in
                    if let point = positions[node.id] {
                        Button { onSelect(node.focusId) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: node.icon).font(.system(size: 23, weight: .light))
                                Text(node.label).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                                if !kindLabel(node.kind).isEmpty {
                                    Text(kindLabel(node.kind)).font(.system(size: 9)).foregroundStyle(muted)
                                }
                            }.padding(.horizontal, 3).padding(.vertical, 5)
                                .frame(width: nodeWidth(geometry.size), height: 73)
                                .background(focus == node.focusId ? Color.black.opacity(0.065) : paper)
                                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(focus == node.focusId ? 0.6 : 0.12)).frame(height: 0.5) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).position(point)
                            .accessibilityValue(focus == node.focusId ? "已选择" : "")
                    }
                }
            }
        }
    }
    private func nodeWidth(_ size: CGSize) -> CGFloat {
        let columns = max(1, (view.nodes.map(\.column).max() ?? 0) + 1)
        return min(110, size.width / CGFloat(columns) - 5)
    }
    private func graphPositions(_ size: CGSize) -> [String: CGPoint] {
        let maxRow = max(1, view.nodes.map(\.row).max() ?? 1)
        let maxColumn = max(1, view.nodes.map(\.column).max() ?? 1)
        let marginX = nodeWidth(size) / 2 + 2
        return Dictionary(uniqueKeysWithValues: view.nodes.map { node in
            (node.id, CGPoint(x: marginX + (size.width - 2 * marginX) * CGFloat(node.column) / CGFloat(maxColumn),
                              y: 37 + max(0, size.height - 74) * CGFloat(node.row) / CGFloat(maxRow)))
        })
    }
    private func edgeGeometry(_ edge: ReadingEdge, from a: CGPoint, to b: CGPoint) -> (start: CGPoint, end: CGPoint, control: CGPoint, label: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let start = CGPoint(x: a.x + ux * 40, y: a.y + uy * 40)
        let end = CGPoint(x: b.x - ux * 40, y: b.y - uy * 40)
        let reverse = view.edges.contains { $0.fromId == edge.toId && $0.toId == edge.fromId }
        let bend: CGFloat = reverse ? 19 : 0
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let control = CGPoint(x: middle.x - uy * bend, y: middle.y + ux * bend)
        let labelOffset: CGFloat = reverse ? 36 : 25
        let label = CGPoint(x: middle.x - uy * labelOffset, y: middle.y + ux * labelOffset)
        return (start, end, control, label)
    }
    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "legal_entity": return "具体公司"
        case "business_role": return "业务角色"
        case "reporting_scope": return "报表范围"
        case "activity": return "经营活动"
        default: return ""
        }
    }

    private var comparison: some View {
        let values = view.series.flatMap(\.values).map(\.plotValue)
        let commonUnits = Set(view.series.flatMap(\.values).map(\.displayUnit)).count <= 1
        return VStack(alignment: .leading, spacing: 13) {
            ForEach(view.series) { series in
                Button { onSelect(series.focusId) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(series.label).font(.system(size: 13, weight: .medium))
                            if series.values.count == 1, let first = series.values.first {
                                if let context = first.contextText { Text(context).font(.system(size: 11)).foregroundStyle(muted) }
                                Spacer(minLength: 4)
                                Text(first.text).font(.system(size: 22, design: .serif)).monospacedDigit()
                            }
                        }
                        ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
                            HStack(spacing: 9) {
                                if series.values.count > 1 { Text(value.label).font(.system(size: 10)).foregroundStyle(muted).frame(width: 70, alignment: .leading) }
                                signedBar(value.plotValue, domain: commonUnits ? values : series.values.map(\.plotValue),
                                          opacity: focus == series.focusId ? 0.85 : (index == 0 && series.values.count > 1 ? 0.28 : 0.72))
                                    .frame(height: 8)
                                if series.values.count > 1 { Text(value.text).font(.system(size: 15, design: .serif)).monospacedDigit().fixedSize() }
                            }.frame(minHeight: series.values.count > 1 ? 24 : 12)
                        }
                    }.padding(.vertical, 3).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.frame(maxHeight: .infinity, alignment: .center)
    }
    private func signedBar(_ value: Double, domain: [Double], opacity: Double) -> some View {
        GeometryReader { geometry in
            let low = min(0, domain.min() ?? 0), high = max(0, domain.max() ?? 0)
            let range = max(0.0000001, high - low)
            let zero = CGFloat((0 - low) / range) * geometry.size.width
            let point = CGFloat((value - low) / range) * geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.06))
                Rectangle().fill(.black.opacity(opacity)).frame(width: abs(point - zero)).offset(x: min(point, zero))
                if low < 0 && high > 0 { Rectangle().fill(.black.opacity(0.4)).frame(width: 0.5).offset(x: zero) }
            }
        }.accessibilityHidden(true)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(view.series) { series in
                GeometryReader { geometry in
                    let values = series.values
                    let points = trendPoints(values, size: geometry.size)
                    ZStack {
                        Path { path in
                            guard let first = points.first else { return }
                            path.move(to: first)
                            for point in points.dropFirst() { path.addLine(to: point) }
                        }.stroke(.black.opacity(0.7), lineWidth: 1.3).allowsHitTesting(false)
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            if points.indices.contains(index) {
                                Button { onSelect(series.focusId) } label: {
                                    VStack(spacing: 5) {
                                        Text(value.displayValue).font(.system(size: 18, design: .serif)).monospacedDigit()
                                        Circle().fill(.black).frame(width: 5, height: 5)
                                    }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).position(x: points[index].x, y: points[index].y - 12)
                                Text(value.label).font(.system(size: 10)).foregroundStyle(muted).multilineTextAlignment(.center)
                                    .frame(width: 87).position(x: points[index].x, y: geometry.size.height - 12)
                            }
                        }
                    }
                }.frame(minHeight: 110)
            }
        }
    }
    private func trendPoints(_ values: [ReadingValue], size: CGSize) -> [CGPoint] {
        let dates = values.map { value in periods.first { $0.id == value.periodId }.flatMap { Self.isoDate($0.end) } }
        let actualDates = dates.compactMap { $0?.timeIntervalSince1970 }
        let minDate = actualDates.min() ?? 0, dateRange = (actualDates.max() ?? 0) - minDate
        let low = min(0, values.map(\.plotValue).min() ?? 0), high = max(0, values.map(\.plotValue).max() ?? 0)
        let span = max(0.0000001, high - low)
        return values.enumerated().map { index, value in
            let x: Double
            if actualDates.count == values.count, dateRange > 0, let date = dates[index] {
                x = (date.timeIntervalSince1970 - minDate) / dateRange
            } else { x = values.count <= 1 ? 0.5 : Double(index) / Double(values.count - 1) }
            return CGPoint(x: 43 + CGFloat(x) * max(0, size.width - 86),
                           y: 30 + CGFloat(1 - (value.plotValue - low) / span) * max(0, size.height - 72))
        }
    }
    private static func isoDate(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.date(from: text)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(view.events) { event in timelineRow(event) }
        }.frame(maxHeight: .infinity, alignment: .center)
    }
    private func timelineRow(_ event: ReadingTimelineEvent) -> some View {
        let color: Color = event.stage == "proposed" ? paper : Color.black
        return Button { onSelect(event.focusId) } label: {
            HStack(spacing: 11) {
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.18)).frame(width: 0.5)
                    Circle().fill(color).frame(width: 7, height: 7).overlay(Circle().stroke(Color.black, lineWidth: 0.7))
                }.frame(width: 10, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortDate(event)).font(.system(size: 10)).foregroundStyle(muted)
                    Text(event.label).font(.system(size: 13, weight: focus == event.focusId ? .semibold : .regular))
                    Text(stageLabel(event.stage)).font(.system(size: 9)).foregroundStyle(muted)
                }
                Spacer(minLength: 4)
                Text(event.valueText).font(.system(size: 20, design: .serif)).monospacedDigit()
            }.frame(minHeight: 46).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(event.dateLabel + "，" + event.label + "，" + event.valueText + "，" + stageLabel(event.stage))
    }
    private func shortDate(_ event: ReadingTimelineEvent) -> String {
        guard let period = periods.first(where: { $0.id == event.datePeriodId }) else { return event.dateLabel }
        return period.start == period.end ? period.end : "截至 " + period.end
    }
    private func stageLabel(_ stage: String) -> String {
        switch stage {
        case "proposed": return "预案"
        case "approved": return "已批准"
        case "implementation_announced": return "实施公告"
        case "payment_recorded": return "公告记录已付"
        case "cash_flow_observed": return "现金流观察"
        case "cancelled": return "已注销"
        default: return stage
        }
    }
    private var textView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(view.nodes) { node in
                Button { onSelect(node.focusId) } label: {
                    Label(node.label, systemImage: node.icon).font(.system(size: 16)).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct GraphLine: Shape {
    let start, end, control: CGPoint
    let arrow: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: start); path.addQuadCurve(to: end, control: control)
        if arrow {
            let dx = end.x - control.x, dy = end.y - control.y, length = max(1, hypot(dx, dy))
            let ux = dx / length, uy = dy / length
            path.move(to: CGPoint(x: end.x - ux * 7 - uy * 3, y: end.y - uy * 7 + ux * 3))
            path.addLine(to: end)
            path.addLine(to: CGPoint(x: end.x - ux * 7 + uy * 3, y: end.y - uy * 7 - ux * 3))
        }
        return path
    }
}
