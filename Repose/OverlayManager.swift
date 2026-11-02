import AppKit
import SwiftUI

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
class OverlayManager {
    private var overlayWindows: [NSPanel] = []
    private var keyMonitor: Any?

    func showBreakOverlay(timerManager: TimerManager) {
        dismissOverlay()

        for screen in NSScreen.screens {
            let isPrimary = screen == NSScreen.main
            let view = BreakOverlayView(timerManager: timerManager, isPrimary: isPrimary)

            let panel = KeyablePanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.contentView = NSHostingView(rootView: view)

            if isPrimary {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            overlayWindows.append(panel)
        }

        // Completed breaks always accept Return / keypad Enter / Escape,
        // independently of the setting that permits skipping unfinished breaks.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if timerManager.handleBreakKey(event.keyCode, isRepeat: event.isARepeat) { return nil }
            return event
        }
    }

    func dismissWithAnimation() {
        for window in overlayWindows {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.dismissOverlay()
        }
    }

    func dismissOverlay() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}
