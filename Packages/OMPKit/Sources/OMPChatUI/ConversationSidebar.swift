import SwiftUI
import OMPCore
import OMPDesign
import LocalAuthentication

// Official ChatGPT desktop single-column sidebar lives in MacShell.swift
// (`MacShellSidebar`). This typealias keeps the historic call sites.

public struct ConversationSidebar: View {
    public init() {}

    public var body: some View {
        MacShellSidebar()
    }
}

