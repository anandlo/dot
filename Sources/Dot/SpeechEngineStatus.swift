import DotCore
import SwiftUI

/// What the Speech to text page says about the chosen service's key.
///
/// The seven results a check can produce, the state before it has answered, and
/// the state a key that is not in the Keychain produces, whatever the check said
/// about it. The word and the full sentence both live here, so the label, its
/// tooltip and its accessibility value cannot describe the same check
/// differently.
enum SpeechCredentialStatus: Equatable {
    /// The request is on its way, or has not been made yet.
    case checking
    /// The service was asked and answered, at a moment the row remembers.
    case settled(CredentialCheck, checkedAt: Date)
    /// The key in the field is not stored: the Keychain refused it, or it is
    /// text that has been checked but not saved. The words say which.
    case notSaved(String)

    /// The word centred beside the dot.
    var title: String {
        switch self {
        case .checking: "Checking"
        case .settled(let check, _): check.title
        case .notSaved: "Key not saved"
        }
    }

    /// The full sentence: the tooltip and the accessibility value.
    var message: String {
        switch self {
        case .checking: "Asking the service whether it accepts the key."
        case .settled(let check, let at):
            switch check {
            case .verified, .verifiedWithRestriction, .rejected, .serviceError:
                check.message + "\nChecked at " + SpeechCredentialStatus.clock(at)
            case .unreachable, .needsSetup, .unavailable:
                check.message
            }
        case .notSaved(let detail): detail
        }
    }

    /// The single accessible name of the Speech to text Status row.
    var statusAccessibilityLabel: String { "Status, \(title)" }

    /// The accessible value behind that name: the whole reason for the state.
    var statusAccessibilityValue: String { message }

    /// The line under a Status row: the reason, when the check needs one.
    ///
    /// Checking is still in flight and Verified needs no explanation, so neither
    /// repeats its tooltip under the row. This is the rule the AI rewrite page
    /// uses for its own detail line.
    var statusDetail: String? {
        switch self {
        case .checking, .settled(.verified, _):
            nil
        default:
            message
        }
    }

    /// The time a check is stamped with, as a person reads a clock.
    static func clock(_ date: Date) -> String {
        clockFormat.string(from: date)
    }

    private static let clockFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The colour of the dot and the word.
    ///
    /// The tokens are the page's own: the success green a switch uses, the
    /// warning coral, the amber the product reserves for a setup that is not
    /// finished, and the quiet ink of a state that is not a fault.
    var tone: Color {
        switch self {
        case .checking:
            DotTheme.ink3
        case .notSaved:
            DotTheme.coral
        case .settled(let check, _):
            switch check {
            case .verified, .verifiedWithRestriction: DotTheme.switchOn
            case .rejected, .serviceError, .unreachable: DotTheme.coral
            case .needsSetup: DotTheme.amber
            case .unavailable: DotTheme.ink3
            }
        }
    }

    /// Whether the check is still in flight.
    var isChecking: Bool { self == .checking }
}

/// The automatic check behind the status label of the Speech to text page.
///
/// A check is one request to the chosen service, made when the page appears,
/// shortly after a key or address is edited, when a key is saved or deleted,
/// when the service or the address changes, and when the window comes back to
/// the front. A new check cancels the one in flight, a fresh answer is reused
/// for ten minutes, and the key is read through the credential cache off the
/// main thread: a page that redraws must never wait on the Keychain.
@MainActor
final class SpeechCredentialChecks: ObservableObject {
    /// The state the label draws.
    @Published private(set) var status: SpeechCredentialStatus = .checking

    /// Where a stored key comes from.
    private let cache: CredentialCache
    /// Where a fresh answer is kept.
    private let checkCache: any CredentialCheckCaching
    /// The clock a result is stamped with.
    private let now: () -> Date
    /// Which check is the current one.
    ///
    /// Every check takes a number; a result whose number is no longer the current
    /// one is dropped, however long its request took. A provider switch while a
    /// check is in flight is exactly that case.
    private var generation = 0

    /// How long an edit rests before the service is asked.
    ///
    /// The same pause the AI rewrite page gives a typed address: long enough to
    /// swallow a word, short enough that a pasted key is checked while the
    /// person is still on the page.
    static let editDelay: Duration = .milliseconds(600)

    /// How long a stored key may take to come back from the Keychain.
    let keyDeadline: Duration

    /// Whether a stored-key read has failed since the page appeared.
    private var storedReadFailed = false

    private var task: Task<Void, Never>?

    /// Creates the checks.
    ///
    /// - Parameters:
    ///   - cache: where stored keys are read.
    ///   - checkCache: where answered questions are kept.
    ///   - now: the clock a result is stamped with.
    ///   - keyDeadline: how long a stored-key read may take.
    init(
        cache: CredentialCache = .shared,
        checkCache: any CredentialCheckCaching = CredentialCheckCache.shared,
        now: @escaping () -> Date = Date.init,
        keyDeadline: Duration = .seconds(5)
    ) {
        self.cache = cache
        self.checkCache = checkCache
        self.now = now
        self.keyDeadline = keyDeadline
    }

    /// Marks the page as newly opened.
    ///
    /// A stored-key read that failed is not retried while the page is open: the
    /// read can put a Keychain prompt on screen, and a person who denied it
    /// must not be asked again at every pause in the key field. Reopening the
    /// page is the one moment the page asks again.
    func pageAppeared() {
        storedReadFailed = false
    }

    /// Starts a check, replacing whatever was running.
    ///
    /// - Parameters:
    ///   - providerID: the service the page is showing.
    ///   - config: the configuration the provider is built from.
    ///   - typedKey: the key in the field, when the person has typed one. It is
    ///     the key a check uses while it is still being set up.
    ///   - serviceName: the name of the row the page is showing, which is the
    ///     only name a page may put in a sentence.
    ///   - requiresKey: whether the row cannot be used without a key, in which
    ///     case a missing one is answered here instead of with a request.
    ///   - immediate: whether the check is the answer to an action rather than
    ///     the end of an edit, in which case it does not wait.
    func check(
        providerID: String,
        config: DotConfig,
        typedKey: String?,
        serviceName: String,
        requiresKey: Bool,
        immediate: Bool
    ) {
        task?.cancel()
        generation += 1
        let generation = generation
        // A check is the next question asked about the key, so a Keychain
        // refusal the page was showing no longer describes the row.
        clearNotSaved()
        let settings = config.settings(for: providerID)
        let baseURL = settings.baseURL
        let authStyle = settings.authStyle?.rawValue
        let language = settings.language
        task = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(for: Self.editDelay)
                guard self.isCurrent(generation) else { return }
            }
            let extra = await Self.providerState(providerID: providerID, language: language)
            guard self.isCurrent(generation) else { return }
            let (key, unsaved) = await credentials(for: providerID, typed: typedKey)
            guard self.isCurrent(generation) else { return }
            if requiresKey, key == nil {
                publish(
                    .needsSetup("Add an API key for \(serviceName)."),
                    at: now(),
                    generation: generation,
                    unsaved: false
                )
                return
            }
            let entry = CredentialCheckCache.entry(
                providerID: providerID,
                baseURL: baseURL,
                authStyle: authStyle,
                credential: key,
                extra: extra
            )
            if let fresh = await checkCache.result(for: entry, now: now()) {
                guard self.isCurrent(generation) else { return }
                publish(fresh.check, at: fresh.checkedAt, generation: generation, unsaved: unsaved)
                return
            }
            status = .checking
            let check = await ProviderRegistry.verifyCredentials(
                id: providerID,
                config: config,
                apiKey: key
            )
            guard self.isCurrent(generation) else { return }
            await checkCache.store(check, for: entry, at: now())
            // Storing is not publishing, and a question that was replaced while
            // its answer was being written down is still replaced. Its answer
            // is removed again: a later check of that question must ask the
            // service, not trust an answer the page abandoned.
            guard self.isCurrent(generation) else {
                await checkCache.remove(entry)
                return
            }
            publish(check, at: now(), generation: generation, unsaved: unsaved)
        }
    }

    /// Whether a check is still the question the page is asking.
    ///
    /// Every await in a check is followed by this test: the page may have
    /// switched service, edited the key or been closed while the request was in
    /// flight, and the answer to the old question must not land on the new one.
    ///
    /// - Parameter generation: the number the check took when it started.
    /// - Returns: whether this check is the current one and has not been
    ///   cancelled.
    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == self.generation
    }

    /// Publishes a settled answer, when the check that produced it is still the
    /// current one.
    ///
    /// A key that is only typed is never reported as saved, whatever the
    /// service said about it: dictation cannot use a key the Keychain does not
    /// hold, so the row says "Key not saved" and the sentence carries the
    /// answer, which is either that the key works or why it was refused.
    ///
    /// - Parameters:
    ///   - check: what the service said.
    ///   - date: the moment the answer arrived, whether now or before.
    ///   - generation: the check that produced it.
    ///   - unsaved: whether the checked key is text in the field rather than
    ///     the key the Keychain holds.
    private func publish(
        _ check: CredentialCheck,
        at date: Date,
        generation: Int,
        unsaved: Bool
    ) {
        guard generation == self.generation else { return }
        guard !unsaved else {
            status = .notSaved(Self.unsavedMessage(for: check))
            return
        }
        status = .settled(check, checkedAt: date)
    }

    /// The sentence a checked-but-unsaved key shows.
    ///
    /// - Parameter check: what the service said about the typed key.
    /// - Returns: the acceptance sentence for a key that works, otherwise the
    ///   service's own refusal or failure sentence.
    static func unsavedMessage(for check: CredentialCheck) -> String {
        switch check {
        case .verified, .verifiedWithRestriction:
            "The key works. Save it to use it."
        default:
            check.message
        }
    }

    /// The provider's own state that changes its answer, for the cache name.
    ///
    /// Only the on-device provider has any: its locale and the state of the
    /// language's asset decide what it will say, and both can change while the
    /// app runs.
    /// - Parameters:
    ///   - providerID: the provider about to be asked.
    ///   - language: the stored language, when there is one.
    /// - Returns: the extra part of the cache name, or `nil`.
    private static func providerState(providerID: String, language: String?) async -> String? {
        guard providerID == ProviderIdentifier.apple else { return nil }
        let provider = AppleSpeechProvider(localeIdentifier: language ?? "en_US")
        return "locale:\(language ?? "en_US") " + (await provider.assetFingerprint())
    }

    /// Drops the check that is running.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Reports that the Keychain refused to store a key.
    ///
    /// Nothing was sent to the service, so this is not a credential check: it is
    /// never cached in ``CredentialCheckCache`` and never logged. The words are
    /// the writer's own, and the label shows them as its tooltip.
    ///
    /// - Parameter message: what the writer said, verbatim.
    func markNotSaved(_ message: String) {
        task?.cancel()
        generation += 1
        status = .notSaved(message)
    }

    /// Drops a refusal the page was showing, because a key was saved or a new
    /// question about the key is being asked.
    func clearNotSaved() {
        if case .notSaved = status {
            status = .checking
        }
    }

    /// What the Keychain had to say about the stored key.
    private enum StoredKey {
        /// A read completed: the key, or a definite absence.
        case read(String?)
        /// No read completed: it timed out, failed, or another caller is
        /// holding it. The comparison cannot be made.
        case unknown
    }

    /// The key to check with, and whether it is unsaved text in the field.
    ///
    /// The stored key is read even when the field holds a key: the two are
    /// compared, because text that happens to be the stored key is not an
    /// unsaved change. The comparison is three-valued: an answer that did not
    /// arrive is not a difference, so an unknown stored key leaves the row
    /// with the plain check answer instead of "Key not saved".
    ///
    /// - Parameters:
    ///   - providerID: the provider whose key is checked.
    ///   - typed: the text in the field, when there is any.
    /// - Returns: the key the request should carry, and whether that key is
    ///   text the Keychain definitely does not hold.
    private func credentials(for providerID: String, typed: String?) async -> (key: String?, unsaved: Bool) {
        let typed = CredentialVerifier.credential(typed)
        switch await storedKey(for: providerID) {
        case .unknown:
            return (typed, false)
        case .read(let stored):
            guard let typed else { return (stored, false) }
            return (typed, typed != stored)
        }
    }

    /// The stored key, when a read produced an answer.
    ///
    /// ``CredentialCache/key(for:)`` answers `nil` for three different
    /// situations: no key, a read that failed, and a read another caller is
    /// already making. Only the first is a fact. A read that finished is
    /// definite when the cache resolved it; one that timed out, failed or was
    /// still in progress is unknown. A failure also stops the page reading the
    /// Keychain again until it is reopened, so a denied prompt is not repeated
    /// on every pause in the field.
    ///
    /// - Parameter providerID: the provider whose key is read.
    /// - Returns: the definite answer, or ``StoredKey/unknown``.
    private func storedKey(for providerID: String) async -> StoredKey {
        if storedReadFailed { return .unknown }
        let cache = self.cache
        if cache.readFailed(providerID) {
            storedReadFailed = true
            return .unknown
        }
        _ = await cache.resolved(for: providerID)
        guard cache.isResolved(providerID) else {
            if cache.readFailed(providerID) {
                storedReadFailed = true
            }
            return .unknown
        }
        return .read(cache.resolvedKey(for: providerID))
    }
}

/// The state a render draws in place of a live check.
private struct SettingsCredentialPreviewKey: EnvironmentKey {
    static let defaultValue: SpeechCredentialStatus? = nil
}

extension EnvironmentValues {
    /// The credential state a render was handed, or `nil` for the live one.
    var settingsCredentialPreview: SpeechCredentialStatus? {
        get { self[SettingsCredentialPreviewKey.self] }
        set { self[SettingsCredentialPreviewKey.self] = newValue }
    }
}
