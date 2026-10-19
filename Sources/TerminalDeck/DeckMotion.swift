import AppKit
import SwiftUI

/// Input modality describes an interaction, not the lifetime of a running task.
/// Never use it to stop execution indicators or the agreed deletion particles.
enum DeckInputSource: Equatable {
    case pointer, keyboard, automatic
    @MainActor static var current: DeckInputSource {
        switch NSApp.currentEvent?.type {
        case .keyDown, .keyUp, .flagsChanged: return .keyboard
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: return .pointer
        default: return .automatic
        }
    }
    @MainActor func animation(entering: Bool) -> Animation? {
        guard self == .pointer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        return .timingCurve(0.23, 1, 0.32, 1, duration: entering ? 0.2 : 0.15)
    }
}
