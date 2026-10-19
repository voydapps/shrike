// Pure launch endpoint reducer, shared by the app shell and the offline harness.
// Times are monotonic inputs. They are never a replacement for Metal's actual
// presented callback: only that callback may call photoPresented(at:).
struct LaunchPresentationState {
    enum Outcome: Equatable {
        case realPhotoPresented
        case noPhoto
        case photoUnavailable
    }

    private(set) var windowReadyAt: Double?
    private(set) var placeholderPresentedAt: Double?
    private(set) var realPhotoPresentedAt: Double?
    private(set) var outcome: Outcome?

    mutating func windowReady(at time: Double) -> Bool {
        guard windowReadyAt == nil else { return false }
        windowReadyAt = time
        return true
    }

    mutating func placeholderPresented(at time: Double) -> Bool {
        guard outcome == nil, placeholderPresentedAt == nil else { return false }
        placeholderPresentedAt = time
        return true
    }

    mutating func photoPresented(at time: Double) -> Bool {
        guard outcome == nil else { return false }
        realPhotoPresentedAt = time
        outcome = .realPhotoPresented
        return true
    }

    mutating func settleWithoutPhoto(hasPendingOpen: Bool, hasViewer: Bool) -> Bool {
        guard outcome == nil, !hasPendingOpen, !hasViewer else { return false }
        outcome = .noPhoto
        return true
    }

    mutating func presentationUnavailable() -> Bool {
        guard outcome == nil else { return false }
        outcome = .photoUnavailable
        return true
    }
}
