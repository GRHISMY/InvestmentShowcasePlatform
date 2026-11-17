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
    var allowsHorizontalScroll = true
    let onSelect: (String) -> Void
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var statusSize: CGFloat = 11
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 23
    @ScaledMetric(relativeTo: .body) private var nodeCardWidth: CGFloat = 160
    private var paper: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    private let muted = Color.secondary

    var body: some View {
        content
        .frame(minWidth: !allowsHorizontalScroll && ["relation_graph", "argument"].contains(view.kind)
               ? graphPlacement.size.width : nil, alignment: .leading)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !view.title.isEmpty { Text(view.title).font(.system(size: bodySize, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
            if !view.caption.isEmpty { Text(view.caption).font(.system(size: captionSize)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
            Group {
                switch view.kind {
                case "relation_graph", "argument": graph
                case "comparison": comparison
                case "trend": trend
                case "timeline": timeline
                default: textView
                }
            }.frame(maxWidth: .infinity)
            if !view.annotations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(view.annotations) { annotation in
                        Button { onSelect(annotation.focusId) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Image(systemName: annotation.icon).font(.system(size: bodySize, weight: .light))
                                Text(annotation.label).font(.system(size: captionSize)).lineSpacing(2).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).contentShape(Rectangle())
                                .foregroundStyle(focus == annotation.focusId ? Color.accentColor : Color.primary)
                        }.buttonStyle(.plain).accessibilityValue(focus == annotation.focusId ? "已选择" : "")
                    }
                }
            }
            if !view.notes.isEmpty {
                Text(view.notes.joined(separator: "\n")).font(.system(size: captionSize)).foregroundStyle(muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        let placement = graphPlacement
        return Group {
            if allowsHorizontalScroll {
                ScrollView(.horizontal) { graphCanvas(placement) }
                    .frame(height: placement.size.height)
            } else {
                graphCanvas(placement)
            }
        }
    }

    private struct GraphPlacement {
        let size: CGSize
        let frames: [String: CGRect]
    }

    private var graphPlacement: GraphPlacement {
        let width = min(260, nodeCardWidth), horizontalGap = edgeLabelWidth + 28, padding: CGFloat = 24
        let rows = max(1, (view.nodes.map(\.row).max() ?? 0) + 1)
        let columns = max(1, (view.nodes.map(\.column).max() ?? 0) + 1)
        let gap = max(72, (view.edges.map(edgeLabelHeight).max() ?? 44) + 24)
        var heights = Array(repeating: CGFloat(88), count: rows)
        for node in view.nodes { heights[node.row] = max(heights[node.row], nodeHeight(node, width: width)) }
        var rowOrigins: [CGFloat] = []
        var top = padding
        for height in heights { rowOrigins.append(top); top += height + gap }
        let frames = Dictionary(uniqueKeysWithValues: view.nodes.map { node in
            (node.id, CGRect(x: padding + CGFloat(node.column) * (width + horizontalGap),
                             y: rowOrigins[node.row], width: width, height: heights[node.row]))
        })
        return GraphPlacement(size: CGSize(width: padding * 2 + CGFloat(columns) * width + CGFloat(columns - 1) * horizontalGap,
                                           height: top - gap + padding), frames: frames)
    }

    private func nodeHeight(_ node: ReadingNode, width: CGFloat) -> CGFloat {
        var height: CGFloat = iconSize + 5 + 16 + textHeight(node.label, size: bodySize, width: width - 16) + 5
        if !kindLabel(node.kind).isEmpty { height += textHeight(kindLabel(node.kind), size: statusSize, width: width - 16) + 5 }
        if !node.subtitle.isEmpty { height += textHeight(node.subtitle, size: captionSize, width: width - 16) + 5 }
        return max(88, height)
    }

    private func edgeLabelHeight(_ edge: ReadingEdge) -> CGFloat {
        let status = relationStatus(edge.status)
        return max(44, 16 + textHeight(edge.label, size: captionSize, width: edgeLabelWidth - 16)
                   + (status.isEmpty ? 0 : textHeight(status, size: statusSize, width: edgeLabelWidth - 16) + 2)
                   + (edge.note.isEmpty ? 0 : textHeight(edge.note, size: captionSize, width: edgeLabelWidth - 16) + 2))
    }

    private var edgeLabelWidth: CGFloat { min(240, max(138, captionSize * 11)) }

    private func relationStatus(_ status: String) -> String {
        switch status {
        case "unknown": "待查"
        case "inferred": "推断"
        case "absent": "有依据表明不成立"
        default: ""
        }
    }

    private func graphCanvas(_ placement: GraphPlacement) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(view.edges) { edge in
                if let a = placement.frames[edge.fromId], let b = placement.frames[edge.toId] {
                    let active = !view.edges.contains { $0.focusId == focus } || edge.focusId == focus
                    let path = edgeGeometry(edge, from: a, to: b)
                    GraphLine(start: path.start, end: path.end, control: path.control,
                              arrow: !["unknown", "absent"].contains(edge.status))
                        .stroke(Color.primary.opacity(active ? 0.8 : 0.3), style: StrokeStyle(
                            lineWidth: active ? 1.5 : 1,
                            dash: ["unknown", "inferred", "absent"].contains(edge.status) ? [3, 4] : []))
                        .allowsHitTesting(false)
                    Button { onSelect(edge.focusId) } label: {
                        VStack(spacing: 2) {
                            Text(edge.label).font(.system(size: captionSize, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            if !relationStatus(edge.status).isEmpty {
                                Text(relationStatus(edge.status)).font(.system(size: statusSize)).foregroundStyle(muted)
                            }
                            if !edge.note.isEmpty {
                                Text(edge.note).font(.system(size: captionSize)).foregroundStyle(muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .multilineTextAlignment(.center).padding(8)
                        .frame(width: edgeLabelWidth, height: edgeLabelHeight(edge))
                        .background(paper, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(focus == edge.focusId ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).position(path.label)
                        .accessibilityValue(focus == edge.focusId ? "已选择" : "")
                }
            }
            ForEach(view.nodes) { node in
                if let frame = placement.frames[node.id] {
                    Button { onSelect(node.focusId) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: node.icon).font(.system(size: iconSize, weight: .light)).frame(height: iconSize + 5)
                            Text(node.label).font(.system(size: bodySize, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            if !kindLabel(node.kind).isEmpty {
                                Text(kindLabel(node.kind)).font(.system(size: statusSize)).foregroundStyle(muted)
                            }
                            if !node.subtitle.isEmpty {
                                Text(node.subtitle).font(.system(size: captionSize)).foregroundStyle(muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .multilineTextAlignment(.center).padding(8)
                        .frame(width: frame.width, height: frame.height)
                        .background(focus == node.focusId ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(focus == node.focusId ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).position(x: frame.midX, y: frame.midY)
                        .accessibilityValue(focus == node.focusId ? "已选择" : "")
                }
            }
        }.frame(width: placement.size.width, height: placement.size.height)
    }

    private func edgeGeometry(_ edge: ReadingEdge, from aFrame: CGRect, to bFrame: CGRect) -> (start: CGPoint, end: CGPoint, control: CGPoint, label: CGPoint) {
        let a = CGPoint(x: aFrame.midX, y: aFrame.midY), b = CGPoint(x: bFrame.midX, y: bFrame.midY)
        let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        func inset(_ frame: CGRect) -> CGFloat {
            min(frame.width / 2 / max(abs(ux), 0.0001), frame.height / 2 / max(abs(uy), 0.0001)) + 2
        }
        let start = CGPoint(x: a.x + ux * inset(aFrame), y: a.y + uy * inset(aFrame))
        let end = CGPoint(x: b.x - ux * inset(bFrame), y: b.y - uy * inset(bFrame))
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
                    VStack(alignment: .leading, spacing: 12) {
                        Text(series.label).font(.system(size: bodySize, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(value.label).font(.system(size: captionSize)).foregroundStyle(muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(value.text).font(.system(size: valueSize)).monospacedDigit()
                                    .fixedSize(horizontal: false, vertical: true)
                                if let context = value.contextText {
                                    Text(context).font(.system(size: captionSize)).foregroundStyle(muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if value.periodLabel != value.label {
                                    Text(value.periodLabel).font(.system(size: captionSize)).foregroundStyle(muted)
                                }
                                signedBar(value.plotValue, domain: commonUnits ? values : series.values.map(\.plotValue),
                                          opacity: focus == series.focusId ? 0.85 : (index == 0 && series.values.count > 1 ? 0.28 : 0.72))
                                    .frame(height: 10)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }.padding(16).frame(minHeight: 44)
                        .background(focus == series.focusId ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityValue(focus == series.focusId ? "已选择" : "")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func signedBar(_ value: Double, domain: [Double], opacity: Double) -> some View {
        GeometryReader { geometry in
            let low = min(0, domain.min() ?? 0), high = max(0, domain.max() ?? 0)
            let range = max(0.0000001, high - low)
            let zero = CGFloat((0 - low) / range) * geometry.size.width
            let point = CGFloat((value - low) / range) * geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                Rectangle().fill(Color.primary.opacity(opacity)).frame(width: abs(point - zero)).offset(x: min(point, zero))
                if low < 0 && high > 0 { Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 0.5).offset(x: zero) }
            }
        }.accessibilityHidden(true)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(view.series) { series in
                VStack(alignment: .leading, spacing: 10) {
                    Text(series.label).font(.system(size: bodySize, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("单位：" + Set(series.values.map(\.displayUnit)).sorted().joined(separator: "、"))
                        .font(.system(size: captionSize)).foregroundStyle(muted)
                    GeometryReader { geometry in
                        let points = trendPoints(series.values, size: geometry.size)
                        ZStack {
                            Path { path in
                                guard let first = points.first else { return }
                                path.move(to: first)
                                for point in points.dropFirst() { path.addLine(to: point) }
                            }
                            .stroke(Color.primary.opacity(focus == series.focusId ? 0.85 : 0.6), lineWidth: 1.5)
                            .allowsHitTesting(false)
                            ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
                                if points.indices.contains(index) {
                                    Button { onSelect(series.focusId) } label: {
                                        Circle().fill(Color.primary).frame(width: 7, height: 7)
                                            .frame(width: 44, height: 44).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).position(points[index])
                                    .accessibilityLabel(series.label + "，" + value.periodLabel + "，" + value.text)
                                    .accessibilityValue(focus == series.focusId ? "已选择" : "")
                                }
                            }
                        }
                    }.frame(height: max(150, valueSize * 4))
                    if let first = series.values.first, let last = series.values.last {
                        HStack(alignment: .top) {
                            Text(first.label).frame(maxWidth: .infinity, alignment: .leading)
                            Text(last.label).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: captionSize)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(series.values.enumerated()), id: \.offset) { _, value in
                        Button { onSelect(series.focusId) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(value.label).font(.system(size: captionSize)).foregroundStyle(muted)
                                if value.periodLabel != value.label {
                                    Text(value.periodLabel).font(.system(size: captionSize)).foregroundStyle(muted)
                                }
                                Text(value.text).font(.system(size: valueSize)).monospacedDigit()
                                    .fixedSize(horizontal: false, vertical: true)
                                if let context = value.contextText {
                                    Text(context).font(.system(size: captionSize)).foregroundStyle(muted)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(focus == series.focusId ? "已选择" : "")
                    }
                }
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
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func timelineRow(_ event: ReadingTimelineEvent) -> some View {
        let color: Color = event.stage == "proposed" ? paper : Color.primary
        return Button { onSelect(event.focusId) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.primary, lineWidth: 0.7))
                    Text(shortDate(event)).font(.system(size: captionSize)).foregroundStyle(muted)
                }
                Text(event.label).font(.system(size: bodySize, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(stageLabel(event.stage)).font(.system(size: captionSize)).foregroundStyle(muted)
                if !event.valueText.isEmpty {
                    Text(event.valueText).font(.system(size: valueSize)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !event.note.isEmpty {
                    Text(event.note).font(.system(size: captionSize)).foregroundStyle(muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 0.5) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(focus == event.focusId ? "已选择" : "")
            .accessibilityLabel(event.dateLabel + "，" + event.label + "，" + event.valueText + "，" + stageLabel(event.stage) + "，" + event.note)
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
                    VStack(alignment: .leading, spacing: 7) {
                        Label {
                            Text(node.label).fixedSize(horizontal: false, vertical: true)
                        } icon: { Image(systemName: node.icon) }
                        .font(.system(size: bodySize))
                        if !node.subtitle.isEmpty {
                            Text(node.subtitle).font(.system(size: captionSize)).foregroundStyle(muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(focus == node.focusId ? "已选择" : "")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
