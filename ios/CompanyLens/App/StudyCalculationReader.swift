import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// One published calculation at a time. No financial arithmetic is performed
/// here: both the result and its exact inputs come from ResearchLibrary.
struct StudyCalculationReader: View {
    let library: ResearchLibrary
    let calculationIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var source: EvidencePage?

    private let paper = Color(red: 0.965, green: 0.959, blue: 0.936)
    private let muted = Color.black.opacity(0.58)

    private var calculations: [ResearchCalculation] {
        calculationIDs.compactMap(library.calculation)
    }

    private var current: ResearchCalculation? {
        guard !calculations.isEmpty else { return nil }
        return calculations[min(index, calculations.count - 1)]
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 730
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                HStack {
                    Text("核对计算").font(.caption).tracking(2)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("关闭计算，回到图中")
                    .accessibilityIdentifier("study-close-calculation")
                }
                if let calculation = current {
                    Text(calculation.title)
                        .font(.system(size: compact ? 23 : 26, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("study-calculation-title")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(calculation.result.displayValue)
                            .font(.system(size: compact ? 35 : 42, design: .serif))
                            .monospacedDigit()
                        Text(calculation.result.displayUnit).font(.system(size: 15))
                    }
                    .textSelection(.enabled)
                    Text(calculation.explanation)
                        .font(.system(size: compact ? 14 : 15)).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if calculation.result.displayUnit == "亿元" && calculation.inputs.allSatisfy({ library.fact($0.factId)?.unit == "CNY" }) {
                        Text("下面保留原始金额；1亿元 = 100,000,000元。")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: compact ? 12 : 17) {
                        ForEach(Array(calculation.inputs.enumerated()), id: \.offset) { offset, input in
                            if let fact = library.fact(input.factId) {
                                inputRow(fact, input: input, offset: offset, compact: compact)
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这项计算不能说明什么")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(calculation.limitations, id: \.self) { limitation in
                            Text(limitation)
                                .font(.system(size: compact ? 14 : 15))
                                .foregroundStyle(muted).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Button { index = max(0, index - 1) } label: {
                            Image(systemName: "arrow.left").frame(width: 44, height: 44)
                        }
                        .disabled(index == 0)
                        .accessibilityLabel("前一个算式")
                        .accessibilityIdentifier("study-previous-calculation")
                        Spacer()
                        Text("算式 \(min(index + 1, calculations.count)) / \(calculations.count)")
                            .font(.caption.monospaced())
                        Spacer()
                        Button { index = min(calculations.count - 1, index + 1) } label: {
                            Image(systemName: "arrow.right").frame(width: 44, height: 44)
                        }
                        .disabled(index + 1 >= calculations.count)
                        .accessibilityLabel("后一个算式")
                        .accessibilityIdentifier("study-next-calculation")
                    }
                } else {
                    ContentUnavailableView("这处没有可打开的正式计算", systemImage: "equal.square")
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, compact ? 22 : 26)
            .padding(.vertical, compact ? 16 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(paper).foregroundStyle(.black).tint(.black)
        }
        .accessibilityIdentifier("study-calculation-reader")
        #if os(iOS)
        .presentationDetents([.large])
        .fullScreenCover(item: $source) { page in StudyPDFScreen(page: page, returnLabel: "回到计算") }
        #else
        .frame(width: 460, height: 790)
        .sheet(item: $source) { page in StudyPDFScreen(page: page, returnLabel: "回到计算").frame(width: 650, height: 850) }
        #endif
    }

    private func inputRow(_ fact: ResearchFact, input: CalculationInput, offset: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 9) {
                Text(operation(input.coefficient, first: offset == 0))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(muted).frame(width: 57, alignment: .leading)
                    .padding(.top, 4)
                Text(factTitle(fact, library: library))
                    .font(.system(size: compact ? 14 : 15, weight: .medium))
                    .lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = fact.evidenceIds.flatMap({ library.pages(for: $0) }).first {
                    Button { source = page } label: {
                        Image(systemName: "doc.viewfinder").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("核对" + factTitle(fact, library: library) + "的原页")
                    .accessibilityIdentifier("study-calculation-source-" + String(offset))
                }
            }
            Text(factValue(fact))
                .font(.system(size: compact ? 14 : 15)).monospacedDigit()
                .textSelection(.enabled).padding(.leading, 66)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func operation(_ coefficient: String, first: Bool) -> String {
        switch coefficient {
        case "1": return first ? "先取" : "加上"
        case "-1": return first ? "先取相反数" : "减去"
        default: return "乘以 " + coefficient
        }
    }

}
