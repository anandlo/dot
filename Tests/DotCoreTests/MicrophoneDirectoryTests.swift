import XCTest

@testable import DotCore

/// The microphone picker offers devices a person can name.
///
/// `AVCaptureDevice.DiscoverySession` returns every input, including the
/// aggregate CoreAudio builds to route audio between devices and the devices
/// that have no name of their own. Those are not choices a dictation app can
/// offer: a row titled `CADefaultDeviceAggregate-95480-0` says nothing about
/// what will be recorded. The decision lives in DotCore so it can be tested
/// here with descriptors — no microphone, audio engine or permission prompt.
final class MicrophoneDirectoryTests: XCTestCase {
    /// The three inputs the machine really has.
    private static let iPhone = MicrophoneDevice(
        uid: "9FDD3A26-1EB0-4DA5-AF72-DD6E00000003",
        name: "Anand’s iPhone 14 Pro Microphone"
    )
    private static let builtIn = MicrophoneDevice(
        uid: "BuiltInMicrophoneDevice",
        name: "MacBook Air Microphone"
    )
    private static let usb = MicrophoneDevice(
        uid: "AppleUSBAudioEngine:Microphone:0",
        name: "USB Microphone"
    )

    /// The aggregate macOS built for a process that has since exited. Its HAL
    /// name was absent, so the discovery session handed back the UID instead.
    private static let leakedUID = "CADefaultDeviceAggregate-95480-0"

    func testADeviceNamedByItsUIDIsDropped() {
        // The exact row the menu used to show: the platform's fallback name is
        // the UID, so the menu titled a device with an identifier.
        let aggregate = MicrophoneDevice(
            uid: Self.leakedUID,
            name: Self.leakedUID
        )
        XCTAssertEqual(
            MicrophoneDirectory.offered([Self.iPhone, aggregate, Self.builtIn]),
            [Self.iPhone, Self.builtIn]
        )
    }

    func testADeviceWithNoNameIsDropped() {
        // The same aggregate as the discovery session reports it here: no name
        // at all. A row with an empty title is not a choice either.
        let nameless = MicrophoneDevice(uid: Self.leakedUID, name: "")
        let blank = MicrophoneDevice(uid: "BuiltInSpeakerDevice", name: " \n\t ")
        XCTAssertEqual(MicrophoneDirectory.offered([nameless, blank]), [])
    }

    func testAnAggregateIsDroppedEvenWhenItHasAFriendlyName() {
        // A name filter would keep this one: "Dot Probe Aggregate" is readable.
        // The HAL is what says it is not a microphone, and the descriptor
        // carries that answer.
        let aggregate = MicrophoneDevice(
            uid: "CADefaultDeviceAggregate-95480-1",
            name: "Dot Probe Aggregate",
            isAggregate: true
        )
        XCTAssertEqual(MicrophoneDirectory.offered([aggregate]), [])
    }

    func testTheRealDevicesSurviveIntact() {
        let devices = [Self.iPhone, Self.builtIn, Self.usb]
        let offered = MicrophoneDirectory.offered(devices)
        XCTAssertEqual(offered, devices)
        XCTAssertEqual(
            offered.map(\.uid),
            [
                "9FDD3A26-1EB0-4DA5-AF72-DD6E00000003",
                "BuiltInMicrophoneDevice",
                "AppleUSBAudioEngine:Microphone:0",
            ]
        )
        XCTAssertEqual(
            offered.map(\.name),
            [
                "Anand’s iPhone 14 Pro Microphone",
                "MacBook Air Microphone",
                "USB Microphone",
            ]
        )
        XCTAssertTrue(offered.allSatisfy { !$0.isAggregate })
    }

    func testAConfiguredDeviceThatIsHiddenIsStillOffered() {
        // The choice may name a device that is unplugged, or one Dot has just
        // stopped offering. It keeps its value and gains a readable label; the
        // UID is never printed.
        let aggregate = MicrophoneDevice(uid: Self.leakedUID, name: Self.leakedUID)
        let options = MicrophoneDirectory.options(
            devices: [Self.iPhone, Self.builtIn, aggregate],
            configuredUID: Self.leakedUID
        )
        XCTAssertEqual(
            options.map(\.uid),
            [nil, Self.leakedUID, Self.iPhone.uid, Self.builtIn.uid]
        )
        XCTAssertEqual(options.map(\.name).first, "System default")
        XCTAssertEqual(options[1].name, "Unavailable device")
        XCTAssertEqual(options[1].uid, Self.leakedUID, "the value must stay the person's choice")
        XCTAssertFalse(options.contains { $0.name == Self.leakedUID })
    }

    func testAConfiguredDeviceThatIsHereIsNotRepeated() {
        let options = MicrophoneDirectory.options(
            devices: [Self.iPhone, Self.builtIn],
            configuredUID: Self.iPhone.uid
        )
        XCTAssertEqual(
            options,
            [
                MicrophoneOption(uid: nil, name: "System default"),
                MicrophoneOption(uid: Self.iPhone.uid, name: Self.iPhone.name),
                MicrophoneOption(uid: Self.builtIn.uid, name: Self.builtIn.name),
            ]
        )
        XCTAssertFalse(options.contains { $0.name == "Unavailable device" })
    }

    func testTheSystemDefaultIsAlwaysFirstEvenWithNoDevices() {
        XCTAssertEqual(
            MicrophoneDirectory.options(devices: [], configuredUID: nil),
            [MicrophoneOption(uid: nil, name: "System default")]
        )
    }

    func testTheSameDeviceIsOfferedOnce() {
        // The old catalog deduped by UID, and the rule keeps that: two
        // descriptors for one device are one row, and the first name wins.
        let duplicate = MicrophoneDevice(uid: Self.iPhone.uid, name: "Another name")
        XCTAssertEqual(
            MicrophoneDirectory.offered([Self.iPhone, duplicate]),
            [Self.iPhone]
        )
    }
}
