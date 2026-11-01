import AppKit
import Foundation

// Keep timer regressions deterministic: no device access, windows, or real clock.
class StubMeetingDetector: MeetingDetector {
    var capturing = false
    override func check() {
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

@MainActor
class OverlayManager {
    var dismissals = 0
    func showBreakOverlay(timerManager: TimerManager) {}
    func dismissOverlay() { dismissals += 1 }
    func dismissWithAnimation() {}
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
        }

        let suite = "ReposeMeetingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKey.pauseWhenIdle)
        defaults.set(true, forKey: SettingsKey.muteSounds)
        defaults.set(1, forKey: SettingsKey.workDurationMinutes)
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
    }
}
