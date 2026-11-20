/// The mouse button, if any, that Dot uses as a hold-to-talk trigger.
///
/// `.off` leaves every mouse button to the system. The other cases name the
/// physical button Dot consumes while it is held, and release it again when the
/// setting returns to `.off`.
public enum MouseTriggerButton: String, Codable, Sendable, CaseIterable {
    /// No mouse button is assigned.
    case off
    /// The middle (scroll-wheel) button.
    case middle
    /// The back (thumb) button.
    case back
    /// The forward (thumb) button.
    case forward

    /// The CoreGraphics button number for this choice, or `nil` for `.off`.
    public var buttonNumber: Int64? {
        switch self {
        case .off: nil
        case .middle: 2
        case .back: 3
        case .forward: 4
        }
    }

    /// The human-readable name of the choice, as it appears in settings.
    public var title: String {
        switch self {
        case .off: "Off"
        case .middle: "Middle button"
        case .back: "Back button"
        case .forward: "Forward button"
        }
    }
}
