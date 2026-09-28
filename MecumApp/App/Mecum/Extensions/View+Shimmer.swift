//
//  View+Shimmer.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI

extension View {

    /// Marks the view as loading with a passing band of light; see `Shimmer`.
    func shimmering() -> some View { modifier(Shimmer()) }
}
