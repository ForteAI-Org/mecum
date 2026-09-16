//
//  ChromiumAXTreeReadiness.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

/// Chromium lazily exposes web content when its container's role is queried.
/// Read roles individually before children; a bulk attribute request can leave
/// only browser toolbar nodes. The bounded walk also distinguishes native
/// Chrome dialogs from tabbed windows still waiting for renderer accessibility.
nonisolated enum ChromiumAXTreeReadiness {
    struct Reading {
        var hasTabs      = false
        var hasWebArea   = false
        var wasTruncated = false
    }

    static func supports(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return [
            "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
            "com.google.Chrome.canary", "org.chromium.Chromium",
        ].contains(bundleIdentifier)
    }

    static func read<Element: Hashable>(
        root    : Element,
        limit   : Int = 512,
        role    : (Element) -> String?,
        children: (Element) -> [Element]
    ) -> Reading {
        var pending = [root]
        var seen: Set<Element> = [root]
        var index = 0
        var reading = Reading()
        while index < pending.count, index < limit {
            let element = pending[index]
            index += 1
            let currentRole = role(element)
            if currentRole == "AXWebArea" {
                reading.hasWebArea = true
                return reading
            }
            if currentRole == "AXTabGroup" { reading.hasTabs = true }
            for child in children(element) where seen.insert(child).inserted {
                pending.append(child)
            }
        }
        reading.wasTruncated = index < pending.count
        return reading
    }
}
