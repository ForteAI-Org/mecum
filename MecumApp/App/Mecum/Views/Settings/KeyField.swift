//
//  KeyField.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// A secure key field with a reveal toggle, a link to where keys are made,
/// and a clear statement of what happens to the key.
struct KeyField: View {

    let title: String

    @Binding
    var text: String

    let consoleURL: URL?

    @State
    private var reveals = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            HStack(spacing: 8) {
                Group {
                    if reveals {
                        TextField(
                            title,
                            text  : $text,
                            prompt: Text("Paste your key here")
                        )
                    } else {
                        SecureField(
                            title,
                            text  : $text,
                            prompt: Text("Paste your key here")
                        )
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(
                    .body,
                    design: .monospaced
                ))
                Button(reveals ? "Hide" : "Show") { reveals.toggle() }
                    .controlSize(.small)
                if !text.isEmpty {
                    Button(
                        "Clear",
                        role: .destructive
                    ) { text = "" }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                Label(
                    text.isEmpty ? "No key stored" : "Key stored in your keychain",
                    systemImage: text.isEmpty ? "key.slash" : "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                if let consoleURL {
                    Link(
                        "Get a key…",
                        destination: consoleURL
                    )
                    .font(.caption)
                }
            }
        }
    }
}
