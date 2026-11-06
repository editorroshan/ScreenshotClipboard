import AppKit
import AVFoundation
@preconcurrency import QuickLookThumbnailing

// A floating preview in the corner, like macOS's own screenshot thumbnail, but
// shown after the file is already saved. Click to open, drag to drop the file
// into another app, swipe right (or wait) to dismiss, right-click for more.

@MainActor
final class PreviewController {
    private var panel: PreviewPanel?
    private var generation = 0

    func show(_ url: URL, isVideo: Bool) {
        generation += 1
        let ticket = generation
        Task {
            // A recording can still be finishing when its file appears, so keep
            // trying until it is readable (or a newer capture replaces it).
            let deadline = Date().addingTimeInterval(isVideo ? 2 * 60 * 60 : 10)
            var image: NSImage?
            while image == nil, ticket == generation, Date() < deadline,
                  FileManager.default.fileExists(atPath: url.path) {
                image = await Self.thumbnail(for: url)
                if image == nil { try? await Task.sleep(for: .milliseconds(isVideo ? 500 : 150)) }
            }
            guard ticket == generation else { return }
            guard let image else { log("No preview for \(url.lastPathComponent)"); return }

            let duration = isVideo ? await Self.duration(of: url) : nil
            guard ticket == generation else { return }

            panel?.dismiss(animated: false)
            let panel = PreviewPanel(url: url, image: image, isVideo: isVideo, duration: duration)
            panel.onClose = { [weak panel] in
                if self.panel === panel { self.panel = nil }
            }
            self.panel = panel
            panel.present()
            log("Previewing \(url.lastPathComponent)")
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: PreviewPanel.maxSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }

    private static func duration(of url: URL) async -> String? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        let total = Int(time.seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

@MainActor
final class PreviewPanel: NSPanel {
    static let maxSize = CGSize(width: 220, height: 150)
    private static let margin: CGFloat = 16
    private static let visibleFor: TimeInterval = 5

    let fileURL: URL
    let isVideo: Bool
    var onClose: (() -> Void)?

    private var restFrame = NSRect.zero
    private var dismissTimer: Timer?
    private var closing = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(url: URL, image: NSImage, isVideo: Bool, duration: String?) {
        fileURL = url
        self.isVideo = isVideo
        super.init(contentRect: NSRect(origin: .zero, size: Self.fit(image.size)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = PreviewView(panel: self, image: image, isVideo: isVideo, duration: duration)
    }

    // Fits the thumbnail inside maxSize without enlarging small captures.
    private static func fit(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return maxSize }
        let k = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        return CGSize(width: max(size.width * k, 48).rounded(), height: max(size.height * k, 48).rounded())
    }

    // Bottom-right of the screen the pointer is on, like the system thumbnail.
    private func cornerFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        return NSRect(x: area.maxX - frame.width - Self.margin, y: area.minY + Self.margin,
                      width: frame.width, height: frame.height)
    }

    private var offscreenFrame: NSRect { restFrame.offsetBy(dx: restFrame.width + Self.margin * 2, dy: 0) }

    func present() {
        restFrame = cornerFrame()
        setFrame(reduceMotion ? restFrame : offscreenFrame, display: true)
        alphaValue = reduceMotion ? 0 : 1
        orderFrontRegardless()
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().setFrame(restFrame, display: true)
            animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    func dismiss(animated: Bool = true) {
        guard !closing else { return }
        closing = true
        dismissTimer?.invalidate()
        guard animated else { finishClosing(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduceMotion { animator().setFrame(offscreenFrame, display: true) }
            animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.finishClosing() }
        })
    }

    private func finishClosing() {
        orderOut(nil)
        onClose?()
    }

    func scheduleDismiss() {
        guard !closing else { return }
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.visibleFor, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func pauseDismiss() { dismissTimer?.invalidate() }

    // The panel follows a two-finger swipe; past the threshold it leaves, otherwise it settles back.
    func swipe(to offset: CGFloat) {
        guard !closing else { return }
        pauseDismiss()
        let x = offset > 0 ? offset : offset / 4
        setFrameOrigin(NSPoint(x: restFrame.minX + x, y: restFrame.minY))
    }

    func endSwipe(at offset: CGFloat) {
        guard !closing else { return }
        if offset > min(60, restFrame.width * 0.3) { dismiss(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().setFrame(restFrame, display: true)
        }
        scheduleDismiss()
    }

    @objc func openFile() {
        let appID = isVideo ? "com.apple.QuickTimePlayerX" : "com.apple.Preview"
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            NSWorkspace.shared.open([fileURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(fileURL)
        }
        dismiss()
    }

    @objc func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        dismiss()
    }

    @objc func moveToTrash() {
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            log("Moved \(fileURL.lastPathComponent) to the Trash")
        } catch {
            log("Couldn't move \(fileURL.lastPathComponent) to the Trash: \(error.localizedDescription)")
        }
        dismiss()
    }

    @objc func closePreview() { dismiss() }
}

@MainActor
final class PreviewView: NSView, NSDraggingSource {
    private weak var panel: PreviewPanel?
    private let image: NSImage
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    private var swipeOffset: CGFloat = 0

    init(panel: PreviewPanel, image: NSImage, isVideo: Bool, duration: String?) {
        self.panel = panel
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        if isVideo { addBadge(duration: duration) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Play icon and length, so a recording reads differently from a screenshot.
    private func addBadge(duration: String?) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Screen recording")!)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        icon.contentTintColor = .white
        var views: [NSView] = [icon]
        if let duration {
            let label = NSTextField(labelWithString: duration)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            views.append(label)
        }
        let badge = NSStackView(views: views)
        badge.spacing = 4
        badge.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 7)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        badge.layer?.cornerRadius = 10
        badge.layer?.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            badge.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // Every click lands here, not on the badge.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { panel?.pauseDismiss() }
    override func mouseExited(with event: NSEvent) { if !dragging { panel?.scheduleDismiss() } }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !dragging, let panel else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragging = true
        panel.pauseDismiss()
        let item = NSDraggingItem(pasteboardWriter: panel.fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if mouseDownPoint != nil, !dragging { panel?.openFile() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let panel else { return }
        panel.pauseDismiss()
        let menu = NSMenu()
        menu.addItem(withTitle: panel.isVideo ? "Open in QuickTime Player" : "Open in Preview",
                     action: #selector(PreviewPanel.openFile), keyEquivalent: "")
        menu.addItem(withTitle: "Show in Finder", action: #selector(PreviewPanel.showInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(PreviewPanel.moveToTrash), keyEquivalent: "")
        menu.addItem(withTitle: "Close", action: #selector(PreviewPanel.closePreview), keyEquivalent: "")
        for item in menu.items { item.target = panel }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        panel.scheduleDismiss()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let panel, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        // Measure finger movement, whichever way the scroll direction setting points.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        switch event.phase {
        case .began:
            swipeOffset = dx
            panel.swipe(to: swipeOffset)
        case .changed:
            swipeOffset += dx
            panel.swipe(to: swipeOffset)
        case .ended, .cancelled:
            panel.endSwipe(at: swipeOffset)
            swipeOffset = 0
        default:
            break
        }
    }

    // Offer a copy, so dropping into Finder never moves the saved file away.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if operation.isEmpty { panel?.scheduleDismiss() } else { panel?.dismiss() }
    }
}
