import AppKit

/// The axis a wheel gesture reads its travel from once it has begun.
enum HUDWheelAxis: Equatable, Sendable {
    case horizontal
    case vertical

    /// The travel this axis takes from one wheel event.
    ///
    /// The rail only scrolls sideways, so a vertical gesture is mapped onto
    /// the same horizontal travel: a mouse wheel, and a trackpad pushed up or
    /// down, move the chips as a sideways flick does.
    func step(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        switch self {
        case .horizontal: deltaX
        case .vertical: deltaY
        }
    }

    /// The axis a gesture beginning with these deltas owns.
    ///
    /// A sideways trackpad flick is horizontal. Every other beginning, such as
    /// a vertical trackpad, a mouse wheel, or a diagonal whose vertical travel
    /// wins, is vertical, and its travel is mapped onto the row. There is no
    /// dead band: a small horizontal component never discards the event. A
    /// beginning with no travel yet has no axis; the first movement latches it.
    static func beginning(deltaX: CGFloat, deltaY: CGFloat) -> HUDWheelAxis? {
        guard deltaX != 0 || deltaY != 0 else { return nil }
        if deltaX != 0, abs(deltaX) >= abs(deltaY) { return .horizontal }
        return .vertical
    }
}

/// Which scroll view a wheel gesture belongs to.
enum HUDWheelOwner: Sendable {
    case none
    case rail
    case body
    case versions
}

/// One wheel gesture's owner and axis, held from the event that began it
/// through its momentum.
///
/// AppKit sends a gesture as `began`, `changed` and `ended`, followed by
/// momentum events whose location follows the pointer. Deciding the owner once,
/// on the beginning, is what keeps every event of the gesture together: a
/// diagonal event is never rejected on its own, and a gesture that started over
/// the style rail keeps the rail even when the pointer drifts away from it.
///
/// The axis is latched on the first movement with travel. A gesture may begin
/// with a stationary event, and the direction it then takes is still the
/// gesture's own; the applier is decided per event, because only the event
/// knows whether AppKit delivered it.
struct HUDWheelGesture: Sendable {
    private(set) var owner: HUDWheelOwner = .none
    private(set) var axis: HUDWheelAxis?
    private(set) var isTracking = false

    mutating func begin(owner: HUDWheelOwner, axis: HUDWheelAxis?) {
        self.owner = owner
        self.axis = axis
        isTracking = true
    }

    /// Latches the axis on the first movement that has travel.
    ///
    /// - Returns: the gesture's axis, or `nil` while every event is stationary.
    mutating func latchAxis(deltaX: CGFloat, deltaY: CGFloat) -> HUDWheelAxis? {
        if axis == nil {
            axis = HUDWheelAxis.beginning(deltaX: deltaX, deltaY: deltaY)
        }
        return axis
    }

    mutating func cancel() {
        self = HUDWheelGesture()
    }
}

/// One pointer event, copied off its `NSEvent` before the main actor is asked
/// for a turn.
///
/// `NSEvent` belongs to the thread that produced it, and a global monitor's
/// event carries the pointer's location at the moment it was produced. The
/// snapshot is what crosses to the main actor: the event-time location is read
/// before the handoff, so a later pointer move cannot change where the gesture
/// began.
struct HUDPointerEvent: Sendable {
    enum Kind: Sendable {
        case moved
        case click
        case wheel
    }

    let kind: Kind
    let deltaX: CGFloat
    let deltaY: CGFloat
    let isPrecise: Bool
    let phaseRawValue: UInt
    let momentumPhaseRawValue: UInt
    let isDirectionInvertedFromDevice: Bool

    init(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            kind = .wheel
            deltaX = event.scrollingDeltaX
            deltaY = event.scrollingDeltaY
            isPrecise = event.hasPreciseScrollingDeltas
            phaseRawValue = event.phase.rawValue
            momentumPhaseRawValue = event.momentumPhase.rawValue
            isDirectionInvertedFromDevice = event.isDirectionInvertedFromDevice
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .click
            deltaX = 0
            deltaY = 0
            isPrecise = false
            phaseRawValue = 0
            momentumPhaseRawValue = 0
            isDirectionInvertedFromDevice = false
        default:
            kind = .moved
            deltaX = 0
            deltaY = 0
            isPrecise = false
            phaseRawValue = 0
            momentumPhaseRawValue = 0
            isDirectionInvertedFromDevice = false
        }
    }

    var phase: NSEvent.Phase { NSEvent.Phase(rawValue: phaseRawValue) }
    var momentumPhase: NSEvent.Phase {
        NSEvent.Phase(rawValue: momentumPhaseRawValue)
    }
}
