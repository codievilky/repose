import Foundation
import Combine
import AppKit
import CoreMediaIO
import CoreAudio

struct AudioInputCapture {
    let name: String
    let devices: [AudioDeviceID]
}

class MeetingDetector: ObservableObject {
    @Published var isInMeeting: Bool = false
    @Published var meetingSource: String? = nil
    private var microphoneSource: String?
    private var cameraSource: String?

    func check() {
        microphoneSource = nil
        cameraSource = nil
        let cameraActive = checkCamera()
        let micActive = checkMicrophone()

        if cameraActive {
            isInMeeting = true
            meetingSource = cameraSource.map { "Camera in use — \($0)" } ?? "Camera in use"
        } else if micActive {
            isInMeeting = true
            meetingSource = microphoneSource.map { "Microphone in use — \($0)" } ?? "Microphone in use"
        } else {
            isInMeeting = false
            meetingSource = nil
        }
    }

    // MARK: - Camera Detection via CoreMediaIO

    func checkCamera() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var result = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )

        guard result == kCMIOHardwareNoError, dataSize > 0 else { return false }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: deviceCount)
        var dataUsed: UInt32 = 0

        result = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress,
            0, nil,
            dataSize,
            &dataUsed,
            &devices
        )

        guard result == kCMIOHardwareNoError else { return false }

        for device in devices {
            if isDeviceRunning(device) {
                cameraSource = cameraName(device)
                return true
            }
        }

        return false
    }

    private func cameraName(_ device: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil,
            UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &name)
        guard status == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func isDeviceRunning(_ deviceID: CMIODeviceID) -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var isRunning: UInt32 = 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        var dataUsed: UInt32 = 0

        let result = CMIOObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            dataSize,
            &dataUsed,
            &isRunning
        )

        guard result == kCMIOHardwareNoError else { return false }
        return isRunning != 0
    }

    // MARK: - Microphone Detection via CoreAudio

    private func checkMicrophone() -> Bool {
        // DeviceIsRunningSomewhere is device-wide: speaker playback on a
        // duplex headset can keep it true after a FaceTime call has ended.
        // Process input activity distinguishes capture from playback.
        if #available(macOS 14.2, *), let capturing = checkProcessInputs() {
            return capturing
        }

        // Older macOS releases do not expose audio process objects.
        return checkLegacyMicrophone()
    }

    @available(macOS 14.2, *)
    func checkProcessInputs() -> Bool? {
        guard let captures = activeAudioInputs() else { return nil }
        for capture in captures where capture.devices.contains(where: isMicrophoneDevice) {
            microphoneSource = capture.name
            return true
        }
        return false
    }

    @available(macOS 14.2, *)
    func activeAudioInputs() -> [AudioInputCapture]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Only fall back to the device heuristic when the API is unavailable.
        guard AudioObjectHasProperty(system, &address) else { return nil }
        guard let processes = audioObjects(system, address: &address) else { return [] }

        var captures: [AudioInputCapture] = []
        for process in processes {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let result = AudioObjectGetPropertyData(process, &inputAddress, 0, nil, &size, &running)
            // A process may disappear between enumeration and reading it.
            guard result == noErr && running != 0 else { continue }
            var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            let devices = audioObjects(process, address: &devicesAddress) ?? []
            let pid = number(process, selector: kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) }
            let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
                ?? string(process, selector: kAudioProcessPropertyBundleID) ?? "Audio input"
            captures.append(AudioInputCapture(name: name, devices: devices))
        }
        return captures
    }

    func isMicrophoneDevice(_ device: AudioDeviceID) -> Bool {
        isMicrophoneDevice(device, visited: [])
    }

    private func isMicrophoneDevice(_ device: AudioDeviceID, visited: Set<AudioDeviceID>) -> Bool {
        guard !visited.contains(device), visited.count < 32, isInputDevice(device),
              let transport = number(device, selector: kAudioDevicePropertyTransportType) else { return false }
        if transport == kAudioDeviceTransportTypeVirtual { return false }
        if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate {
            var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let children = audioObjects(device, address: &address) ?? []
            return children.contains { isMicrophoneDevice($0, visited: visited.union([device])) }
        }
        // System-audio taps and loopback capture are not microphone input.
        return true
    }

    private func number(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func audioObjects(_ object: AudioObjectID, address: inout AudioObjectPropertyAddress) -> [AudioObjectID]? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let result = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return nil }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    func checkLegacyMicrophone() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )

        guard result == kAudioHardwareNoError, dataSize > 0 else { return false }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)

        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &devices
        )

        guard result == kAudioHardwareNoError else { return false }

        for device in devices {
            if isInputDevice(device) && isAudioDeviceRunning(device) {
                return true
            }
        }

        return false
    }

    private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func isAudioDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let result = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &isRunning
        )

        guard result == kAudioHardwareNoError else { return false }
        return isRunning != 0
    }
}
