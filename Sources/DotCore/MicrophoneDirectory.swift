import Foundation

/// One input device as the platform hands it over, before Dot decides which
/// devices a person may pick.
///
/// `AVCaptureDevice` knows that a device has an id and a name, but not what the
/// device is. A device macOS builds to route audio between other devices is an
/// input too, and it reaches the same discovery session as a microphone. The
/// HAL knows the difference; that answer travels here in ``isAggregate`` so the
/// decision stays pure and can be tested without a microphone.
public struct MicrophoneDevice: Equatable, Sendable {
    /// The stable CoreAudio UID, which is what the configuration stores.
    public let uid: String
    /// The name the platform reports. It may be empty, or the UID repeated
    /// because the device has no name of its own.
    public let name: String
    /// Whether CoreAudio reports the device as an aggregate: a routing graph
    /// made of other devices, not a microphone.
    public let isAggregate: Bool

    /// Creates a descriptor.
    public init(uid: String, name: String, isAggregate: Bool = false) {
        self.uid = uid
        self.name = name
        self.isAggregate = isAggregate
    }
}

/// A row the microphone picker can offer.
public struct MicrophoneOption: Equatable, Sendable {
    /// The value the row selects; `nil` is the system default.
    public let uid: String?
    /// The words a person reads. Never a UID.
    public let name: String

    /// Creates an option.
    public init(uid: String?, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// The rule that decides which inputs the microphone picker offers.
///
/// It is a pure function over descriptors, so the question can be tested
/// without a microphone, an audio engine or a permission prompt.
public enum MicrophoneDirectory {
    /// The row that hands the choice back to the system.
    public static let systemDefaultName = "System Default"

    /// The row for a configured device Dot cannot offer right now.
    ///
    /// The row keeps the UID as its value, so opening the picker and closing it
    /// again cannot change the choice; only the label is a placeholder. A UID
    /// is an identifier for the system, not a name for a person.
    public static let unavailableName = "Unavailable device"

    /// The devices that can be offered, in the order the system reported them.
    ///
    /// A device is dropped when it has nothing a person can read — no name, or
    /// only its UID — and when CoreAudio says it is an aggregate. A menu row
    /// has to say what the device is; a UID says only which device it is, and
    /// only to the system.
    public static func offered(_ devices: [MicrophoneDevice]) -> [MicrophoneDevice] {
        var seen = Set<String>()
        var offered: [MicrophoneDevice] = []
        for device in devices {
            let uid = device.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, !device.isAggregate else { continue }
            guard let name = readableName(of: device) else { continue }
            guard seen.insert(uid).inserted else { continue }
            offered.append(MicrophoneDevice(uid: uid, name: name, isAggregate: false))
        }
        return offered
    }

    /// The name of a device, or `nil` when it has none a person can read.
    ///
    /// macOS falls back to the UID when a device has no name of its own, so a
    /// name equal to the UID is the same as no name. The comparison ignores
    /// case and surrounding whitespace: the platform's capitalisation of a UID
    /// is not a promise.
    static func readableName(of device: MicrophoneDevice) -> String? {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let uid = device.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.caseInsensitiveCompare(uid) != .orderedSame else { return nil }
        return name
    }

    /// Every row the picker shows: the system default, the configured device
    /// even when it cannot be offered, then the devices that are here now.
    ///
    /// The configured device is never removed. A microphone that was chosen
    /// deliberately and is now unplugged — or one Dot no longer offers, such as
    /// an aggregate — keeps its row and its value, labelled
    /// ``unavailableName`` instead of the UID it stores. Changing the choice
    /// takes the person, not a menu refresh.
    public static func options(
        devices: [MicrophoneDevice],
        configuredUID: String?
    ) -> [MicrophoneOption] {
        let available = offered(devices)
        var options = [MicrophoneOption(uid: nil, name: systemDefaultName)]
        let configured = configuredUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured,
           !configured.isEmpty,
           !available.contains(where: { $0.uid == configured }) {
            options.append(MicrophoneOption(uid: configured, name: unavailableName))
        }
        options.append(contentsOf: available.map {
            MicrophoneOption(uid: $0.uid, name: $0.name)
        })
        return options
    }
}
