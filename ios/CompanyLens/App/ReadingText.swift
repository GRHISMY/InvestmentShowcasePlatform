import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Shared rendering of authored text and published scalar values.
struct ResearchText: View {
    let text: String
    var body: some View {
        let readable = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\(evidence\.md[^)]*\)"#, with: "$1", options: .regularExpression)
        Text((try? AttributedString(markdown: readable,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(readable))
            .lineSpacing(6).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}


func factValue(_ fact: ResearchFact) -> String {
    let unit: String
    switch fact.unit {
    case "CNY": unit = "元"
    case "CNY/share": unit = "元/股"
    case "percent": unit = "%"
    default: unit = fact.unit
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    let digits = fact.value.split(separator: ".").dropFirst().first?.count ?? 0
    formatter.minimumFractionDigits = digits
    formatter.maximumFractionDigits = digits
    return (formatter.string(from: NSDecimalNumber(string: fact.value, locale: Locale(identifier: "en_US_POSIX"))) ?? fact.value) + " " + unit
}

func factTitle(_ fact: ResearchFact, library: ResearchLibrary) -> String {
    let period = library.research.periods.first { $0.id == fact.periodId }?.label ?? ""
    return factTitle(fact, periodLabel: period)
}

func factTitle(_ fact: ResearchFact, periodLabel: String) -> String {
    // Translate machine-generated labels only; preserve authored Chinese labels.
    guard fact.label.contains(" / ") else { return fact.label }
    let names = [
        "cfo": "日常经营收款减去付款",
        "cash_sales": "销售收到的钱",
        "financial_loan_increase": "贷款与垫款净增加额",
        "money_funds": "账上货币资金",
        "term_deposits_outside_cash_equivalents": "未计入现金余额的定期存款和利息",
        "restricted_money_funds": "使用受限制的资金",
        "trading_financial_assets": "交易性金融资产",
        "other_debt_investments": "其他债权投资",
        "short_borrowings": "短期借款",
        "long_borrowings": "长期借款"
    ]
    guard let name = names[fact.metric] else { return fact.label }
    return periodLabel + " · " + name
}
