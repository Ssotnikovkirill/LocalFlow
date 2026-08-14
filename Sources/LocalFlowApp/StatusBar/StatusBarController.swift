import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openSettings: () -> Void
    private let requestPermissions: () -> Void
    private let cancelSession: () -> Void

    init(
        openSettings: @escaping () -> Void,
        requestPermissions: @escaping () -> Void,
        cancelSession: @escaping () -> Void
    ) {
        self.openSettings = openSettings
        self.requestPermissions = requestPermissions
        self.cancelSession = cancelSession
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()
        configure()
    }

    func updateStatus(_ text: String) {
        statusMenuItem.title = "Статус: \(text)"
    }

    private func configure() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform.circle.fill",
                accessibilityDescription: "LocalFlow"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Настройки…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        ).target = self
        menu.addItem(
            withTitle: "Запросить разрешения…",
            action: #selector(requestPermissionsAction),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Отменить диктовку",
            action: #selector(cancelAction),
            keyEquivalent: "\u{1b}"
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Завершить LocalFlow",
            action: #selector(quitAction),
            keyEquivalent: "q"
        ).target = self

        statusItem.menu = menu
    }

    @objc
    private func openSettingsAction() {
        openSettings()
    }

    @objc
    private func requestPermissionsAction() {
        requestPermissions()
    }

    @objc
    private func cancelAction() {
        cancelSession()
    }

    @objc
    private func quitAction() {
        NSApp.terminate(nil)
    }
}
