import AppKit
import Combine
import OSLog
import RamRadarCore
import SwiftUI

private let log = Logger(subsystem: "io.github.gemscng.RamRadar", category: "status-item")

/// The menu-bar icon, its red dot, and the dropdown panel.
///
/// The dropdown is our own panel rather than an `NSPopover`: on macOS 26 menu-bar items are
/// drawn by Control Centre, and the status button's window reports an off-screen frame, so a
/// popover anchored to it opens partly above the top of the screen. The panel is placed from
/// the click location instead, directly under the menu bar.
@MainActor
final class StatusItemController: NSObject {
    private static let panelWidth: CGFloat = 440
    private static let maxPanelHeight: CGFloat = 680

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: DropdownPanel
    private let dot = NSView()
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingView(rootView: PanelView().environmentObject(model))
        panel = DropdownPanel(content: hosting)
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "RamRadar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePanel)

            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.isHidden = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
            ])
        }

        // `apply` sets the snapshot before the findings, so one subscription sees both.
        model.$findings
            .receive(on: RunLoop.main)
            .sink { [weak self] findings in self?.update(findings: findings, snapshot: model.snapshot) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.closePanel() }
            .store(in: &cancellables)
    }

    private func update(findings: [Finding], snapshot: Snapshot?) {
        dot.isHidden = findings.isEmpty
        guard let button = item.button else { return }
        var tip = "RamRadar"
        if let s = snapshot?.system {
            tip += " — \(ByteFormat.string(s.used)) of \(ByteFormat.string(s.physical)) used"
        }
        if !findings.isEmpty {
            tip += " · \(findings.count) suggestion\(findings.count == 1 ? "" : "s")"
        }
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        let dotState = dot.isHidden ? "hidden" : "shown"
        log.info("check done: \(findings.count) suggestions, red dot \(dotState, privacy: .public)")
    }

    // MARK: Panel

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        model.refresh()
        let anchor = anchorPoint()
        let screen = NSScreen.screens.first { NSPointInRect(anchor, $0.frame) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = Self.panelWidth
        let height = min(Self.maxPanelHeight, visible.height - 12)
        model.panelHeight = height

        let x = min(max(anchor.x - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let frame = NSRect(x: x, y: visible.maxY - 6 - height, width: width, height: height)
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        log.info("panel at \(Int(frame.minX), privacy: .public),\(Int(frame.minY), privacy: .public) \(Int(frame.width), privacy: .public)x\(Int(frame.height), privacy: .public); screen visible top \(Int(visible.maxY), privacy: .public)")

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            self?.closePanel()
            return nil
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        if let m = escapeMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    /// Where the icon is on screen. Prefer the click; the button's own window frame is only
    /// trusted when it actually lies on a screen.
    private func anchorPoint() -> NSPoint {
        if let type = NSApp.currentEvent?.type, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(type) {
            return NSEvent.mouseLocation
        }
        if let frame = item.button?.window?.frame,
           NSScreen.screens.contains(where: { NSContainsRect($0.frame, frame) }) {
            return NSPoint(x: frame.midX, y: frame.minY)
        }
        let screen = NSScreen.main?.frame ?? .zero
        return NSPoint(x: screen.maxX - 200, y: screen.maxY - 1)
    }
}

/// Borderless panel with the standard popover material and rounded corners.
final class DropdownPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }
}
