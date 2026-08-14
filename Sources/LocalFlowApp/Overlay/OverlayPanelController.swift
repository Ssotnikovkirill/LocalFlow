import AppKit
import LocalFlowCore

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayPanelController {
    private let panel: NonActivatingPanel
    private let contentView = OverlayContentView()

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 104),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        panel.contentView = contentView
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.animationBehavior = .utilityWindow
    }

    func showListening() {
        contentView.setMode(.listening)
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func showFinalizing() {
        contentView.setMode(.finalizing)
    }

    func showFinalText(_ text: String) {
        contentView.setMode(.inserting)
        contentView.setTranscript(
            TranscriptPresentation(confirmed: text, tentative: "")
        )
    }

    func showError(_ message: String) {
        contentView.setMode(.error(message))
    }

    func updateTranscript(_ transcript: TranscriptPresentation) {
        contentView.setTranscript(transcript)
    }

    func updateAudioLevel(_ level: Float) {
        contentView.setAudioLevel(level)
    }

    func hide() {
        panel.orderOut(nil)
        contentView.reset()
    }

    private func positionOnActiveScreen() {
        // Positioning must never delay the first microphone buffer. A
        // cross-process Accessibility lookup can block on a busy target app,
        // whereas the pointer screen is immediately available.
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 56
        )
        panel.setFrameOrigin(origin)
    }
}

private final class OverlayContentView: NSVisualEffectView {
    enum Mode {
        case listening
        case finalizing
        case inserting
        case error(String)
    }

    private let waveform = WaveformView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let confirmedLabel = NSTextField(wrappingLabelWithString: "")
    private let tentativeLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func setMode(_ mode: Mode) {
        switch mode {
        case .listening:
            statusLabel.stringValue = "Слушаю"
            statusLabel.textColor = .systemGreen
            waveform.isActive = true
        case .finalizing:
            statusLabel.stringValue = "Распознаю…"
            statusLabel.textColor = .secondaryLabelColor
            waveform.isActive = false
        case .inserting:
            statusLabel.stringValue = "Вставляю…"
            statusLabel.textColor = .systemBlue
            waveform.isActive = false
        case let .error(message):
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            waveform.isActive = false
        }
    }

    func setTranscript(_ transcript: TranscriptPresentation) {
        confirmedLabel.stringValue = transcript.confirmed
        tentativeLabel.stringValue = transcript.tentative
    }

    func setAudioLevel(_ level: Float) {
        waveform.append(level: CGFloat(level))
    }

    func reset() {
        waveform.reset()
        confirmedLabel.stringValue = ""
        tentativeLabel.stringValue = ""
    }

    private func configure() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 1

        confirmedLabel.font = .systemFont(ofSize: 14, weight: .medium)
        confirmedLabel.textColor = .labelColor
        confirmedLabel.lineBreakMode = .byTruncatingHead
        confirmedLabel.maximumNumberOfLines = 2

        tentativeLabel.font = .systemFont(ofSize: 14, weight: .regular)
        tentativeLabel.textColor = .tertiaryLabelColor
        tentativeLabel.lineBreakMode = .byTruncatingTail
        tentativeLabel.maximumNumberOfLines = 2

        let transcriptRow = NSStackView(
            views: [confirmedLabel, tentativeLabel]
        )
        transcriptRow.orientation = .horizontal
        transcriptRow.alignment = .firstBaseline
        transcriptRow.spacing = 5
        transcriptRow.distribution = .fill

        let rootStack = NSStackView(
            views: [statusLabel, waveform, transcriptRow]
        )
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 7
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        waveform.translatesAutoresizingMaskIntoConstraints = false
        transcriptRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            waveform.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 26),
            transcriptRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])

        setMode(.listening)
    }
}

private final class WaveformView: NSView {
    var isActive = false {
        didSet { needsDisplay = true }
    }

    private var levels = Array(repeating: CGFloat(0.08), count: 42)

    override var isFlipped: Bool { true }

    func append(level: CGFloat) {
        levels.removeFirst()
        levels.append(min(max(level, 0.03), 1))
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: CGFloat(0.08), count: 42)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barWidth: CGFloat = 3
        let availableSpacing = max(
            1,
            (bounds.width - CGFloat(levels.count) * barWidth)
                / CGFloat(max(levels.count - 1, 1))
        )
        let color = isActive
            ? NSColor.systemGreen
            : NSColor.quaternaryLabelColor
        color.setFill()

        for (index, level) in levels.enumerated() {
            let height = max(3, bounds.height * level)
            let x = CGFloat(index) * (barWidth + availableSpacing)
            let rect = NSRect(
                x: x,
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }
}
