//
//  PhotoshopDocumentCatalog.swift
//  AgentSeatKit
//

import Foundation

/// A complete, nonce-bound snapshot of the scoped Photoshop documents. IDs
/// distinguish tabs sharing one AX window; a window title cannot prove closure.
nonisolated struct PhotoshopDocumentCatalog {

    struct Document: Equatable {
        let id  : Int
        let name: String
        // Keep the vendor path: Foundation can standardize /private/tmp to
        // /tmp, which is not a byte-identical Photoshop File.fsName.
        let nativePath: String?

        var url: URL? { nativePath.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    }

    enum Failure: Error, Equatable {
        case invalidSnapshot
    }

    let documents: [Document]
    let activeID : Int?

    var activeDocument: Document? { documents.first { $0.id == activeID } }

    init(parsing source: String, token: String) throws {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false),
              header.count == 4, header[0] == "MECUM_DOCUMENTS", header[1] == token,
              let count = Int(header[3]), (0...2).contains(count), lines.count == count + 2,
              lines.last == "MECUM_DONE\t\(token)"
        else { throw Failure.invalidSnapshot }
        let active = header[2] == "none" ? nil : Int(header[2])
        guard header[2] == "none" || active.map({ $0 > 0 }) == true else { throw Failure.invalidSnapshot }
        var records: [Document] = []
        for line in lines.dropFirst().dropLast() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let id = Int(fields[0]), id > 0,
                  let name = String(fields[1]).removingPercentEncoding, !name.isEmpty,
                  let path = String(fields[2]).removingPercentEncoding,
                  path.isEmpty || path.hasPrefix("/")
            else { throw Failure.invalidSnapshot }
            records.append(Document(id: id, name: name, nativePath: path.isEmpty ? nil : path))
        }
        guard Set(records.map(\.id)).count == count,
              (count == 0 ? active == nil : records.contains(where: { $0.id == active }))
        else { throw Failure.invalidSnapshot }
        documents = records
        activeID = active
    }

    /// Only one new, active and unsaved document alongside the unchanged seed
    /// can be owned by the test's single New Document action.
    func createdDocument(since baseline: PhotoshopDocumentCatalog) -> Document? {
        guard baseline.documents.count == 1, let seed = baseline.documents.first,
              seed.url != nil, documents.count == 2, documents.contains(seed),
              let created = documents.first(where: { $0.id != seed.id }),
              created.url == nil, activeID == created.id
        else { return nil }
        return created
    }
}
