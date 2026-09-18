//
//  KnowledgeCoding.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// KnowledgeCoding makes the stable JSON coders every stored knowledge value uses: sorted keys,
/// pretty printing, and ISO 8601 dates with milliseconds, so a file diff shows a change of content
/// and a stored date round-trips to the same instant.
public enum KnowledgeCoding {

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter().string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = formatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "Invalid ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
