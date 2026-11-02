import Foundation
import Combine
import AppKit
import CoreGraphics
import IOKit.pwr_mgt

enum TimerState {
    case working
    case onBreak
    case paused
}

enum PauseReason {
    case manual
    case meeting
    case idle
}

enum SettingsKey {
    static let workDurationMinutes = "workDurationMinutes"
    static let breakDurationSeconds = "breakDurationSeconds"
    static let pauseDuringMeetings = "pauseDuringMeetings"
    static let allowSkipBreak = "allowSkipBreak"
    static let muteSounds = "muteSounds"
    static let pauseWhenIdle = "pauseWhenIdle"
}

@MainActor
class TimerManager: ObservableObject {
    @Published var state: TimerState = .working
    @Published var remainingSeconds: Int = 0
    private(set) var screenIsLocked = false

    private var timerCancellable: AnyCancellable?
    private var tickCount: Int = 0
    private var secondsBeforePause: Int = 0
    private var pauseReason: PauseReason = .manual

    let meetingDetector: MeetingDetector
    let overlayManager = OverlayManager()
    private let defaults: UserDefaults
    private let now: () -> Date
    private var breakDeadline: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObservers: [NSObjectProtocol] = []

    var isAwaitingBreakConfirmation: Bool { state == .onBreak && remainingSeconds == 0 }

    // Activity to prevent App Nap
    private var activity: NSObjectProtocol?

    var workDurationSeconds: Int {
        defaults.integer(forKey: SettingsKey.workDurationMinutes).clamped(to: 1...120) * 60
    }

    var breakDurationSeconds: Int {
        let val = defaults.integer(forKey: SettingsKey.breakDurationSeconds)
        return val.clamped(to: 5...300)
    }

    var pauseDuringMeetings: Bool {
        defaults.bool(forKey: SettingsKey.pauseDuringMeetings)
    }

    var muteSounds: Bool {
        defaults.bool(forKey: SettingsKey.muteSounds)
    }

    var pauseWhenIdle: Bool {
        defaults.bool(forKey: SettingsKey.pauseWhenIdle)
    }

    var menuBarText: String {
        switch state {
        case .working:
            return formatTime(remainingSeconds)
        case .onBreak:
            return isAwaitingBreakConfirmation ? "Break complete — confirm to continue" : "Break \(formatTime(remainingSeconds))"
        case .paused:
            switch pauseReason {
            case .meeting:
                return "Meeting \(formatTime(secondsBeforePause))"
            case .idle:
                return "Idle"
            case .manual:
                return "Paused \(formatTime(secondsBeforePause))"
            }
        }
    }

    var pauseStatusText: String? {
        guard state == .paused else { return nil }
        switch pauseReason {
        case .meeting:
            return meetingDetector.meetingSource.map { "Paused — \($0)" } ?? "Paused — Meeting"
        case .idle:
            return "Paused — Idle"
        case .manual:
            return "Paused"
        }
    }

    var currentPauseReason: PauseReason? {
        state == .paused ? pauseReason : nil
    }

    init(meetingDetector: MeetingDetector = MeetingDetector(), defaults: UserDefaults = .standard,
         startAutomatically: Bool = true, now: @escaping () -> Date = Date.init) {
        self.meetingDetector = meetingDetector
        self.defaults = defaults
        self.now = now
        // Register defaults
        defaults.register(defaults: [
            SettingsKey.workDurationMinutes: 20,
            SettingsKey.breakDurationSeconds: 20,
            SettingsKey.pauseDuringMeetings: true,
            SettingsKey.allowSkipBreak: true,
            SettingsKey.muteSounds: false,
            SettingsKey.pauseWhenIdle: true,
        ])
        // Start timer and ticker (ticker runs for app lifetime)
        remainingSeconds = workDurationSeconds
        state = .working
        guard startAutomatically else { return }
        startTicking()

        // Reset work timer on wake — sleep time isn't work time
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        })
        observeScreenLock()
    }

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in screenObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            screenObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if locked { self?.handleScreenLock() } else { self?.handleScreenUnlock() }
                }
            })
        }
        // Fast user switching also suspends the current work session.
        for (name, locked) in [(NSWorkspace.sessionDidResignActiveNotification, true),
                               (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if locked { self?.handleScreenLock() } else { self?.handleScreenUnlock() }
                }
            })
        }
    }

    func handleScreenLock() {
        screenIsLocked = true
    }

    func handleScreenUnlock() {
        guard screenIsLocked else { return }
        screenIsLocked = false
        if state == .onBreak {
            // Locking/sleeping is valid rest, but never substitutes for confirmation.
            refreshBreakCountdown()
            return
        }
        let manuallyPaused = state == .paused && pauseReason == .manual
        remainingSeconds = workDurationSeconds
        secondsBeforePause = workDurationSeconds
        if !manuallyPaused {
            state = .working
            checkMeetingStatus()
        }
    }

    private func handleWake() {
        switch state {
        case .working:
            remainingSeconds = workDurationSeconds
        case .onBreak:
            refreshBreakCountdown()
        case .paused:
            break
        }
    }

    func start() {
        guard state != .onBreak else { return }
        breakDeadline = nil
        remainingSeconds = workDurationSeconds
        state = .working
    }

    func pause() {
        guard state == .working else { return }
        secondsBeforePause = remainingSeconds
        state = .paused
        pauseReason = .manual
    }

    func resume() {
        guard state == .paused else { return }
        remainingSeconds = secondsBeforePause
        state = .working
        pauseReason = .manual
    }

    func skipBreak() {
        refreshBreakCountdown()
        guard state == .onBreak, !isAwaitingBreakConfirmation else { return }
        overlayManager.dismissOverlay()
        breakDeadline = nil
        remainingSeconds = workDurationSeconds
        state = .working
    }

    func confirmBreak() {
        guard isAwaitingBreakConfirmation, !screenIsLocked else { return }
        overlayManager.dismissWithAnimation()
        breakDeadline = nil
        remainingSeconds = workDurationSeconds
        state = .working
        checkMeetingStatus()
    }

    @discardableResult
    func handleBreakKey(_ keyCode: UInt16, isRepeat: Bool = false) -> Bool {
        guard state == .onBreak, !screenIsLocked, [36, 76, 53].contains(keyCode) else { return false }
        refreshBreakCountdown()
        // Holding a key through the deadline must not confirm automatically.
        guard !isRepeat else { return true }
        if isAwaitingBreakConfirmation {
            confirmBreak()
            return true
        }
        if keyCode == 53 && defaults.bool(forKey: SettingsKey.allowSkipBreak) {
            skipBreak()
            return true
        }
        return false
    }

    func refreshMeetingStatus() {
        refreshBreakCountdown()
        guard !screenIsLocked, !isAwaitingBreakConfirmation else { return }
        checkMeetingStatus()
    }

    func togglePause() {
        if state == .working {
            pause()
        } else if state == .paused && pauseReason != .meeting {
            resume()
        }
    }

    // MARK: - Private

    private func startTicking() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Break timer running"
        )

        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        tickCount += 1
        refreshBreakCountdown()
        // A finished break stays black until the explicit confirmation action.
        guard !isAwaitingBreakConfirmation else { return }
        if screenIsLocked {
            return
        }

        // Re-read capture activity every second so hanging up clears promptly.
        // Also release a meeting pause if the user disabled meeting detection.
        checkMeetingStatus()

        // Idle detection is less time-sensitive.
        if tickCount % 5 == 0 {
            if pauseWhenIdle { checkIdleStatus() }
        }

        switch state {
        case .paused:
            break

        case .working:
            remainingSeconds -= 1
            if remainingSeconds <= 0 {
                startBreak()
            }

        case .onBreak:
            break // Refreshed from the wall-clock deadline at the start of this tick.
        }
    }

    private func startBreak() {
        // Check for meeting immediately before showing break overlay
        if pauseDuringMeetings {
            meetingDetector.check()
            if meetingDetector.isInMeeting {
                secondsBeforePause = workDurationSeconds
                state = .paused
                pauseReason = .meeting
                return
            }
        }

        remainingSeconds = breakDurationSeconds
        breakDeadline = now().addingTimeInterval(TimeInterval(remainingSeconds))
        state = .onBreak
        overlayManager.showBreakOverlay(timerManager: self)
        if !muteSounds { NSSound(named: "Glass")?.play() }
    }

    private func endBreak() {
        guard remainingSeconds > 0 else { return }
        remainingSeconds = 0
        if !muteSounds { NSSound(named: "Blow")?.play() }
        // Keep the overlay and .onBreak state until confirmBreak().
    }

    private func refreshBreakCountdown() {
        guard state == .onBreak, !isAwaitingBreakConfirmation, let deadline = breakDeadline else { return }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now()))))
        if remaining == 0 { endBreak() } else { remainingSeconds = remaining }
    }

    private func checkMeetingStatus() {
        guard pauseDuringMeetings else {
            if state == .paused && pauseReason == .meeting { resume() }
            return
        }
        meetingDetector.check()

        if meetingDetector.isInMeeting {
            if state == .working {
                secondsBeforePause = remainingSeconds
                state = .paused
                pauseReason = .meeting
            } else if state == .onBreak {
                // If a meeting starts during a break, skip the break
                skipBreak()
                // The deadline may have elapsed while capture was being read.
                guard state == .working else { return }
                secondsBeforePause = remainingSeconds
                state = .paused
                pauseReason = .meeting
            }
        } else {
            if state == .paused && pauseReason == .meeting {
                // Meeting ended, resume
                resume()
            }
        }
    }

    #if TESTING
    func tickForTesting() { tick() }
    func wakeForTesting() { handleWake() }
    #endif

    // MARK: - Idle Detection

    #if DEBUG
    private let idleThreshold: TimeInterval = 30 // 30 seconds for testing
    #else
    private let idleThreshold: TimeInterval = 300 // 5 minutes
    #endif

    private func checkIdleStatus() {
        // kCGAnyInputEventType (~0) checks all input event types
        let idleTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)

        if idleTime >= idleThreshold && !hasActiveDisplaySleepAssertion() {
            if state == .working {
                secondsBeforePause = remainingSeconds
                state = .paused
                pauseReason = .idle
            }
        } else {
            if state == .paused && pauseReason == .idle {
                resumeFromIdle()
            }
        }
    }

    private func resumeFromIdle() {
        guard state == .paused && pauseReason == .idle else { return }

        // Check for active meeting before resuming to avoid a gap
        if pauseDuringMeetings {
            meetingDetector.check()
            if meetingDetector.isInMeeting {
                secondsBeforePause = workDurationSeconds
                pauseReason = .meeting
                return
            }
        }

        remainingSeconds = workDurationSeconds
        state = .working
    }

    private func hasActiveDisplaySleepAssertion() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let dict = assertions?.takeRetainedValue() as? [String: [[String: Any]]] else {
            return false
        }

        for (_, processAssertions) in dict {
            for assertion in processAssertions {
                if let type = assertion["AssertType"] as? String,
                   type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleep" {
                    return true
                }
            }
        }
        return false
    }

}

func formatTime(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
