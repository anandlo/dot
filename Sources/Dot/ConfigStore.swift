import DotCore
import Foundation
import SwiftUI

/// The configuration the app is editing, as something SwiftUI can observe.
///
/// The settings window used to hold a `Binding` whose storage was a plain
/// property on the app delegate: a write through it changed nothing the window
/// was observing, so a page redrew only when something else happened to redraw
/// it. That is what made a picked service look like it did not take. A
/// ``ConfigStore`` is the one place the configuration lives for the surfaces
/// that draw it: ``config`` is published, so every write by any writer redraws
/// the page, and ``onWrite`` is the one path every write takes, so the
/// configuration is timestamped and scheduled for saving whatever wrote it.
@MainActor
final class ConfigStore: ObservableObject {
    /// The configuration every surface reads and writes.
    @Published var config: DotConfig {
        didSet {
            guard config != oldValue else { return }
            onWrite?()
        }
    }

    /// Called once after every real write, whatever wrote it.
    ///
    /// The app delegate puts the change timestamp and the debounced save here,
    /// so a write cannot bypass them by not going through a particular binding.
    var onWrite: (@MainActor () -> Void)?

    /// Creates a store.
    ///
    /// - Parameter config: the configuration to start from.
    init(config: DotConfig = .default) {
        self.config = config
    }

    /// A binding to the published configuration.
    ///
    /// The settings window derives its `config` binding from this, so a control
    /// that writes through it writes the store and not a copy of it.
    var configBinding: Binding<DotConfig> {
        Binding(
            get: { self.config },
            set: { self.config = $0 }
        )
    }
}
