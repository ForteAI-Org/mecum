//
//  StructuralDigest.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// StructuralDigest is a deterministic, process-stable hash of a canonical string: FNV-1a over its
/// bytes, as hexadecimal. It is a search hint and a conflict report's fingerprint, never an
/// identity: two equal digests prompt a comparison of the content, they do not replace it.
/// Package-visible: the SQLite adapter fingerprints conflict reports with it.
package enum StructuralDigest {

    package static func fnv1a(_ canonical: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// CanonicalText renders one optional field for a digest so that NULL, empty text and a separator
/// inside a value stay apart: a NULL marker, or the field's byte length before its text.
enum CanonicalText {

    static func field(_ text: String?) -> String {
        guard let text else { return "~" }
        return "\(text.utf8.count):\(text)"
    }
}
