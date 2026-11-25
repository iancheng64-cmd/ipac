import SwiftUI

/// Changes presentation language without replacing a running Mac's identity.
struct AppLanguageScope<Content: View>: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.current.rawValue
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.locale, (AppLanguage(rawValue: language) ?? .zhHant).locale)
    }
}
