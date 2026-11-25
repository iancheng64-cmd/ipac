import AppKit
import Foundation
import SwiftUI

private final class ProbeIdentity: ObservableObject {
    let id = UUID()
}

private final class Recorder {
    var text = ""
    var identities: Set<UUID> = []
}

private struct ProbeReport: NSViewRepresentable {
    let text: String
    let identity: UUID
    let recorder: Recorder

    func makeNSView(context: Context) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        view.stringValue = text
        recorder.text = text
        recorder.identities.insert(identity)
    }
}

private struct LanguageProbe: View {
    @Environment(\.locale) private var locale
    @StateObject private var identity = ProbeIdentity()
    let bundle: Bundle
    let recorder: Recorder

    var body: some View {
        ProbeReport(
            text: L10n.text("介面語言", language: AppLanguage(rawValue: locale.identifier) ?? .zhHant,
                           bundle: bundle),
            identity: identity.id, recorder: recorder
        )
    }
}

@main
struct AppLanguagePresentationTests {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Pass the compiled localization bundle")
        }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "com.henge.tests.language-ui.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        AppLanguage.zhHant.save(to: preferences)

        let main = Recorder()
        let external = Recorder()
        func hosting(_ recorder: Recorder) -> NSHostingView<some View> {
            NSHostingView(rootView: AppLanguageScope {
                LanguageProbe(bundle: bundle, recorder: recorder)
            }.defaultAppStorage(preferences))
        }
        let mainView = hosting(main)
        let externalView = hosting(external)
        let mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        let externalWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        mainWindow.contentView = mainView
        externalWindow.contentView = externalView
        func settle() {
            mainView.layoutSubtreeIfNeeded()
            externalView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        settle()
        expect(main.text == "介面語言" && external.text == "介面語言",
               "Main and external roots start in Chinese")

        AppLanguage.en.save(to: preferences)
        settle()
        let english = L10n.text("介面語言", language: .en, bundle: bundle)
        expect(main.text == english && external.text == english,
               "Changing preferences refreshes both roots immediately")

        AppLanguage.zhHant.save(to: preferences)
        settle()
        expect(main.text == "介面語言" && external.text == "介面語言",
               "Both roots can switch back without re-creation")

        preferences.set("invalid-language", forKey: AppLanguage.storageKey)
        settle()
        expect(main.text == "介面語言" && external.text == "介面語言",
               "Invalid stored values use the source language")
        expect(main.identities.count == 1 && external.identities.count == 1,
               "State objects retain their identity through all language changes")

        print("Language presentation: \(checks) checks passed")
    }
}
