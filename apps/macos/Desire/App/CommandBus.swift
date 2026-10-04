import Combine
import Foundation

/// Typed, app-wide bus for `BrowserCommand`s (menu shortcuts, AI tool
/// actions). Replaces the old `NotificationCenter.post(name: .browserCommand)`
/// route: commands are now delivered through a typed publisher, so adding a
/// command with associated values is a compile-time change instead of an
/// `object as? BrowserCommand` cast that fails silently.
///
/// Deliberately a Combine subject (not an AsyncStream): `ContentView`
/// consumes it via `.onReceive`, which re-subscribes on every render with
/// FRESH closures — an AsyncStream task would capture the view struct once
/// and drive stale `@State` bindings.
@MainActor
final class CommandBus {
    static let shared = CommandBus()

    private let subject = PassthroughSubject<BrowserCommand, Never>()

    private init() {}

    /// Broadcasts a command to every subscribed window.
    func send(_ command: BrowserCommand) {
        subject.send(command)
    }

    /// Per-window subscription. ContentView consumes this via `.onReceive`.
    var publisher: AnyPublisher<BrowserCommand, Never> {
        subject.eraseToAnyPublisher()
    }
}
