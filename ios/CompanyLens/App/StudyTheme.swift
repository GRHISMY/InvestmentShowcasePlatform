import SwiftUI

enum StudyInk {
    #if canImport(UIKit)
    static let paper = Color(uiColor: .systemBackground)
    static let grouped = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    static let paper = Color(nsColor: .textBackgroundColor)
    static let grouped = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    #endif
    static let line = Color.primary.opacity(0.16)
    static let muted = Color.secondary
}
