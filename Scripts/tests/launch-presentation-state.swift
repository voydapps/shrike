// Compile together with App/Sources/LaunchPresentationState.swift. No AppKit,
// Metal device, package build, preferences, app bundle or fake image involved.
@main
struct LaunchPresentationHarness {
    static func main() {
        func route(photoDelay: Double) -> LaunchPresentationState {
            var state = LaunchPresentationState()
            precondition(state.windowReady(at: 0.08))
            precondition(state.placeholderPresented(at: 0.10))
            precondition(!state.settleWithoutPhoto(hasPendingOpen: false, hasViewer: true))
            precondition(state.photoPresented(at: 0.20 + photoDelay))
            precondition(!state.photoPresented(at: 20)) // duplicate rejected
            return state
        }
        let fast = route(photoDelay: 0)
        let delayed = route(photoDelay: 1)
        precondition(fast.windowReadyAt == delayed.windowReadyAt)
        precondition(fast.placeholderPresentedAt == delayed.placeholderPresentedAt)
        precondition(abs(delayed.realPhotoPresentedAt! - fast.realPhotoPresentedAt! - 1) < 0.00001)
        precondition(delayed.outcome == .realPhotoPresented)

        var empty = LaunchPresentationState()
        precondition(empty.windowReady(at: 0.08))
        precondition(empty.settleWithoutPhoto(hasPendingOpen: false, hasViewer: false))
        precondition(empty.outcome == .noPhoto)
        precondition(empty.realPhotoPresentedAt == nil)
        // User think time and a late photo open cannot become cold launch.
        precondition(!empty.photoPresented(at: 20.0))
        precondition(!empty.placeholderPresented(at: 19.9))
        precondition(!empty.presentationUnavailable())
        precondition(empty.realPhotoPresentedAt == nil)

        var pending = LaunchPresentationState()
        precondition(!pending.settleWithoutPhoto(hasPendingOpen: true, hasViewer: false))
        precondition(pending.photoPresented(at: 1.2)) // observer installed before replay
        precondition(!pending.presentationUnavailable())

        var failed = LaunchPresentationState()
        precondition(failed.placeholderPresented(at: 0.1))
        precondition(failed.presentationUnavailable())
        precondition(failed.outcome == .photoUnavailable)
        precondition(failed.realPhotoPresentedAt == nil)
        precondition(!failed.photoPresented(at: 31))
        print("Launch endpoint harness: delayed-photo isolation, empty/late open, pending/early paint, deduplication and unavailable outcome passed")
    }
}
