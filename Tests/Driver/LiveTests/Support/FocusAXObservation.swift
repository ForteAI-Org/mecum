//
//  FocusAXObservation.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import AppKit
import Dispatch
import Foundation
import PrivateSymbols

/// Read-only AX evidence. Missing values, IPC errors and identity conversion
/// failures stay distinct; a main window never substitutes for a focused one.
nonisolated struct FocusAXObservation: Codable {
    let phase: String
    let processID: Int32
    let startedAtUptimeNanoseconds: UInt64
    let durationNanoseconds: UInt64
    let timeoutCode: Int32
    let attributeCode: Int32
    let valueKind: String
    let mappingCode: Int32?
    let windowNumber: Int?

    @MainActor
    static func read(_ pid: Int32, phase: String) -> Self {
        let started = DispatchTime.now().uptimeNanoseconds
        let application = AXUIElementCreateApplication(pid)
        let timeout = AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        var mappingCode: Int32?
        var windowNumber: Int?
        var kind = "missing"
        if let value {
            kind = CFGetTypeID(value) == AXUIElementGetTypeID() ? "AXUIElement" : "unexpectedType"
            if kind == "AXUIElement" {
                typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
                if let getWindow = SymbolTable.shared.function(.axUIElementGetWindow, as: GetWindow.self) {
                    var number: CGWindowID = 0
                    let code = getWindow(unsafeDowncast(value, to: AXUIElement.self), &number)
                    mappingCode = code.rawValue
                    if code == .success, number != 0 { windowNumber = Int(number) }
                } else { kind = "mappingSymbolUnavailable" }
            }
        }
        return Self(phase: phase, processID: pid, startedAtUptimeNanoseconds: started,
                    durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started,
                    timeoutCode: timeout.rawValue, attributeCode: error.rawValue, valueKind: kind,
                    mappingCode: mappingCode, windowNumber: windowNumber)
    }
}
