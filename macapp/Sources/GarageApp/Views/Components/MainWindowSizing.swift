import AppKit
import PythonXPCService
import SwiftUI

/// The main window's size follows what it shows. The setup assistant opens at `assistantSize`, also
/// when it opens in a window of another size (the relaunch after "Reset Database", which restores the
/// last frame, or "Setup Assistant…"). When it closes the window grows (animated) to `workingSize` if
/// it is smaller than that.
enum MainWindowSizing {
    /// The smallest content size the window allows, on any page.
    static let minimumSize = NSSize(width: 760, height: 520)

    /// The setup assistant's content size, between the minimum and 1.5× it: wide enough for three
    /// columns of locations on the data page (220-point step rail, 32-point page padding, three cards
    /// of at least 200 points, `FirstRunSelectDataPage.columns`), and tall enough to show each page
    /// without clipping at the bottom.
    static let assistantSize = NSSize(width: 920, height: 650)

    /// Roomy enough for Sources, Documents and Search side by side with the sidebar.
    static let workingSize = NSSize(width: 1100, height: 760)

    /// The frame to grow to from `current`, or nil when the window is already at least that big.
    /// The window keeps its centre where it can, never shrinks, and stays inside `visible` (the
    /// screen's visible frame, in the same coordinates).
    static func frameAfterFirstRun(current: NSRect, visible: NSRect, target: NSSize = workingSize) -> NSRect? {
        let width = min(max(current.width, target.width), visible.width)
        let height = min(max(current.height, target.height), visible.height)
        guard width > current.width || height > current.height else { return nil }
        return centred(width: width, height: height, around: current, in: visible)
    }

    /// The frame for the setup assistant from `current` (a frame size, title bar included), or nil when
    /// the window is already that size. The window keeps its centre and stays inside `visible`, which
    /// also caps the size on a small screen.
    static func frameForFirstRun(current: NSRect, visible: NSRect, target: NSSize) -> NSRect? {
        let width = min(target.width, visible.width)
        let height = min(target.height, visible.height)
        guard abs(width - current.width) >= 1 || abs(height - current.height) >= 1 else { return nil }
        return centred(width: width, height: height, around: current, in: visible)
    }

    @MainActor
    static func growAfterFirstRun(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              let frame = frameAfterFirstRun(current: window.frame, visible: visible)
        else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    @MainActor
    static func sizeForFirstRun(_ window: NSWindow, animate: Bool = true) {
        // `assistantSize` is a content size; the frame adds the title bar.
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: assistantSize)).size
        guard !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              let frame = frameForFirstRun(current: window.frame, visible: visible, target: target)
        else { return }
        window.setFrame(frame, display: animate, animate: animate)
    }

    /// The frame size `--window-size <width>x<height>` asks for (see `GarageAppLaunch`), or nil.
    static func requestedSize(in arguments: [String] = CommandLine.arguments) -> NSSize? {
        guard let index = arguments.firstIndex(of: GarageAppLaunch.windowSizeArgument),
              arguments.indices.contains(index + 1) else { return nil }
        let parts = arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        return NSSize(width: width, height: height)
    }

    /// Puts the window at `size` (a frame size) at the top left of its screen's visible frame, when
    /// the launch asked for one. Not while the setup assistant shows, which has a fixed size. The
    /// window may reach below the visible frame (behind the Dock): the store screenshots want exactly
    /// 1440 × 900 points, and a 1512 × 982 display with the Dock showing leaves 893.
    @MainActor
    static func applyRequestedSize(_ window: NSWindow) {
        guard let size = requestedSize(),
              !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        allowFramesBeyondVisibleFrame()
        let frame = NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    @MainActor private static var framesAllowedBeyondVisibleFrame = false

    /// AppKit fits a titled window into its screen's visible frame whenever it is shown or its frame
    /// set (`constrainFrameRect(_:to:)`), and SwiftUI owns the window's class, so no subclass can
    /// override that. Only for a launch with `--window-size`, a UI test's: every window's frame is
    /// then taken as given.
    @MainActor
    private static func allowFramesBeyondVisibleFrame() {
        guard !framesAllowedBeyondVisibleFrame,
              let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)))
        else { return }
        framesAllowedBeyondVisibleFrame = true
        let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        method_setImplementation(method, imp_implementationWithBlock(unconstrained))
    }

    private static func centred(width: CGFloat, height: CGFloat, around current: NSRect, in visible: NSRect) -> NSRect {
        var frame = NSRect(x: current.midX - width / 2, y: current.midY - height / 2, width: width, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return frame
    }
}

/// Hands the enclosing `NSWindow` to `onResolve` as soon as the view joins it, which is before the
/// window is first shown, so a size set there is the size the window opens at.
struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        ResolvingView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ResolvingView: NSView {
        let onResolve: (NSWindow) -> Void
        private var hasResolved = false

        init(onResolve: @escaping (NSWindow) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasResolved, let window else { return }
            hasResolved = true
            onResolve(window)
        }
    }
}
