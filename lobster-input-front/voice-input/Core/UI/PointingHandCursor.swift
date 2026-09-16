import AppKit
import SwiftUI

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                    isHovering = true
                } else {
                    popCursorIfNeeded()
                }
            }
            .onDisappear {
                popCursorIfNeeded()
            }
    }

    private func popCursorIfNeeded() {
        if isHovering {
            NSCursor.pop()
            isHovering = false
        }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
