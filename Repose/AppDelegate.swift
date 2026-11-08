import AppKit
import ServiceManagement
#if !LOCAL_BUILD
import Sparkle
#endif
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timerManager: TimerManager!
    #if !LOCAL_BUILD
    private var updaterController: SPUStandardUpdaterController!
    #endif
    private var statusBarTimer: Timer?
    private var menuIsOpen = false
    private var lastDiagnosticSignature = ""
    private var lastDiagnosticWrite = Date.distantPast

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var pauseResumeMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var confirmBreakMenuItem: NSMenuItem!
    private var workIntervalMenu: NSMenu!
    private var breakDurationMenu: NSMenu!
    private var pauseDuringMeetingsMenuItem: NSMenuItem!
    private var includeBrowserMicrophonesMenuItem: NSMenuItem!
    private var allowSkipMenuItem: NSMenuItem!
    private var pauseWhenIdleMenuItem: NSMenuItem!
    private var muteSoundsMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    #if DEBUG
    private let workIntervalOptions = [1, 5, 10, 15, 20, 25, 30, 45, 60, 90]
    private let breakDurationOptions = [10, 20, 30, 60, 120, 300, 600]
    #else
    private let workIntervalOptions = [5, 10, 15, 20, 25, 30, 45, 60, 90]
    private let breakDurationOptions = [20, 30, 60, 120, 300, 600]
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        timerManager = TimerManager()
        #if !LOCAL_BUILD
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly

        buildMenu()
        startStatusBarTimer()
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Status line (disabled, just for display)
        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        confirmBreakMenuItem = NSMenuItem(title: "Confirm & Continue", action: #selector(confirmBreak), keyEquivalent: "")
        confirmBreakMenuItem.target = self
        confirmBreakMenuItem.isHidden = true
        menu.addItem(confirmBreakMenuItem)

        menu.addItem(.separator())

        // Pause / Resume
        pauseResumeMenuItem = NSMenuItem(title: "Pause Timer", action: #selector(togglePause), keyEquivalent: "p")
        pauseResumeMenuItem.target = self
        menu.addItem(pauseResumeMenuItem)

        let restartItem = NSMenuItem(title: "Restart Timer", action: #selector(restartTimer), keyEquivalent: "r")
        restartItem.target = self
        restartMenuItem = restartItem
        menu.addItem(restartItem)

        menu.addItem(.separator())

        // Work Interval submenu
        let workItem = NSMenuItem(title: "Work Interval", action: nil, keyEquivalent: "")
        workIntervalMenu = NSMenu()
        for minutes in workIntervalOptions {
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(setWorkInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            workIntervalMenu.addItem(item)
        }
        workItem.submenu = workIntervalMenu
        menu.addItem(workItem)

        // Break Duration submenu
        let breakItem = NSMenuItem(title: "Break Duration", action: nil, keyEquivalent: "")
        breakDurationMenu = NSMenu()
        for seconds in breakDurationOptions {
            let item = NSMenuItem(title: formatBreakDuration(seconds), action: #selector(setBreakDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            breakDurationMenu.addItem(item)
        }
        breakItem.submenu = breakDurationMenu
        menu.addItem(breakItem)

        menu.addItem(.separator())

        // Toggles
        pauseDuringMeetingsMenuItem = NSMenuItem(title: "Pause During Meetings", action: #selector(toggleBoolSetting(_:)), keyEquivalent: "")
        pauseDuringMeetingsMenuItem.target = self
        pauseDuringMeetingsMenuItem.representedObject = SettingsKey.pauseDuringMeetings
        menu.addItem(pauseDuringMeetingsMenuItem)

        includeBrowserMicrophonesMenuItem = NSMenuItem(title: "Include Browser Microphones", action: #selector(toggleBoolSetting(_:)), keyEquivalent: "")
        includeBrowserMicrophonesMenuItem.target = self
        includeBrowserMicrophonesMenuItem.representedObject = SettingsKey.includeBrowserMicrophones
        includeBrowserMicrophonesMenuItem.indentationLevel = 1
        includeBrowserMicrophonesMenuItem.toolTip = "Also pause for browser microphone use, including ChatGPT voice and audio-only web calls. Requires macOS 14.2 or later."
        menu.addItem(includeBrowserMicrophonesMenuItem)

        pauseWhenIdleMenuItem = NSMenuItem(title: "Pause When Idle", action: #selector(toggleBoolSetting(_:)), keyEquivalent: "")
        pauseWhenIdleMenuItem.target = self
        pauseWhenIdleMenuItem.representedObject = SettingsKey.pauseWhenIdle
        menu.addItem(pauseWhenIdleMenuItem)

        allowSkipMenuItem = NSMenuItem(title: "Allow Skip Break", action: #selector(toggleBoolSetting(_:)), keyEquivalent: "")
        allowSkipMenuItem.target = self
        allowSkipMenuItem.representedObject = SettingsKey.allowSkipBreak
        menu.addItem(allowSkipMenuItem)

        muteSoundsMenuItem = NSMenuItem(title: "Mute Sounds", action: #selector(toggleBoolSetting(_:)), keyEquivalent: "")
        muteSoundsMenuItem.target = self
        muteSoundsMenuItem.representedObject = SettingsKey.muteSounds
        menu.addItem(muteSoundsMenuItem)

        menu.addItem(.separator())

        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Repose", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // An upstream update would replace a locally customized build.
        #if !LOCAL_BUILD
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)
        #endif

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Repose", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate — update items right before the menu opens

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menuIsOpen = true
            timerManager.refreshMeetingStatus()
            updateStatusBarTitle()
            updateMenuItems()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menuIsOpen = false
        }
    }

    private func updateStatusText() {
        switch timerManager.state {
        case .working:
            statusMenuItem.title = "Next break in \(formatTime(timerManager.remainingSeconds))"
        case .onBreak:
            statusMenuItem.title = timerManager.isAwaitingBreakConfirmation ? "Break complete — confirm to continue" : "On a break"
        case .paused:
            statusMenuItem.title = timerManager.pauseStatusText ?? "Paused"
        }
    }

    private func updateMenuItems() {
        updateStatusText()
        restartMenuItem.isEnabled = timerManager.state != .onBreak
        confirmBreakMenuItem.isHidden = !timerManager.isAwaitingBreakConfirmation

        // Pause / Resume
        switch timerManager.state {
        case .working:
            pauseResumeMenuItem.title = "Pause Timer"
            pauseResumeMenuItem.isEnabled = true
            pauseResumeMenuItem.isHidden = false
        case .paused:
            pauseResumeMenuItem.title = "Resume Timer"
            pauseResumeMenuItem.isEnabled = timerManager.currentPauseReason != .meeting
            pauseResumeMenuItem.isHidden = false
        default:
            pauseResumeMenuItem.isHidden = true
        }

        // Work interval checkmarks
        let currentWork = UserDefaults.standard.integer(forKey: SettingsKey.workDurationMinutes)
        for item in workIntervalMenu.items {
            item.state = item.tag == currentWork ? .on : .off
        }

        // Break duration checkmarks
        let currentBreak = UserDefaults.standard.integer(forKey: SettingsKey.breakDurationSeconds)
        for item in breakDurationMenu.items {
            item.state = item.tag == currentBreak ? .on : .off
        }

        // Toggle states
        pauseDuringMeetingsMenuItem.state = UserDefaults.standard.bool(forKey: SettingsKey.pauseDuringMeetings) ? .on : .off
        includeBrowserMicrophonesMenuItem.state = UserDefaults.standard.bool(forKey: SettingsKey.includeBrowserMicrophones) ? .on : .off
        if #available(macOS 14.2, *) {
            includeBrowserMicrophonesMenuItem.isEnabled = pauseDuringMeetingsMenuItem.state == .on
        } else {
            includeBrowserMicrophonesMenuItem.isEnabled = false
        }
        pauseWhenIdleMenuItem.state = UserDefaults.standard.bool(forKey: SettingsKey.pauseWhenIdle) ? .on : .off
        allowSkipMenuItem.state = UserDefaults.standard.bool(forKey: SettingsKey.allowSkipBreak) ? .on : .off
        muteSoundsMenuItem.state = UserDefaults.standard.bool(forKey: SettingsKey.muteSounds) ? .on : .off
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Status bar progress updates

    private func startStatusBarTimer() {
        updateStatusBarTitle()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateStatusBarTitle()
                if self.menuIsOpen {
                    self.updateMenuItems()
                }
            }
        }
        // .common includes both default and eventTracking modes,
        // so updates work even while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        statusBarTimer = timer
    }

    private func updateStatusBarTitle() {
        guard let button = statusItem.button else { return }
        let duration = timerManager.state == .onBreak
            ? timerManager.breakDurationSeconds
            : timerManager.workDurationSeconds
        let progress = Double(timerManager.remainingSeconds) / Double(max(duration, 1))
        button.title = ""
        button.image = MenuBarProgressIcon.image(
            remainingFraction: progress,
            pauseReason: timerManager.currentPauseReason,
            onBreak: timerManager.state == .onBreak
        )
        let source = timerManager.currentPauseReason == .meeting ? "\n\(timerManager.pauseStatusText ?? "")" : ""
        let status = "Repose — \(timerManager.menuBarText)\(source)"
        button.toolTip = status
        button.setAccessibilityLabel("Repose")
        button.setAccessibilityValue(timerManager.menuBarText)
        writeDiagnosticStatus()
    }

    private func writeDiagnosticStatus() {
        let state = String(describing: timerManager.state)
        let reason = timerManager.currentPauseReason.map { String(describing: $0) } ?? "none"
        let source = timerManager.meetingDetector.meetingSource ?? "none"
        let signature = "\(state)|\(reason)|\(source)|\(timerManager.screenIsLocked)|\(timerManager.isAwaitingBreakConfirmation)"
        let date = Date()
        guard signature != lastDiagnosticSignature || date.timeIntervalSince(lastDiagnosticWrite) >= 30 else { return }
        let status: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "state": state, "pauseReason": reason, "captureSource": source,
            "remainingSeconds": timerManager.remainingSeconds,
            "screenIsLocked": timerManager.screenIsLocked,
            "awaitingConfirmation": timerManager.isAwaitingBreakConfirmation,
            "sampledAt": ISO8601DateFormatter().string(from: date),
        ]
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Repose Ring", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = support.appendingPathComponent("status.json")
            try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastDiagnosticSignature = signature
            lastDiagnosticWrite = date
        } catch {
            // Optional local diagnostics must never interrupt reminders.
        }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        timerManager.togglePause()
    }

    @objc private func restartTimer() {
        timerManager.start()
    }

    @objc private func confirmBreak() {
        timerManager.confirmBreak()
    }

    @objc private func setWorkInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: SettingsKey.workDurationMinutes)
        if timerManager.state == .working {
            timerManager.start()
        }
    }

    @objc private func setBreakDuration(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: SettingsKey.breakDurationSeconds)
    }

    @objc private func toggleBoolSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        try? enabled ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register()
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "by Fikri Karim\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        credits.append(NSAttributedString(
            string: "github.com/fikrikarim/repose",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/fikrikarim/repose")!,
            ]
        ))

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Repose",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits,
        ])
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func formatBreakDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) sec"
        } else {
            return "\(seconds / 60) min"
        }
    }
}

/// A monochrome template image follows the menu bar's light/dark appearance.
enum MenuBarProgressIcon {
    static func image(remainingFraction: Double, pauseReason: PauseReason? = nil, onBreak: Bool = false) -> NSImage {
        let fraction = remainingFraction.isFinite ? min(max(remainingFraction, 0), 1) : 0
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bounds = NSRect(x: 2, y: 2, width: 14, height: 14)
            let track = NSBezierPath(ovalIn: bounds)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            NSColor.black.setStroke()
            if fraction >= 1 {
                track.stroke()
            } else if fraction > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                // The remaining arc starts at twelve o'clock, clockwise.
                arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 7,
                              startAngle: 90, endAngle: 90 - CGFloat(fraction * 360), clockwise: true)
                arc.stroke()
            }

            NSColor.black.setFill()
            switch pauseReason {
            case .manual:
                NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 2, height: 6),
                             xRadius: 0.5, yRadius: 0.5).fill()
                NSBezierPath(roundedRect: NSRect(x: 10, y: 6, width: 2, height: 6),
                             xRadius: 0.5, yRadius: 0.5).fill()
            case .idle, .meeting:
                let symbolName = pauseReason == .idle ? "moon.fill" : "video.fill"
                let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
                if let symbol {
                    // Preserve SF Symbol proportions inside the ring's clear center.
                    let scale = min(9 / symbol.size.width, 8 / symbol.size.height)
                    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                    symbol.draw(in: NSRect(x: 9 - size.width / 2, y: 9 - size.height / 2,
                                           width: size.width, height: size.height))
                }
            case nil:
                if onBreak {
                    NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
