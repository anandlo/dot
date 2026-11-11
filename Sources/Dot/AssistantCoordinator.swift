import AppKit
import DotCore
import Foundation

/// Runs one question to the assistant and puts the answer where it belongs.
///
/// The coordinator owns the turn: it is the only place that knows a question is
/// in flight, what the answer so far is, and whether the person may still stop
/// it. Everything it touches is a protocol, so a test drives a turn without a
/// network, a Keychain, an audio engine or an island.
///
/// Nothing is built before the first question. A person who never asks the
/// assistant never pays for a chat client, a registry of connectors or an audio
/// engine, and ``createdComponents`` is how that promise is checked.
@MainActor
final class AssistantCoordinator {
    /// How long a turn's conversation is kept for the next question.
    static let historyLifetime: TimeInterval = 120
    /// How long the voice may sit idle before the audio engine is released.
    static let speechIdleTeardown: TimeInterval = 30
    /// The longest a confirmation waits for an answer.
    static let confirmationTimeout: TimeInterval = 30
    /// The shortest gap between two redraws of a streaming answer.
    static let hudUpdateInterval: TimeInterval = 0.05

    private let factory: any ChatProviderFactory
    private let makeSpeaker: () -> any AnswerSpeaker
    private let paster: any AnswerPaster
    private let hud: any AssistantHUD
    private let settings: () -> AssistantRuntimeSettings
    private let now: () -> Date

    private var provider: (any ChatProvider)?
    /// The chat settings the provider was built from.
    private var providerSettings: AssistantSettings?
    private var tools: AssistantTools?
    /// The configuration the tools were built from.
    private var toolsSettings: ToolsSignature?
    private var speaker: (any AnswerSpeaker)?

    /// What a toolbox is built from, so a switch that moved is noticed.
    struct ToolsSignature: Equatable {
        var connectors: ConnectorSettings
        var actionsEnabled: Bool
    }

    private var turnTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var speechTeardownTask: Task<Void, Never>?
    private var confirmationTimeoutTask: Task<Void, Never>?

    private var history: [ChatMessage] = []
    private var historyAt: Date?
    private var frontmostAtPress: FrontmostApp?
    private var frontmostNameAtPress: String?
    private var lastHUDUpdate = Date.distantPast
    private var pendingAnswer: String?
    /// Whether the voice has finished the turn's answer already.
    ///
    /// A very short answer can be played out before the turn itself ends. The
    /// delivery reads this so the card says the answer was spoken instead of
    /// leaving ``AssistantAnswerState/speaking`` on screen with nothing behind
    /// it.
    private var speechEnded = false

    private var activeConfirmation: ConfirmationRequest?
    private var activeContinuation: CheckedContinuation<Bool, Never>?
    private var queuedConfirmations: [(request: ConfirmationRequest, continuation: CheckedContinuation<Bool, Never>)] = []

    /// What the assistant is doing right now.
    private(set) var phase: AssistantPhase = .idle

    /// How many pieces of the engine this coordinator has built.
    ///
    /// A turn builds at most three: the provider, the tools and the voice. The
    /// count exists so a test can prove a turn that needs none of them built
    /// none of them.
    private(set) var createdComponents = 0

    /// The question of the turn in flight, when there is one.
    private(set) var question: String?

    /// The answer so far.
    private(set) var answer: String = ""

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - factory: builds the provider and the tools, once per app run.
    ///   - makeSpeaker: builds the voice, on the first answer that is spoken.
    ///   - paster: reads the clipboard and the frontmost application.
    ///   - hud: the island.
    ///   - settings: the configuration, read at the start of every turn.
    ///   - now: the clock. It is injected because the conversation expires.
    init(
        factory: any ChatProviderFactory,
        makeSpeaker: @escaping () -> any AnswerSpeaker,
        paster: any AnswerPaster,
        hud: any AssistantHUD,
        settings: @escaping () -> AssistantRuntimeSettings,
        now: @escaping () -> Date = Date.init
    ) {
        self.factory = factory
        self.makeSpeaker = makeSpeaker
        self.paster = paster
        self.hud = hud
        self.settings = settings
        self.now = now
    }

    /// Asks the assistant a question.
    ///
    /// - Parameters:
    ///   - prompt: what the person said, as it was transcribed.
    ///   - frontmost: the application that was in front when the question was
    ///     started. The answer is pasted into it only if it is still in front.
    ///   - frontmostName: that application's name, for the card.
    func ask(_ prompt: String, frontmost: FrontmostApp?, frontmostName: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hud.showAssistantMessage("Nothing was heard.", symbol: "waveform.slash")
            return
        }
        let runtime = settings()
        guard isReachable(runtime.configuration.chat) else {
            hud.showAssistantMessage("Connect an assistant service in Settings.", symbol: "sparkle")
            return
        }
        frontmostAtPress = frontmost
        frontmostNameAtPress = frontmostName
        question = trimmed
        answer = ""
        lastHUDUpdate = .distantPast
        pendingAnswer = nil
        speechEnded = false
        phase = .thinking
        hud.showAssistantThinking(question: trimmed)
        startTurn(prompt: trimmed, runtime: runtime)
    }

    /// Whether a service can be asked at all.
    ///
    /// A service on this Mac needs no key: it is reachable as soon as the
    /// address answers, which the request itself finds out. Everything else
    /// needs a stored key, and without one the person is sent to Settings
    /// rather than into a request that can only fail.
    private func isReachable(_ chat: AssistantSettings) -> Bool {
        let row = AssistantProviderCatalogue.row(for: chat.providerID)
        guard row.requiresKey else { return true }
        return factory.hasKey(for: chat.providerID)
    }

    private func startTurn(prompt: String, runtime: AssistantRuntimeSettings) {
        turnTask?.cancel()
        turnTask = Task { @MainActor [weak self] in
            await self?.run(prompt: prompt, runtime: runtime)
        }
    }

    // MARK: - The turn

    private func run(prompt: String, runtime: AssistantRuntimeSettings) async {
        let chat = runtime.configuration.chat
        guard let provider = await ensureProvider(chat) else { return }
        let tools = await ensureTools(runtime.configuration)
        let session = AssistantSession(
            provider: provider,
            model: AssistantProviderCatalogue.model(for: chat),
            toolbox: tools.toolbox,
            configuration: AssistantSessionConfiguration(maximumSteps: chat.maxSteps)
        )
        let carried = liveHistory()
        // The voice is started before the first event is read, so every delta is
        // fed to a player that is already listening instead of being spoken from
        // the middle of the answer.
        if runtime.configuration.delivery.speaks {
            _ = await prepareSpeaker(runtime.configuration.voice)
        }
        for await event in session.run(prompt: prompt, history: carried) {
            if Task.isCancelled { break }
            switch event {
            case .thinking:
                beginThinking()
            case .textDelta(let delta):
                append(delta, delivery: runtime.configuration.delivery)
            case .toolStarted(let name):
                showTool(tools.connectorName(for: name))
            case .toolFinished, .usage:
                break
            case .finished(let result):
                deliver(result, runtime: runtime)
            case .failed(let message):
                fail(message)
            }
        }
        turnTask = nil
    }

    /// The provider, built on the first turn that needs one.
    ///
    /// A service the person changed in Settings is a different provider, so the
    /// record it was built from is kept and compared: the next question uses
    /// what the person chose without a relaunch.
    private func ensureProvider(_ chat: AssistantSettings) async -> (any ChatProvider)? {
        if let provider, providerSettings == chat { return provider }
        do {
            let built = try await factory.makeProvider(chat)
            provider = built
            providerSettings = chat
            createdComponents += 1
            return built
        } catch {
            fail(Self.text(for: error))
            return nil
        }
    }

    /// The tools, built on the first turn that needs them.
    private func ensureTools(_ configuration: AssistantConfiguration) async -> AssistantTools {
        let wanted = ToolsSignature(
            connectors: configuration.connectors,
            actionsEnabled: configuration.actionsEnabled
        )
        if let tools, toolsSettings == wanted { return tools }
        guard configuration.actionsEnabled else {
            tools = AssistantTools.none
            toolsSettings = wanted
            return AssistantTools.none
        }
        // The gate is the island: a risky call puts its sentence on the card and
        // waits for an answer. A confirmation that times out is a no.
        let gate = ConfirmationGate { [weak self] request in
            await self?.confirm(request) ?? false
        }
        let built = await factory.makeTools(configuration, gate: gate)
        tools = built
        toolsSettings = wanted
        createdComponents += 1
        return built
    }

    // MARK: - The answer as it arrives

    /// Adds a piece of the answer, speaks it, and redraws the card at most
    /// twenty times a second.
    ///
    /// The voice is fed every delta as it lands: cutting the text into sentences
    /// is the player's job, and a dropped delta would be a dropped word. The
    /// card is different. A model that streams faster than the island can lay
    /// out would make it flicker, so a redraw is held for up to 50 ms and the
    /// newest text always wins.
    private func append(_ delta: String, delivery: AnswerDelivery) {
        answer += delta
        if delivery.speaks {
            speaker?.feed(delta)
        }
        guard phase != .confirming else { return }
        phase = .streaming
        pushAnswer(answer, state: .streaming)
    }

    private func pushAnswer(_ text: String, state: AssistantAnswerState) {
        let moment = now()
        guard moment.timeIntervalSince(lastHUDUpdate) >= Self.hudUpdateInterval else {
            pendingAnswer = text
            scheduleFlush()
            return
        }
        lastHUDUpdate = moment
        pendingAnswer = nil
        hud.showAssistantAnswer(text: text, state: state)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AssistantCoordinator.hudUpdateInterval))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            guard let pending = self.pendingAnswer else { return }
            self.pendingAnswer = nil
            self.lastHUDUpdate = self.now()
            guard self.phase == .streaming else { return }
            self.hud.showAssistantAnswer(text: pending, state: .streaming)
        }
    }

    // MARK: - Speech

    /// Builds the voice and starts a turn with it.
    ///
    /// It runs before the first event is read, so every delta is fed to a player
    /// that is already listening and the answer is never spoken from the middle.
    ///
    /// - Returns: `false` when the voice cannot be built, in which case the
    ///   answer goes to the cursor instead of being lost.
    private func prepareSpeaker(_ voice: VoiceSettings) async -> Bool {
        speechTeardownTask?.cancel()
        if speaker == nil {
            let created = makeSpeaker()
            createdComponents += 1
            created.onFinish = { [weak self] in self?.speechDidFinish() }
            created.onFailure = { [weak self] message in self?.fail(message) }
            speaker = created
        }
        guard let player = speaker else { return false }
        // Every answer starts a turn, so a voice the person changed in Settings
        // is the voice this answer uses.
        guard await player.beginSpeaking(voice) else {
            player.tearDownSpeech()
            speaker = nil
            return false
        }
        return true
    }

    private func speechDidFinish() {
        guard phase != .confirming else { return }
        speechEnded = true
        phase = .idle
        if !answer.isEmpty {
            hud.showAssistantAnswer(text: answer, state: .spoken)
        }
        scheduleSpeechTeardown()
    }

    /// Releases the audio engine once the voice has been quiet for a while.
    private func scheduleSpeechTeardown() {
        speechTeardownTask?.cancel()
        speechTeardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AssistantCoordinator.speechIdleTeardown))
            guard let self, !Task.isCancelled, self.phase != .speaking else { return }
            self.speaker?.tearDownSpeech()
        }
    }

    // MARK: - The conversation

    /// The earlier turns, if they are still fresh enough to be a conversation.
    private func liveHistory() -> [ChatMessage] {
        guard let historyAt else { return [] }
        guard now().timeIntervalSince(historyAt) <= Self.historyLifetime else {
            dropHistory()
            return []
        }
        return history
    }

    private func remember(_ messages: [ChatMessage]) {
        history = messages
        historyAt = now()
    }

    private func dropHistory() {
        history = []
        historyAt = nil
    }

    // MARK: - States of the card

    private func beginThinking() {
        guard phase != .confirming else { return }
        phase = .thinking
        if let question {
            hud.showAssistantThinking(question: question)
        }
    }

    private func showTool(_ connectorName: String) {
        guard phase != .confirming else { return }
        phase = .tool
        hud.showAssistantTool(connectorName: connectorName)
    }

    // MARK: - Delivery

    private func deliver(_ result: AssistantSessionResult, runtime: AssistantRuntimeSettings) {
        guard result.stopReason != .cancelled else {
            cancelTurn()
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            dropHistory()
            speaker?.stopSpeaking()
            scheduleSpeechTeardown()
            phase = .idle
            hud.showAssistantMessage("The assistant did not answer.", symbol: "sparkle")
            return
        }
        answer = text
        remember(result.messages)
        let delivery = runtime.configuration.delivery
        let speaks = delivery.speaks && speaker != nil
        if delivery.speaks {
            speaker?.finishSpeaking()
        }
        switch delivery {
        case .speak where speaks && speechEnded:
            phase = .idle
            hud.showAssistantAnswer(text: text, state: .spoken)
            scheduleSpeechTeardown()
        case .speak where speaks:
            phase = .speaking
            hud.showAssistantAnswer(text: text, state: .speaking)
            scheduleSpeechTeardown()
        case .speak:
            // The voice could not be built, so the answer goes where every other
            // answer goes rather than being lost to a silent failure.
            paste(text, runtime: runtime)
        case .paste:
            paste(text, runtime: runtime)
        case .pasteAndSpeak:
            // The paste is the irreversible half, so the header names where the
            // answer landed; the voice announces itself.
            paste(text, runtime: runtime)
            if speaks {
                phase = .speaking
                scheduleSpeechTeardown()
            }
        }
    }

    /// Copies the answer and pastes it only where it was asked for.
    private func paste(_ text: String, runtime: AssistantRuntimeSettings) {
        paster.copy(text)
        let decision = PasteDecision.decide(
            atPress: frontmostAtPress,
            atDelivery: paster.frontmostApp,
            accessibilityGranted: paster.accessibilityGranted,
            autoPasteEnabled: runtime.autoPaste,
            ownBundleIdentifier: runtime.ownBundleIdentifier
        )
        let state: AssistantAnswerState
        switch decision {
        case .paste:
            paster.paste()
            state = .pasted(frontmostNameAtPress)
        case .copy:
            state = .copied
        }
        if phase != .speaking {
            phase = .idle
        }
        hud.showAssistantAnswer(text: text, state: state)
    }

    private func fail(_ message: String) {
        dropHistory()
        flushTask?.cancel()
        flushTask = nil
        pendingAnswer = nil
        speaker?.stopSpeaking()
        scheduleSpeechTeardown()
        phase = .idle
        hud.showAssistantMessage(
            ProviderErrorText.sanitized(message) ?? message,
            symbol: "exclamationmark.triangle"
        )
    }

    // MARK: - Confirmation

    /// Puts a connected app's request on the card and waits for the person.
    ///
    /// - Parameter request: what the app wants to do.
    /// - Returns: whether it may run. A request that times out, or a turn that
    ///   is stopped while it waits, answers no.
    func confirm(_ request: ConfirmationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            if activeConfirmation == nil {
                activeConfirmation = request
                activeContinuation = continuation
                present(request)
            } else {
                queuedConfirmations.append((request, continuation))
            }
        }
    }

    /// The person allowed the request.
    func allowConfirmation() {
        resolveConfirmation(true)
    }

    /// The person refused the request.
    func declineConfirmation() {
        resolveConfirmation(false)
    }

    private func present(_ request: ConfirmationRequest) {
        phase = .confirming
        hud.showAssistantConfirm(
            request,
            onAllow: { [weak self] in self?.allowConfirmation() },
            onCancel: { [weak self] in self?.declineConfirmation() }
        )
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AssistantCoordinator.confirmationTimeout))
            guard let self, !Task.isCancelled else { return }
            self.resolveConfirmation(false)
        }
    }

    /// Answers the visible request and shows the next one, if any.
    private func resolveConfirmation(_ allowed: Bool) {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        guard let continuation = activeContinuation else {
            // Nothing is on the card any more: the turn was stopped while the
            // request waited, and the queue has already been answered.
            drainConfirmationQueue()
            return
        }
        activeContinuation = nil
        activeConfirmation = nil
        hud.hideAssistantConfirm()
        continuation.resume(returning: allowed)
        if let next = queuedConfirmations.first {
            queuedConfirmations.removeFirst()
            activeConfirmation = next.request
            activeContinuation = next.continuation
            present(next.request)
        } else if phase == .confirming {
            phase = .tool
        }
    }

    private func drainConfirmationQueue() {
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        activeContinuation = nil
        activeConfirmation = nil
        for waiting in queuedConfirmations {
            waiting.continuation.resume(returning: false)
        }
        queuedConfirmations.removeAll()
        hud.hideAssistantConfirm()
    }

    // MARK: - Stopping

    /// Stops the turn: the request is cancelled, the voice silenced and the card
    /// taken away. The conversation is dropped with it, because the next
    /// question is a new one.
    func cancelTurn() {
        turnTask?.cancel()
        turnTask = nil
        flushTask?.cancel()
        flushTask = nil
        pendingAnswer = nil
        speaker?.stopSpeaking()
        scheduleSpeechTeardown()
        drainConfirmationQueue()
        dropHistory()
        answer = ""
        question = nil
        phase = .idle
        hud.hideAssistant()
    }

    /// Silences the voice and leaves the answer on the card.
    func stopSpeech() {
        guard phase == .speaking else { return }
        speaker?.stopSpeaking()
        phase = .idle
        if !answer.isEmpty {
            hud.showAssistantAnswer(text: answer, state: .spoken)
        }
        scheduleSpeechTeardown()
    }

    /// The app is going away: nothing is left running behind it.
    func terminate() {
        turnTask?.cancel()
        turnTask = nil
        flushTask?.cancel()
        flushTask = nil
        drainConfirmationQueue()
        speaker?.tearDownSpeech()
        speechTeardownTask?.cancel()
        speechTeardownTask = nil
        phase = .idle
    }

    /// Whether a turn is doing something the assistant key can stop.
    var isTurnActive: Bool {
        switch phase {
        case .thinking, .streaming, .tool, .speaking, .confirming: true
        case .idle, .recording: false
        }
    }

    /// A message for the card, with a provider's words made safe to show.
    private static func text(for error: Error) -> String {
        if let described = error as? LocalizedError, let description = described.errorDescription {
            return ProviderErrorText.sanitized(description) ?? "The assistant service could not be reached."
        }
        return ProviderErrorText.sanitized(error.localizedDescription)
            ?? "The assistant service could not be reached."
    }
}
