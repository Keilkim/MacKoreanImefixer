import AppKit

/// Best-effort, original-only recovery UI for one automatic correction.
///
/// The controller owns presentation only. The event-tap layer owns the short-
/// lived replacement transaction and revalidates focus/text before restoring.
final class CorrectionNoticeController: NSObject {
    private var panel: NSPanel?
    private weak var button: NSButton?
    private var hideWorkItem: DispatchWorkItem?
    private var selectionAction: ((UInt64) -> Void)?
    private(set) var activeGeneration: UInt64?
    private let featureEnabled: Bool

    var visibleOriginal: String? {
        guard panel?.isVisible == true else { return nil }
        return button?.title
    }

    var visibleButtonScreenRect: CGRect? {
        guard let panel, panel.isVisible, let button else { return nil }
        return panel.convertToScreen(button.convert(button.bounds, to: nil))
    }

    var isVisibleNonactivatingAndInteractive: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.styleMask.contains(.nonactivatingPanel)
            && !panel.ignoresMouseEvents
    }

    /// Called only when the UI lifetime ends naturally. Short corrections keep
    /// their separate six-second Command-Z transaction; longer corrections have
    /// no event-tap shortcut and can discard their transaction here.
    var onExpiration: ((UInt64) -> Void)?

    /// How strongly to advertise the recovery affordance.
    ///
    /// A `medium` correction means the opposite reading was structurally
    /// possible but marked, so the user is more likely to disagree with it. That
    /// chip is tinted and stays for the entire undo window instead of the
    /// shorter default.
    enum Emphasis: Equatable {
        case standard
        case prominent

        var lifetime: TimeInterval {
            switch self {
            case .standard: return 4
            case .prominent: return 6
            }
        }

        init(_ tier: LayoutCorrectionPolicy.Tier) {
            switch tier {
            case .high: self = .standard
            case .medium: self = .prominent
            }
        }
    }

    /// The emphasis of the currently visible chip. Test observation only.
    private(set) var visibleEmphasis: Emphasis?

    init(
        featureEnabled: Bool = ProcessInfo.processInfo.environment[
            "MACKOR_ORIGINAL_CHOICE_CHIP"
        ] != "0"
    ) {
        self.featureEnabled = featureEnabled
        super.init()
    }

    /// Presents one clickable chip above the exact corrected range.
    /// Returns false when the experiment is disabled or the anchor is invalid.
    @discardableResult
    func show(
        original: String,
        generation: UInt64,
        replacementRect: CGRect,
        emphasis: Emphasis = .standard,
        onSelect: @escaping (UInt64) -> Void
    ) -> Bool {
        hide()
        guard featureEnabled,
              !original.isEmpty,
              replacementRect.origin.x.isFinite,
              replacementRect.origin.y.isFinite,
              replacementRect.size.width.isFinite,
              replacementRect.size.height.isFinite else {
            return false
        }

        activeGeneration = generation
        selectionAction = onSelect
        visibleEmphasis = emphasis

        let button = NSButton(
            title: original,
            target: self,
            action: #selector(selectOriginal(_:))
        )
        button.isBordered = false
        button.font = .monospacedSystemFont(
            ofSize: 12,
            weight: emphasis == .prominent ? .semibold : .medium
        )
        button.contentTintColor = emphasis == .prominent
            ? .controlAccentColor
            : .labelColor
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(original)
        self.button = button

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 9
        effectView.layer?.masksToBounds = true
        if emphasis == .prominent {
            effectView.layer?.borderWidth = 1.5
            effectView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        effectView.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 5),
            button.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -5),
        ])

        let fittingSize = effectView.fittingSize
        let size = CGSize(
            width: min(max(fittingSize.width, 44), 260),
            height: max(fittingSize.height, 28)
        )
        let origin = chipOrigin(size: size, replacementRect: replacementRect)

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = effectView
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.activeGeneration == generation else { return }
            self.hide()
            self.onExpiration?(generation)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + emphasis.lifetime,
            execute: workItem
        )
        return true
    }

    /// Tests the actual button content rectangle, not the panel shadow/frame.
    /// `quartzPoint` is the unmodified `CGEvent.location` value.
    func contains(quartzPoint: CGPoint, generation: UInt64) -> Bool {
        guard activeGeneration == generation,
              let panel,
              panel.isVisible,
              let button,
              let appKitPoint = FocusedInputSafety.appKitPoint(fromQuartz: quartzPoint) else {
            return false
        }
        let buttonWindowRect = button.convert(button.bounds, to: nil)
        let buttonScreenRect = panel.convertToScreen(buttonWindowRect)
        return buttonScreenRect.contains(appKitPoint)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        activeGeneration = nil
        selectionAction = nil
        visibleEmphasis = nil

        if let button {
            button.target = nil
            button.action = nil
        }
        button = nil
        panel?.contentView = nil
        panel?.orderOut(nil)
    }

    @objc private func selectOriginal(_ sender: NSButton) {
        guard sender === button,
              let generation = activeGeneration,
              let selectionAction else {
            hide()
            return
        }
        hide()
        selectionAction(generation)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func chipOrigin(size: CGSize, replacementRect: CGRect) -> CGPoint {
        let gap: CGFloat = 5
        var origin = CGPoint(
            x: replacementRect.midX - (size.width / 2),
            y: replacementRect.maxY + gap
        )

        let targetPoint = CGPoint(x: replacementRect.midX, y: replacementRect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(targetPoint) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return origin }

        if origin.y + size.height > visibleFrame.maxY {
            origin.y = replacementRect.minY - size.height - gap
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return origin
    }
}
