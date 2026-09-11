//
//  PhysicalDisplayRecoveryPolicy.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// PhysicalDisplayRecoveryPolicy decides whether the kit may put the person's
/// displays back where it found them. It restores only origins of displays that
/// are still identical to the baseline: a hot plug or a resolution change means
/// the person rearranged their own desk, and writing the old topology back over
/// that would be the kit deciding for them.
public enum PhysicalDisplayRecoveryPolicy {

    /// canRestore is true only when the display set is unchanged, the baseline
    /// main display still sits at the origin, and every display kept its size.
    public static func canRestore(
        baseline     : [CGDirectDisplayID: CGRect],
        current      : [CGDirectDisplayID: CGRect],
        mainDisplayID: CGDirectDisplayID
    ) -> Bool {
        
        guard !baseline.isEmpty, baseline[mainDisplayID]?.origin == .zero,
              Set(baseline.keys) == Set(current.keys)
        else { return false }
        
        return baseline.allSatisfy { id, bounds in
            
            guard let now = current[id],
                    !bounds.isEmpty,
                    !now.isEmpty
            else { return false }
            
            return bounds.width == now.width && bounds.height == now.height
        }
    }
}
