import AppKit
import Foundation
import CoreAudio

// Keep timer regressions deterministic: no device access, windows, or real clock.
class StubMeetingDetector: MeetingDetector {
    var capturing = false
    var onCheck: (() -> Void)?
    override func check() {
        onCheck?()
        isInMeeting = capturing
        meetingSource = capturing ? "Microphone in use" : nil
    }
}

@available(macOS 14.2, *)
class DuplexHeadsetDetector: MeetingDetector {
    var cameraRunning = false
    var inputRunning: Bool? = false
    override func checkCamera() -> Bool { cameraRunning }
    override func checkProcessInputs() -> Bool? { inputRunning }
    // The headset's device stays running while it plays sound after hangup.
    override func checkLegacyMicrophone() -> Bool { true }
}

@available(macOS 14.2, *)
class CaptureDeviceDetector: MeetingDetector {
    var captures: [AudioInputCapture] = []
    var cameraRunning = false
    override func checkCamera() -> Bool { cameraRunning }
    override func activeAudioInputs() -> [AudioInputCapture]? { captures }
    override func isMicrophoneDevice(_ device: AudioDeviceID) -> Bool { device == 1 }
}

@MainActor
class OverlayManager {
    var dismissals = 0
    var confirmations = 0
    func showBreakOverlay(timerManager: TimerManager) {}
    func dismissOverlay() { dismissals += 1 }
    func dismissWithAnimation() { confirmations += 1 }
}

@main
struct MeetingRegressionTests {
    @MainActor
    static func main() {
        if #available(macOS 14.2, *) {
            let headset = DuplexHeadsetDetector()
            headset.check()
            precondition(!headset.isInMeeting)
            print("PASS: headset playback without capture does not count as a meeting")
            headset.inputRunning = true
            headset.check()
            precondition(headset.isInMeeting)
            headset.inputRunning = false
            headset.check()
            precondition(!headset.isInMeeting)
            print("PASS: stopping capture clears Meeting even if the device stays running")
            headset.cameraRunning = true
            headset.check()
            precondition(headset.isInMeeting)
            print("PASS: camera-only meetings still pause the timer")
            headset.cameraRunning = false
            headset.inputRunning = nil
            headset.check()
            precondition(headset.isInMeeting)
            print("PASS: unsupported process detection uses the legacy fallback")

            let devices = CaptureDeviceDetector()
            devices.captures = [AudioInputCapture(name: "Screen Sharing", devices: [])]
            devices.check()
            precondition(!devices.isInMeeting)
            devices.captures = [AudioInputCapture(name: "System Audio Capture", devices: [2])]
            devices.check()
            precondition(!devices.isInMeeting)
            print("PASS: system-audio capture without a physical microphone is not a meeting")
            let codex = AudioInputCapture(name: "com.openai.codex.helper", devices: [1],
                                          bundleID: "com.openai.codex.helper")
            for bundleID in ["com.openai.codex", "com.openai.codex.helper", "com.openai.codex.helper.renderer"] {
                devices.captures = [AudioInputCapture(name: "Voice input", devices: [1], bundleID: bundleID)]
                devices.check()
                precondition(!devices.isInMeeting && devices.meetingSource == nil)
            }
            print("PASS: Codex voice input on a physical microphone does not count as a meeting")
            devices.captures = [codex, AudioInputCapture(name: "FaceTime", devices: [1], bundleID: "com.apple.FaceTime")]
            devices.check()
            precondition(devices.isInMeeting && devices.meetingSource == "Microphone in use — FaceTime")
            print("PASS: an actual call still pauses and names its source while Codex is recording")
            devices.captures = [codex]
            devices.check()
            precondition(!devices.isInMeeting && devices.meetingSource == nil)
            print("PASS: hanging up clears the meeting even if Codex keeps the microphone running")
            devices.cameraRunning = true
            devices.check()
            precondition(devices.isInMeeting && devices.meetingSource == "Camera in use")
            devices.cameraRunning = false
            print("PASS: camera activity still pauses while Codex microphone input is ignored")
            for bundleID: String? in [nil, "us.zoom.xos", "com.tencent.xinWeChat", "com.openai.codex-other"] {
                devices.captures = [AudioInputCapture(name: "Codex", devices: [1], bundleID: bundleID)]
                devices.check()
                precondition(devices.isInMeeting && devices.meetingSource == "Microphone in use — Codex")
            }
            print("PASS: other microphone apps are detected by identity, regardless of their display name")
            devices.captures = []
            devices.check()
            precondition(!devices.isInMeeting && devices.meetingSource == nil)
            print("PASS: capture sources clear when recording stops")

            let browser = AudioInputCapture(name: "Edge voice input", devices: [1], bundleID: "com.microsoft.edgemac.helper")
            for bundleID in ["com.microsoft.edgemac.helper", "com.google.Chrome.helper", "com.apple.Safari",
                             "com.apple.WebKit.GPU", "org.mozilla.firefox"] {
                devices.captures = [AudioInputCapture(name: "ChatGPT voice", devices: [1], bundleID: bundleID)]
                devices.check()
                precondition(!devices.isInMeeting && devices.meetingSource == nil)
            }
            print("PASS: browser microphone input does not count as a meeting by default")
            devices.includeBrowserMicrophones = true
            devices.captures = [codex, browser]
            devices.check()
            precondition(devices.isInMeeting && devices.meetingSource == "Microphone in use — Edge voice input")
            devices.captures = [codex]
            devices.check()
            precondition(!devices.isInMeeting)
            print("PASS: opting into browser microphones detects web calls while still excluding Codex")
            devices.includeBrowserMicrophones = false
            devices.captures = [browser, AudioInputCapture(name: "FaceTime", devices: [1], bundleID: "com.apple.FaceTime")]
            devices.check()
            precondition(devices.isInMeeting && devices.meetingSource == "Microphone in use — FaceTime")
            devices.captures = [browser]
            devices.check()
            precondition(!devices.isInMeeting && devices.meetingSource == nil)
            print("PASS: a native call pauses and clears correctly while browser voice input continues")
            devices.cameraRunning = true
            devices.check()
            precondition(devices.isInMeeting && devices.meetingSource == "Camera in use")
            devices.cameraRunning = false
            print("PASS: browser video calls with an active camera still pause automatically")
            devices.captures = [AudioInputCapture(name: "Edge", devices: [1], bundleID: "com.microsoft.edgemac-other")]
            devices.check()
            precondition(devices.isInMeeting)
            print("PASS: browser exclusions respect bundle identity boundaries")
        }

        let suite = "ReposeMeetingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKey.pauseWhenIdle)
        defaults.set(true, forKey: SettingsKey.muteSounds)
        defaults.set(1, forKey: SettingsKey.workDurationMinutes)
        if #available(macOS 14.2, *) {
            let inputs = CaptureDeviceDetector()
            let codex = AudioInputCapture(name: "Codex voice input", devices: [1], bundleID: "com.openai.codex.helper")
            inputs.captures = [codex]
            let inputTimer = TimerManager(meetingDetector: inputs, defaults: defaults, startAutomatically: false)
            inputTimer.tickForTesting()
            precondition(inputTimer.state == .working && inputTimer.remainingSeconds == 59)
            inputs.captures.append(AudioInputCapture(name: "FaceTime", devices: [1], bundleID: "com.apple.FaceTime"))
            inputTimer.tickForTesting()
            precondition(inputTimer.currentPauseReason == .meeting && inputTimer.remainingSeconds == 59)
            inputs.captures = [codex]
            inputTimer.tickForTesting()
            precondition(inputTimer.state == .working && inputTimer.remainingSeconds == 58)
            print("PASS: the timer runs with Codex input, pauses for a call, and resumes with Codex still recording")

            inputs.captures = [AudioInputCapture(name: "Edge voice input", devices: [1], bundleID: "com.microsoft.edgemac.helper")]
            inputTimer.tickForTesting()
            precondition(inputTimer.state == .working && inputTimer.remainingSeconds == 57)
            defaults.set(true, forKey: SettingsKey.includeBrowserMicrophones)
            inputTimer.refreshMeetingStatus()
            precondition(inputTimer.currentPauseReason == .meeting && inputTimer.remainingSeconds == 57)
            defaults.set(false, forKey: SettingsKey.includeBrowserMicrophones)
            inputTimer.refreshMeetingStatus()
            precondition(inputTimer.state == .working && inputTimer.remainingSeconds == 57)
            inputTimer.tickForTesting()
            precondition(inputTimer.remainingSeconds == 56)
            print("PASS: enabling browser microphones pauses immediately; disabling them resumes the countdown")
            inputTimer.pause()
            defaults.set(true, forKey: SettingsKey.includeBrowserMicrophones)
            inputTimer.refreshMeetingStatus()
            defaults.set(false, forKey: SettingsKey.includeBrowserMicrophones)
            inputTimer.refreshMeetingStatus()
            precondition(inputTimer.currentPauseReason == .manual && inputTimer.remainingSeconds == 56)
            print("PASS: changing browser detection never overrides a manual pause")
        }
        let detector = StubMeetingDetector()
        let timer = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false)

        // Hanging up must release the meeting pause on the next tick, preserving time.
        timer.tickForTesting()
        let beforeCall = timer.remainingSeconds
        detector.capturing = true
        timer.tickForTesting()
        precondition(timer.state == .paused && timer.currentPauseReason == .meeting)
        precondition(timer.remainingSeconds == beforeCall)
        detector.capturing = false
        timer.tickForTesting()
        precondition(timer.state == .working && timer.remainingSeconds == beforeCall - 1)
        print("PASS: call end resumes on next tick, retaining the work countdown")

        // Output activity is represented by no capture; a running call app alone
        // must not keep the timer paused after capture stops.
        for _ in 0..<3 { timer.tickForTesting() }
        precondition(timer.state == .working)
        print("PASS: no capture keeps the work timer running")

        // Turning off the setting during a call used to leave Meeting stuck forever.
        detector.capturing = true
        timer.tickForTesting()
        precondition(timer.currentPauseReason == .meeting)
        defaults.set(false, forKey: SettingsKey.pauseDuringMeetings)
        timer.tickForTesting()
        precondition(timer.state == .working)
        print("PASS: disabling meeting detection releases an existing meeting pause")

        // Automatic recovery must never override an intentional manual pause.
        defaults.set(true, forKey: SettingsKey.pauseDuringMeetings)
        timer.pause()
        timer.tickForTesting()
        detector.capturing = false
        timer.tickForTesting()
        precondition(timer.currentPauseReason == .manual)
        defaults.set(false, forKey: SettingsKey.pauseDuringMeetings)
        timer.tickForTesting()
        precondition(timer.currentPauseReason == .manual)
        print("PASS: manual pause survives meeting start/end and disabling detection")

        // A call beginning during a break must still dismiss the overlay safely.
        timer.resume()
        timer.start()
        defaults.set(true, forKey: SettingsKey.pauseDuringMeetings)
        for _ in 0..<60 { timer.tickForTesting() }
        precondition(timer.state == .onBreak)
        detector.capturing = true
        timer.tickForTesting()
        precondition(timer.currentPauseReason == .meeting && timer.overlayManager.dismissals == 1)
        detector.capturing = false
        timer.tickForTesting()
        precondition(timer.state == .working)
        print("PASS: calls during breaks dismiss the overlay and recover after hangup")

        // Screen locking does not require sleep or a five-minute idle interval.
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let locks = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<10 { locks.tickForTesting() }
        precondition(locks.remainingSeconds == 50)
        locks.handleScreenLock()
        for _ in 0..<5 { locks.tickForTesting() }
        precondition(locks.remainingSeconds == 50)
        locks.handleScreenUnlock()
        precondition(locks.state == .working && locks.remainingSeconds == 60)
        locks.tickForTesting()
        locks.handleScreenUnlock()
        precondition(locks.remainingSeconds == 59)
        print("PASS: lock freezes work; unlock resets it exactly once")

        locks.pause()
        locks.handleScreenLock()
        locks.handleScreenUnlock()
        precondition(locks.currentPauseReason == .manual && locks.remainingSeconds == 60)
        print("PASS: unlocking preserves an intentional manual pause")
        locks.resume()
        detector.capturing = true
        locks.tickForTesting()
        locks.handleScreenLock()
        detector.capturing = false
        locks.handleScreenUnlock()
        precondition(locks.state == .working && locks.remainingSeconds == 60)
        print("PASS: unlock clears a stale meeting pause and starts a full interval")

        // Completed breaks keep their overlay until an explicit confirmation.
        let rest = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<60 { rest.tickForTesting() }
        rest.confirmBreak()
        precondition(rest.state == .onBreak && !rest.isAwaitingBreakConfirmation)
        clock.addTimeInterval(TimeInterval(rest.breakDurationSeconds + 5))
        rest.tickForTesting()
        precondition(rest.isAwaitingBreakConfirmation && rest.remainingSeconds == 0)
        for _ in 0..<60 { rest.tickForTesting() }
        precondition(rest.isAwaitingBreakConfirmation && rest.remainingSeconds == 0)
        precondition(rest.overlayManager.dismissals == 0 && rest.overlayManager.confirmations == 0)
        print("PASS: a completed break stays black at zero without auto-restarting")

        rest.skipBreak()
        rest.start()
        rest.wakeForTesting()
        rest.refreshMeetingStatus()
        precondition(rest.isAwaitingBreakConfirmation && rest.overlayManager.dismissals == 0)
        print("PASS: skip, restart, wake and menu refresh cannot bypass confirmation")
        rest.confirmBreak()
        precondition(rest.state == .working && rest.remainingSeconds == 60)
        precondition(rest.overlayManager.confirmations == 1)
        rest.confirmBreak()
        precondition(rest.overlayManager.confirmations == 1)
        print("PASS: confirmation starts one full work interval exactly once")

        let lockedRest = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<60 { lockedRest.tickForTesting() }
        lockedRest.handleScreenLock()
        clock.addTimeInterval(TimeInterval(lockedRest.breakDurationSeconds + 5))
        lockedRest.wakeForTesting()
        lockedRest.confirmBreak()
        precondition(lockedRest.isAwaitingBreakConfirmation && lockedRest.overlayManager.confirmations == 0)
        lockedRest.handleScreenUnlock()
        precondition(lockedRest.isAwaitingBreakConfirmation)
        lockedRest.confirmBreak()
        precondition(lockedRest.state == .working && lockedRest.remainingSeconds == 60)
        print("PASS: rest during lock/sleep counts, and still requires confirmation after unlock")

        let interrupted = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<60 { interrupted.tickForTesting() }
        clock.addTimeInterval(TimeInterval(interrupted.breakDurationSeconds))
        detector.capturing = true
        interrupted.tickForTesting()
        precondition(interrupted.isAwaitingBreakConfirmation && interrupted.overlayManager.dismissals == 0)
        interrupted.refreshMeetingStatus()
        precondition(interrupted.isAwaitingBreakConfirmation)
        interrupted.confirmBreak()
        precondition(interrupted.currentPauseReason == .meeting)
        detector.capturing = false
        interrupted.tickForTesting()
        precondition(interrupted.state == .working)
        print("PASS: capture starting at the break deadline cannot dismiss the confirmation screen")

        let racing = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<60 { racing.tickForTesting() }
        clock.addTimeInterval(TimeInterval(racing.breakDurationSeconds) - 0.1)
        detector.capturing = true
        detector.onCheck = {
            clock.addTimeInterval(0.2)
            detector.onCheck = nil
        }
        racing.tickForTesting()
        precondition(racing.isAwaitingBreakConfirmation && racing.overlayManager.dismissals == 0)
        detector.capturing = false
        print("PASS: crossing the deadline during capture detection still requires confirmation")

        defaults.set(false, forKey: SettingsKey.allowSkipBreak)
        for key: UInt16 in [36, 76, 53] {
            let keyboard = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
            for _ in 0..<60 { keyboard.tickForTesting() }
            clock.addTimeInterval(TimeInterval(keyboard.breakDurationSeconds))
            // Refreshing the deadline is part of key handling, even before the next tick.
            precondition(keyboard.handleBreakKey(key))
            precondition(keyboard.state == .working && keyboard.remainingSeconds == 60)
            precondition(keyboard.overlayManager.confirmations == 1)
        }
        print("PASS: Return, keypad Enter and Esc confirm completed breaks with early skipping disabled")

        let early = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<60 { early.tickForTesting() }
        precondition(!early.handleBreakKey(36) && !early.handleBreakKey(53))
        precondition(early.state == .onBreak && !early.isAwaitingBreakConfirmation)
        defaults.set(true, forKey: SettingsKey.allowSkipBreak)
        precondition(early.handleBreakKey(53) && early.state == .working)
        precondition(early.overlayManager.dismissals == 1 && early.overlayManager.confirmations == 0)
        print("PASS: Esc before the deadline respects the Allow Skip Break setting")

        defaults.set(false, forKey: SettingsKey.allowSkipBreak)
        let held = TimerManager(meetingDetector: detector, defaults: defaults, startAutomatically: false, now: { clock })
        for _ in 0..<60 { held.tickForTesting() }
        clock.addTimeInterval(TimeInterval(held.breakDurationSeconds))
        precondition(held.handleBreakKey(53, isRepeat: true))
        precondition(held.isAwaitingBreakConfirmation && held.overlayManager.confirmations == 0)
        held.handleScreenLock()
        precondition(!held.handleBreakKey(53) && held.isAwaitingBreakConfirmation)
        held.handleScreenUnlock()
        precondition(held.handleBreakKey(53) && held.overlayManager.confirmations == 1)
        print("PASS: held keys and locked-screen keys cannot confirm automatically; a fresh press can")
    }
}
