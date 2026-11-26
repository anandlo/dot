import AVFoundation
import CoreAudio
import DotCore

/// The microphones the menu can switch to.
enum MicrophoneCatalog {
    /// Posted once, on the main thread, when the first load of the cache finishes.
    ///
    /// The menu and the settings window are both on screen by then: they read the
    /// cache at launch, while it is still empty, and this is what asks them to
    /// read it again.
    static let didLoadNotification = Notification.Name("dot.microphone.catalog.loaded")

    /// The cache the app reads.
    ///
    /// It is replaceable so a test can install a cache whose first load is slow
    /// and prove the readers do not wait for it. The app installs the live cache
    /// once and never replaces it.
    static var cache: CatalogCache {
        get { installed.value }
        set { installed.install(newValue) }
    }

    private static let installed = InstalledCache()

    /// The device list and the default input as far as they are known right now.
    ///
    /// It never waits. Before the first load finishes it is
    /// ``CatalogCache/Snapshot/loading``: no devices and no default input, which
    /// the picker already draws as the system default row alone.
    static func snapshot() -> CatalogCache.Snapshot {
        cache.snapshot()
    }

    /// Waits for the first load of the cache.
    ///
    /// Only for a caller that is not the main thread. The press is the one that
    /// uses it, because opening a microphone for a device the cache has not
    /// listed yet would refuse a device that is there.
    ///
    /// - Parameter timeout: how long to wait, in seconds.
    /// - Returns: the filled snapshot, or `nil` when the timeout expired.
    static func awaitSnapshot(timeout: TimeInterval) -> CatalogCache.Snapshot? {
        cache.awaitSnapshot(timeout: timeout)
    }

    /// Every input device the system knows about, annotated with the one fact
    /// `AVCaptureDevice` cannot supply: whether CoreAudio built it as an
    /// aggregate.
    ///
    /// The answer comes from ``CatalogCache``: enumerating the machine's audio
    /// devices is a HAL round trip, and neither a menu refresh nor the press that
    /// starts a recording may pay one. The cache is filled once and re-read
    /// whenever the system reports a device or the default input changed, so a
    /// headset plugged in after launch still shows up.
    static func devices() -> [MicrophoneDevice] {
        snapshot().devices
    }

    /// Whether the system lists the input `uid` right now.
    ///
    /// It is the same list ``devices()`` offers, read from the same cache, so a
    /// configured device is accepted exactly when the picker would show it.
    static func isConnected(_ uid: String) -> Bool {
        snapshot().devices.contains { $0.uid == uid }
    }

    /// The UID of the microphone a recording would use right now.
    ///
    /// A configured device is used as it is. The system default is resolved to
    /// the device the HAL says would record, because a calibration belongs to the
    /// microphone that produced the take and "system default" is a choice, not a
    /// device. The HAL is read by the cache, not here: the value is the one the
    /// default-input listener last reported, and it is `nil` until the first load
    /// finishes, which only means nothing is learned or applied for that take.
    ///
    /// - Parameter configured: the device the configuration names, or `nil`.
    static func recordingDeviceUID(configured: String?) -> String? {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return snapshot().defaultInputUID
    }

    /// Starts filling the device cache.
    ///
    /// Called at launch. The enumeration runs on the catalog's own queue, so the
    /// first press and the first menu refresh read a cache that is already being
    /// filled instead of running a discovery session themselves.
    static func warm() {
        cache.begin()
    }

    /// The inputs a person can pick.
    static func microphones() -> [MenuMicrophone] {
        MicrophoneDirectory.offered(devices()).map {
            MenuMicrophone(id: $0.uid, name: $0.name)
        }
    }

    /// Holds the cache the app reads, so a test can put another one in its place.
    private final class InstalledCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CatalogCache

        init() {
            stored = CatalogCache()
        }

        var value: CatalogCache {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func install(_ cache: CatalogCache) {
            lock.lock()
            stored = cache
            lock.unlock()
        }
    }
}

/// The device list and the default input, read once and refreshed off the main
/// thread.
///
/// A discovery session and the HAL reads behind it are synchronous questions to
/// the audio server. Both were asked on the main thread, on the press that
/// starts a recording and on every menu refresh. Here they are asked on a
/// private queue instead, and a reader never blocks on them: ``snapshot()`` gives
/// the last known answer in place, and only a caller off the main thread may wait
/// for the first one with ``awaitSnapshot(timeout:)``.
final class CatalogCache: @unchecked Sendable {
    /// One answer: the inputs the system lists and the one that would record.
    struct Snapshot: Sendable, Equatable {
        var devices: [MicrophoneDevice] = []
        var defaultInputUID: String?
        /// Whether the first load has finished.
        var isLoaded = true

        /// What a cache answers before its first load finishes.
        static let loading = Snapshot(devices: [], defaultInputUID: nil, isLoaded: false)
    }

    static let shared = CatalogCache()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.anandlo.dot.microphone-catalog", qos: .userInitiated)
    /// Signalled when a load finishes, so a caller off the main thread can wait.
    private let ready = NSCondition()
    /// The question itself, injectable so a test can make it slow.
    private let discovery: @Sendable () -> Snapshot
    private var cached: Snapshot?
    private var announced = false
    private var observing = false
    private var observers: [NSObjectProtocol] = []
    private var readOnMainThread = true
    private var reads = 0

    /// Creates a cache. The first load starts here, on the cache's own queue.
    ///
    /// - Parameter discovery: makes the snapshot. The live cache enumerates the
    ///   machine; a test supplies one that takes as long as an audio server that
    ///   is busy.
    init(discovery: @escaping @Sendable () -> Snapshot = { CatalogCache.read() }) {
        self.discovery = discovery
        begin()
    }

    /// The last known snapshot. It never waits, on any thread.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return cached ?? .loading
    }

    /// Waits for the first load of the cache.
    ///
    /// It blocks the caller, which is why the main thread never calls it: a menu,
    /// a key press and a settings read all go through ``snapshot()``. The press
    /// waits off the main thread, so that opening a microphone for a device the
    /// cache has not listed yet does not refuse a device that is there.
    ///
    /// - Parameter timeout: how long to wait, in seconds.
    /// - Returns: the filled snapshot, or `nil` when the timeout expired.
    func awaitSnapshot(timeout: TimeInterval) -> Snapshot? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        ready.lock()
        defer { ready.unlock() }
        while true {
            lock.lock()
            let answer = cached
            lock.unlock()
            if let answer { return answer }
            if Date() >= deadline { return nil }
            ready.wait(until: deadline)
        }
    }

    /// Starts the first load on `queue`, without waiting for it.
    func begin() {
        queue.async { [weak self] in
            self?.fillIfNeeded()
        }
    }

    /// Whether the last discovery ran on the main thread, and how many ran.
    ///
    /// The app never asks; the test that proves a reader cannot run a discovery
    /// on the main thread does.
    var didReadOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readOnMainThread
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    /// Fills the cache on `queue`, once.
    private func fillIfNeeded() {
        lock.lock()
        let filled = cached != nil
        lock.unlock()
        guard !filled else { return }
        // The observers are installed before the first read, so a device that
        // arrives while the first list is being built is never missed.
        startObserving()
        store(discovery())
    }

    /// Re-reads the devices and the default input. Runs on `queue`.
    private func refresh() {
        store(discovery())
    }

    /// Records one discovery and its thread, and wakes whoever is waiting.
    private func store(_ snapshot: Snapshot) {
        lock.lock()
        cached = snapshot
        reads += 1
        readOnMainThread = Thread.isMainThread
        let announce = !announced
        announced = true
        lock.unlock()
        ready.lock()
        ready.broadcast()
        ready.unlock()
        if announce {
            // One notification, on the main thread, for the two surfaces that
            // read the cache while it was still empty.
            DispatchQueue.main.async { [weak self] in
                NotificationCenter.default.post(
                    name: MicrophoneCatalog.didLoadNotification,
                    object: self
                )
            }
        }
    }

    /// Watches for the two things that change the answer.
    private func startObserving() {
        lock.lock()
        guard !observing else {
            lock.unlock()
            return
        }
        observing = true
        lock.unlock()

        let center = NotificationCenter.default
        for name in [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in self?.refresh() }
            }
            observers.append(token)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The block is delivered on `queue`, so the HAL reads behind it never
        // run on the thread that changed the input.
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue
        ) { [weak self] _, _ in
            self?.refresh()
        }
    }

    /// The question itself: everything that must not run on the main thread.
    private static func read() -> Snapshot {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let aggregates = CoreAudioInput.aggregateUIDs()
        return Snapshot(
            devices: session.devices.map { device in
                MicrophoneDevice(
                    uid: device.uniqueID,
                    name: device.localizedName,
                    isAggregate: aggregates.contains(device.uniqueID)
                )
            },
            defaultInputUID: CoreAudioInput.defaultInputUID()
        )
    }
}

/// What the HAL says about an input that `AVCaptureDevice` reports.
///
/// A discovery session cannot tell a microphone from an aggregate that
/// CoreAudio built to route audio between devices. The HAL can: an aggregate is
/// an `AudioAggregateDevice` (`kAudioAggregateDeviceClassID`) rather than an
/// `AudioDevice`, and it carries the aggregate transport. The UID is the bridge
/// between the two.
enum CoreAudioInput {
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

    /// The UID of the device an input audio unit is running on, or `nil`.
    ///
    /// The engine is the only witness of what it opened: this reads
    /// `kAudioOutputUnitProperty_CurrentDevice` from the unit, then the HAL's own
    /// UID for that device. Nothing here guesses from the configuration, the
    /// cache or the system default, which can all have moved while the engine was
    /// opening.
    ///
    /// - Parameter unit: the audio unit of the engine's input node.
    /// - Returns: the device the input is running on, or `nil` when it cannot be
    ///   read.
    static func deviceUID(of unit: AudioUnit) -> String? {
        guard let device = currentDeviceID(of: unit) else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    /// The device an input audio unit is currently pointed at, or `nil`.
    ///
    /// This is the readback a selection needs: a write is only justified when
    /// the unit does not already name the device the take asked for.
    static func currentDeviceID(of unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        ) == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// The HAL device whose UID is `uid`, when it can record.
    ///
    /// The translation is a HAL question, not a name match: a picker offers the
    /// UID of an `AVCaptureDevice`, and CoreAudio answers with the device an
    /// audio unit has to be pointed at. A device with no input streams cannot be
    /// used as a microphone even when the HAL knows its UID.
    ///
    /// - Parameter uid: the device UID written by the microphone picker.
    /// - Returns: the device ID, or `nil` when the UID is unknown, has no input
    ///   streams, or the HAL cannot answer.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let cfUID = uid as CFString
        let status = withUnsafePointer(to: cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeRawPointer(pointer),
                &size,
                &device
            )
        }
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown),
              hasInputStreams(device) else { return nil }
        return device
    }

    /// Whether a HAL device exposes input streams.
    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return false }
        return size > 0
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
