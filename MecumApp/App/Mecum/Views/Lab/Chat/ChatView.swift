//
//  ChatView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

/// The app's one screen: the message log, a floating live monitor of the
/// adopted window in the bottom-right corner, and a composer bar with the
/// model controls. Return sends, Option-Return inserts a newline. Images sit
/// in fixed-height slots so resizing never reflows the log.
///
/// It is shown before any seat exists, so the monitor and the titles are
/// written for a session that is nil and for one holding nothing yet.
struct ChatView: View {

    @Bindable
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(
                        .horizontal,
                        20
                    )
                    .padding(
                        .top,
                        16
                    )
                    // Room for the floating monitor so the last bubble is never under it.
                    .padding(
                        .bottom,
                        200
                    )
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation {
                            proxy.scrollTo(
                                last.id,
                                anchor: .bottom
                            )
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let session = model.session {
                    FloatingMonitor(
                        session  : session,
                        isRunning: model.isBusy
                    )
                    .padding(16)
                }
            }

            LabComposerBar(model: model)
                // The composer carries the model picker, so its appearing is what asks for the checks.
                .task { model.settings.refresh() }
        }
        .navigationTitle(model.session?.app?.name ?? "Mecum")
        .navigationSubtitle(model.session?.target?.title ?? "")
    }
}
