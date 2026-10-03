//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 06.04.26.
//

import Foundation


@Observable
@MainActor
public class SwiftRmFileSystem{
    public var loading = false
    public var syncingCount = 0
    public var syncing: Bool { syncingCount > 0 }

    public let session: SwiftRmSession
    public let root =  RmFolder(hash: "", visibleName: "My files", parent: nil, pinned: false)
    public let trash =  RmFolder(hash: "trash", visibleName: "Trash", parent: "", pinned: false)
    public var items: [RmItem] = []
    
    public var pinnedFiles: [RmDocument] {
        self.root.allDocuments.filter(\.pinned)
    }
    public var pinnedFolders: [RmFolder] {
        self.root.allFolders.filter(\.pinned)
    }

    init(session: SwiftRmSession) throws{
        self.session = session
        Task{
            loading = true
            do { try await loadFiles() }
            catch { Log.msg("loadFiles failed: \(error)", level: .error) }
            loading = false
        }
    }

    public func loadFiles() async throws {
        self.items = try await SwiftRmCache(session: session).loadItems()
        try await buildTree()
    }
    
    public func rebuildCache() async throws {
        self.items = try await SwiftRmCache(session: session).rebuildCache()
        try await buildTree()
    }

    private func withSync(_ work: @escaping @Sendable () async throws -> Void) {
        syncingCount += 1
        Task {
            defer { Task { @MainActor in syncingCount -= 1 } }
            do { try await work() }
            catch { Log.msg("sync operation failed: \(error)", level: .error) }
        }
    }

    public func move(item: RmDocument, from source: RmFolder, to destination: RmFolder) {
        source.documents.removeAll { $0.hash == item.hash }
        destination.documents.append(item)
        syncMove(hash: item.hash, to: destination.hash)
    }

    public func move(folder: RmFolder, from source: RmFolder, to destination: RmFolder) {
        source.folders.removeAll { $0.hash == folder.hash }
        destination.folders.append(folder)
        syncMove(hash: folder.hash, to: destination.hash)
    }

    private func syncMove(hash: String, to destHash: String) {
        withSync { [session] in
            try await session.moveItem(hash, destHash)
            await MainActor.run { RmRootCache.setRootHashCache(hash: "") }
        }
    }

    public func trash(item: RmDocument, from source: RmFolder) {
        move(item: item, from: source, to: trash)
    }

    public func trash(folder: RmFolder, from source: RmFolder) {
        move(folder: folder, from: source, to: trash)
    }

    public func upload(name: String, data: Data, to parent: RmFolder) {
        let placeholder = RmDocument(hash: UUID().uuidString.lowercased(), visibleName: name, parent: parent.hash, lastModified: String(Int64(Date().timeIntervalSince1970 * 1000)), pinned: false)
        parent.documents.append(placeholder)

        let parentHash = parent.hash
        withSync { [session] in
            try await session.uploadDocument(name, data, parentHash)
            await MainActor.run { RmRootCache.setRootHashCache(hash: "") }
        }
    }

    public func createFolder(name: String, in parent: RmFolder) {
        let placeholder = RmFolder(hash: UUID().uuidString.lowercased(), visibleName: name, parent: parent.hash, pinned: false)
        parent.folders.append(placeholder)

        let parentHash = parent.hash
        withSync { [session] in
            try await session.createFolder(name, parentHash)
            await MainActor.run { RmRootCache.setRootHashCache(hash: "") }
        }
    }

    public func inspectDocument(_ doc: RmDocument) async throws -> [(name: String, content: String)] {
        let (rootEntry, subIndex) = try await resolveDocument(doc)

        var results: [(name: String, content: String)] = []
        results.append((name: "root entry", content: "\(rootEntry.hash):\(rootEntry.type):\(rootEntry.filename):\(rootEntry.subfiles):\(rootEntry.size)"))

        results.append((name: "sub-index", content: subIndex.map {
            "\($0.hash):\($0.type):\($0.filename):\($0.subfiles):\($0.size)"
        }.joined(separator: "\n")))

        for entry in subIndex {
            if entry.filename.hasSuffix(".metadata") || entry.filename.hasSuffix(".content") {
                let raw = try await session.fetchBlobText(entry.hash, entry.filename)
                results.append((name: entry.filename, content: raw))
            }
        }
        return results
    }

    public func downloadPDF(_ doc: RmDocument) async throws -> Data {
        let (_, subIndex) = try await resolveDocument(doc)
        guard let pdfEntry = subIndex.first(where: { $0.filename.hasSuffix(".pdf") || $0.filename.hasSuffix(".epub") }) else {
            throw SwiftRmError.notFound
        }
        return try await session.downloadBlob(pdfEntry.hash, pdfEntry.filename)
    }

    public func downloadNotebookPages(_ doc: RmDocument) async throws -> [RmFile] {
        let (_, subIndex) = try await resolveDocument(doc)

        // read correct page order from the .content file
        var order: [String] = []
        if let c = subIndex.first(where: { $0.filename.hasSuffix(".content") }) {
            let data = try await session.downloadBlob(c.hash, c.filename)
            order = Self.pageOrder(from: data)
        }

        // download pages and remember UUIDs
        let rmEntries = subIndex.filter { $0.filename.hasSuffix(".rm") }
        let pages = try await withThrowingTaskGroup(of: (String, RmFile).self) { group in
            for entry in rmEntries {
                let uuid = ((entry.filename as NSString).lastPathComponent as NSString).deletingPathExtension
                group.addTask { [session] in
                    let data = try await session.downloadBlob(entry.hash, entry.filename)
                    return (uuid, try RmFileParser.parse(data))
                }
            }
            var result: [(String, RmFile)] = []
            for try await p in group { result.append(p) }
            return result
        }

        // order according to list
        return pages
            .sorted { (order.firstIndex(of: $0.0) ?? .max) < (order.firstIndex(of: $1.0) ?? .max) }
            .map(\.1)
    }

    private static func pageOrder(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let ids = json["pages"] as? [String] { return ids }
        if let c = json["cPages"] as? [String: Any], let pages = c["pages"] as? [[String: Any]] {
            return pages.compactMap { $0["id"] as? String }
        }
        return []
    }

    public func documentType(_ doc: RmDocument) async throws -> String {
        let (_, subIndex) = try await resolveDocument(doc)
        if subIndex.contains(where: { $0.filename.hasSuffix(".pdf") }) { return "pdf" }
        if subIndex.contains(where: { $0.filename.hasSuffix(".epub") }) { return "epub" }
        if subIndex.contains(where: { $0.filename.hasSuffix(".rm") }) { return "notebook" }
        return "unknown"
    }

    private func resolveDocument(_ doc: RmDocument) async throws -> (RmIndexEntry, [RmIndexEntry]) {
        let rootHash = try await session.getRootHash()
        let rootIndex = try await session.fetchIndex(rootHash, RmIndexEntry.rootFilename)
        guard let rootEntry = rootIndex.first(where: { $0.filename == doc.hash }) else {
            throw SwiftRmError.notFound
        }
        let subIndex = try await session.fetchIndex(rootEntry.hash, rootEntry.schemaFilename)
        return (rootEntry, subIndex)
    }

    public func buildTree() async throws {
        root.documents = []
        root.folders = []
        trash.documents = []
        trash.folders = []

        var folderMap: [String: RmFolder] = [
              "": root,
              "trash": trash
          ]

        for item in items where item.isFolder {
            let folder = RmFolder(hash: item.hash ?? "", visibleName: item.visibleName, parent: item.parent, pinned: item.pinned)
            folderMap[item.hash ?? ""] = folder
        }

        for item in items where item.isDocument {
            let doc = RmDocument(hash: item.hash ?? "", visibleName: item.visibleName, parent: item.parent, lastModified: item.lastModified, pinned: item.pinned)
            let parentFolder = folderMap[item.parent ?? ""] ?? root
            parentFolder.documents.append(doc)
        }

        for folder in folderMap.values where folder.hash != "" {
            let parentFolder = folderMap[folder.parent ?? ""] ?? root
            if folder.hash != "trash" {
                parentFolder.folders.append(folder)
            }
        }
    }
}
