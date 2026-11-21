import DotCore

/// The grammar chosen for one delivery, and the plan that carries it.
struct PerAppFormatDelivery {
    let grammar: OutputGrammar.Result?
    let plan: TranscriptDelivery
}

/// Composes the per-app grammar and the delivery plan from the same inputs the
/// delivery path has: the config in force, the app frontmost at the press, and
/// the transcript the provider returned.
func perAppFormatDelivery(
    for transcript: String,
    config: DotConfig,
    frontmostBundleIdentifier: String?
) -> PerAppFormatDelivery {
    let grammar: OutputGrammar.Result?
    if config.outputGrammarEnabled {
        let target = config.dictationTarget(for: frontmostBundleIdentifier)
        grammar = target == .plain ? nil : OutputGrammar.result(for: transcript, target: target)
    } else {
        grammar = nil
    }
    return PerAppFormatDelivery(
        grammar: grammar,
        plan: TranscriptDelivery.plan(transcript: transcript, grammar: grammar)
    )
}

/// The pasteboard operations the last step of a delivery needs.
///
/// AppDelegate supplies the system pasteboard; a test supplies one that
/// records what was on it when the paste keystroke was posted.
struct DeliveryPasteboard {
    var copy: (String) -> Void
    var pasteCommand: () -> Bool
    var restore: (String, String) -> Void

    @MainActor static func live(restore: @escaping (String, String) -> Void) -> DeliveryPasteboard {
        DeliveryPasteboard(
            copy: Paste.copy,
            pasteCommand: Paste.pasteCommand,
            restore: restore
        )
    }
}

/// The result of one delivery, including what the guard decided.
struct DispatchedTranscript {
    let grammar: OutputGrammar.Result?
    let plan: TranscriptDelivery
    let decision: PasteDecision
    let delivery: HUDDelivery
    let anchor: InsertionAnchor?
}

/// Runs a finished transcript through the paste guard and the final paste.
///
/// The order of operations matches the app's delivery path: the original words
/// go on the clipboard before the guard, the insertion goes on it only when a
/// paste is allowed, and the original words are restored after a successful
/// paste of a rewritten transcript.
func dispatchTranscript(
    transcript: String,
    config: DotConfig,
    atPress: FrontmostApp?,
    atDelivery: () -> FrontmostApp?,
    accessibilityGranted: () -> Bool,
    ownBundleIdentifier: String,
    shouldCaptureAnchor: () -> Bool,
    captureAnchor: (String) -> InsertionAnchor?,
    pasteboard: DeliveryPasteboard
) -> DispatchedTranscript {
    let formatted = perAppFormatDelivery(
        for: transcript,
        config: config,
        frontmostBundleIdentifier: atPress?.bundleIdentifier
    )
    let plan = formatted.plan
    pasteboard.copy(plan.clipboard)
    let capture = shouldCaptureAnchor()
    let decision = PasteDecision.decide(
        atPress: atPress,
        atDelivery: atDelivery(),
        accessibilityGranted: accessibilityGranted(),
        autoPasteEnabled: config.autoPaste,
        ownBundleIdentifier: ownBundleIdentifier
    )

    switch decision {
    case .paste:
        let rewritten = plan.insertion != plan.clipboard
        if rewritten {
            pasteboard.copy(plan.insertion)
        }
        let anchor = capture ? captureAnchor(plan.insertion) : nil
        guard pasteboard.pasteCommand() else {
            pasteboard.copy(plan.clipboard)
            return DispatchedTranscript(
                grammar: formatted.grammar,
                plan: plan,
                decision: decision,
                delivery: .copied,
                anchor: nil
            )
        }
        if rewritten {
            pasteboard.restore(plan.clipboard, plan.insertion)
        }
        return DispatchedTranscript(
            grammar: formatted.grammar,
            plan: plan,
            decision: decision,
            delivery: .pasted,
            anchor: anchor
        )
    case .copy:
        return DispatchedTranscript(
            grammar: formatted.grammar,
            plan: plan,
            decision: decision,
            delivery: .copied,
            anchor: nil
        )
    }
}
