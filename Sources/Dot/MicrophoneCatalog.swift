import AVFoundation
import CoreAudio
import DotCore

/// The microphones the menu can switch to.
enum MicrophoneCatalog {
    /// Every input device the system knows about, annotated with the one fact
    /// `AVCaptureDevice` cannot supply: whether CoreAudio built it as an
    /// aggregate.
    ///
    /// The list is read when the menu opens, so a headset that was plugged in
    /// after launch shows up without restarting Dot.
    static func devices() -> [MicrophoneDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let aggregates = CoreAudioInput.aggregateUIDs()
        return session.devices.map { device in
            MicrophoneDevice(
                uid: device.uniqueID,
                name: device.localizedName,
                isAggregate: aggregates.contains(device.uniqueID)
            )
        }
    }

    /// The UID of the microphone a recording would use right now.
    ///
    /// A configured device is used as it is. The system default is resolved to
    /// the device the HAL says would record, because a calibration belongs to
    /// the microphone that produced the take and "system default" is a choice,
    /// not a device. A HAL that cannot answer leaves the UID unknown, and an
    /// unknown UID simply means nothing is learned or applied for that take.
    ///
    /// - Parameter configured: the device the configuration names, or `nil`.
    static func recordingDeviceUID(configured: String?) -> String? {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return CoreAudioInput.defaultInputUID()
    }

    /// The inputs a person can pick.
    static func microphones() -> [MenuMicrophone] {
        MicrophoneDirectory.offered(devices()).map {
            MenuMicrophone(id: $0.uid, name: $0.name)
        }
    }
}

/// What the HAL says about an input that `AVCaptureDevice` reports.
///
/// A discovery session cannot tell a microphone from an aggregate that
/// CoreAudio built to route audio between devices. The HAL can: an aggregate is
/// an `AudioAggregateDevice` (`kAudioAggregateDeviceClassID`) rather than an
/// `AudioDevice`, and it carries the aggregate transport. The UID is the bridge
/// between the two.
private enum CoreAudioInput {
    /// The UIDs of the devices the HAL reports as aggregates.
    ///
    /// The aggregate `AVAudioEngine` creates is named
    /// `CADefaultDeviceAggregate-<pid>-0`. It is a routing graph, not an input a
    /// person speaks into, and when the HAL gives it no name its UID is all the
    /// discovery session has left to show.
    ///
    /// This hides a user-made aggregate from Audio MIDI Setup as well. A
    /// dictation input is a microphone, not a routing graph, and an aggregate
    /// that was chosen in the picker is still offered as
    /// ``MicrophoneDirectory/unavailableName`` — so the trade-off is visible,
    /// never silent.
    static func aggregateUIDs() -> Set<String> {
        var uids = Set<String>()
        for device in deviceIDs() where isAggregate(device) {
            guard let uid = string(device, kAudioDevicePropertyDeviceUID) else { continue }
            uids.insert(uid)
        }
        return uids
    }

    /// The UID of the input the system would record from, or `nil`.
    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != 0 else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    /// The devices the HAL lists right now.
    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    /// Whether one HAL device is an aggregate.
    ///
    /// The class is the fact: an aggregate carries
    /// `kAudioAggregateDeviceClassID`. The transport is checked as well, for a
    /// device that reports the aggregate transport without the aggregate class.
    /// Both are read from the HAL; no name, UID prefix or UID shape is guessed
    /// at. Nothing else is dropped here — a device that the HAL does not list
    /// is left to the name rule, so a real input is never hidden because the
    /// HAL could not answer.
    private static func isAggregate(_ device: AudioDeviceID) -> Bool {
        if let objectClass = value(device, kAudioObjectPropertyClass),
           objectClass == kAudioAggregateDeviceClassID {
            return true
        }
        guard let transport = value(device, kAudioDevicePropertyTransportType) else {
            return false
        }
        return transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }

    /// Reads a `UInt32` property.
    private static func value(
        _ device: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    /// Reads a `CFString` property.
    private static func string(
        _ device: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
