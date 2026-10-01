//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 05.04.26.
//

import Foundation
import CryptoKit
import CoreGraphics


extension SwiftRmSession {

    public static func connect(config: RemarkableConfig = .remarkableCloud) async throws -> SwiftRmSession {
        let userToken = try await SwiftRmToken(config: config)

        return SwiftRmSession (
            fetchMetadata: { hash, filename in
                try await SwiftRmNetwork.request(config.blobUrl + hash, userToken: userToken, filename: filename)
            },
            fetchIndex: { hash, filename in
                try await fetchIndex(hash: hash, filename: filename, userToken: userToken, config: config)
            },
            fetchBlobText: { hash, filename in
                try await SwiftRmNetwork.requestText(config.blobUrl + hash, userToken: userToken, filename: filename)
            },
            downloadBlob: { hash, filename in
                try await SwiftRmNetwork.requestData(config.blobUrl + hash, userToken: userToken, filename: filename)
            },
            deleteSomething: { _ in },
            moveItem: { uuid, newParentUUID in
                try await moveItem(uuid: uuid, newParentUUID: newParentUUID, userToken: userToken, config: config)
            },
            uploadDocument: { name, fileData, parentUUID in
                try await uploadDocument(name: name, fileData: fileData, parentUUID: parentUUID, userToken: userToken, config: config)
            },
            createFolder: { name, parentUUID in
                try await createFolder(name: name, parentUUID: parentUUID, userToken: userToken, config: config)
            },
            getRootHash: {
                let (hash, _) = try await getRootHashAndGeneration(userToken: userToken, config: config)
                return hash
            },
            loadItems: {
                try await loadItems(userToken: userToken, config: config)
            },
            fetchItem: { entry in
                try await fetchItem(entry: entry, userToken: userToken, config: config)
            }
        )
    }


    // MARK: - Index parsing

    private static func fetchIndex(hash: String, filename: String, userToken: SwiftRmToken, config: RemarkableConfig) async throws -> [RmIndexEntry] {
        let (entries, _) = try await fetchSchemaAndIndex(hash: hash, filename: filename, userToken: userToken, config: config)
        return entries
    }

    /// Returns the parsed entries and the schema version string from the index file header.
    private static func fetchSchemaAndIndex(hash: String, filename: String, userToken: SwiftRmToken, config: RemarkableConfig) async throws -> ([RmIndexEntry], String) {
        let text: String = try await SwiftRmNetwork.requestText(config.blobUrl + hash, userToken: userToken, filename: filename)

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return ([], "4") }

        let schemaVersion = lines.removeFirst()

        if schemaVersion == "4" && !lines.isEmpty {
            lines.removeFirst() // metadata line: "0:.:count:totalSize"
        }

        let entries = lines.compactMap { line -> RmIndexEntry? in
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 5 else { return nil }
            return RmIndexEntry(
                hash: String(parts[0]),
                type: String(parts[1]),
                filename: String(parts[2]),
                subfiles: Int(parts[3]) ?? 0,
                size: Int(parts[4]) ?? 0
            )
        }
        return (entries, schemaVersion)
    }


    // MARK: - Load items

    private static func loadItems(userToken: SwiftRmToken, config: RemarkableConfig) async throws -> [RmItem] {
        let (rootHash, _) = try await getRootHashAndGeneration(userToken: userToken, config: config)
        let rootIndex = try await fetchIndex(hash: rootHash, filename: RmIndexEntry.rootFilename, userToken: userToken, config: config)

        return try await withThrowingTaskGroup(of: RmItem?.self) { group in
            var active = 0
            var iterator = rootIndex.makeIterator()
            var results: [RmItem] = []

            while active < 20, let entry = iterator.next() {
                group.addTask { try await fetchItem(entry: entry, userToken: userToken, config: config) }
                active += 1
            }

            for try await result in group {
                if let result { results.append(result) }
                if let entry = iterator.next() {
                    group.addTask { try await fetchItem(entry: entry, userToken: userToken, config: config) }
                }
            }

            return results
        }
    }

    private static func fetchItem(entry: RmIndexEntry, userToken: SwiftRmToken, config: RemarkableConfig) async throws -> RmItem? {
        let subIndex = try await fetchIndex(hash: entry.hash, filename: entry.schemaFilename, userToken: userToken, config: config)
        guard let metaFile = subIndex.first(where: { $0.filename.hasSuffix(".metadata") }) else {
            return nil
        }
        var metadata: RmItem = try await SwiftRmNetwork.request(config.blobUrl + metaFile.hash, userToken: userToken, filename: metaFile.filename)
        let uuid = metaFile.filename.replacingOccurrences(of: ".metadata", with: "")
        metadata.hash = uuid
        return metadata
    }

    private static func getRootHashAndGeneration(userToken: SwiftRmToken, config: RemarkableConfig) async throws -> (String, Int) {
        let root: RmRoot = try await SwiftRmNetwork.request(config.rootGet, userToken: userToken)
        return (root.hash, root.generation)
    }


    // MARK: - Index building

    /// Builds a V4 root index file and returns (fileData, blobHash).
    /// The blobHash for V4 is SHA256 of the file bytes — the URL the blob is uploaded to.
    private static func buildRootIndex(entries: [RmIndexEntry]) -> (data: Data, hash: String) {
        let totalSize = entries.reduce(0) { $0 + $1.size }
        var lines: [String] = [
            "4",
            "0:.:\(entries.count):\(totalSize)"
        ]
        for entry in entries {
            lines.append("\(entry.hash):0:\(entry.filename):\(entry.subfiles):\(entry.size)")
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let hash = SHA256.hash(data: data).hexString
        return (data, hash)
    }

    /// Builds a V3 sub-document index file. Sub-doc indexes always use V3.
    /// Returns (fileData, blobHash) where blobHash = hashEntries (SHA256 of concatenated raw entry hashes).
    private static func buildSubDocIndex(entries: [RmIndexEntry]) -> (data: Data, hash: String) {
        var lines: [String] = ["3"]
        for entry in entries {
            lines.append("\(entry.hash):\(entry.type):\(entry.filename):\(entry.subfiles):\(entry.size)")
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let hash = hashEntries(entries)
        return (data, hash)
    }

    private static func hashEntries(_ entries: [RmIndexEntry]) -> String {
        let sorted = entries.sorted { $0.filename < $1.filename }
        var hasher = SHA256()
        for entry in sorted {
            if let raw = Data(hexString: entry.hash) {
                hasher.update(data: raw)
            }
        }
        return hasher.finalize().hexString
    }

    private static func updateRoot(hash: String, generation: Int, userToken: SwiftRmToken, config: RemarkableConfig) async throws {
        var currentGeneration = generation
        for _ in 0..<10 {
            do {
                let result = try await SwiftRmNetwork.putRoot(
                    hash: hash,
                    generation: currentGeneration,
                    userToken: userToken,
                    config: config
                )
                currentGeneration = result.generation
                return
            } catch SwiftRmError.generationConflict {
                let (_, latestGeneration) = try await getRootHashAndGeneration(userToken: userToken, config: config)
                currentGeneration = latestGeneration
            }
        }
        throw SwiftRmError.generationConflict
    }


    // MARK: - Move

    private static func moveItem(uuid: String, newParentUUID: String, userToken: SwiftRmToken, config: RemarkableConfig) async throws {
        let (currentRootHash, _) = try await getRootHashAndGeneration(userToken: userToken, config: config)
        let currentRootIndex = try await fetchIndex(hash: currentRootHash, filename: RmIndexEntry.rootFilename, userToken: userToken, config: config)
        guard let docEntry = currentRootIndex.first(where: { $0.filename == uuid }) else {
            throw SwiftRmError.notFound
        }

        let subIndex = try await fetchIndex(hash: docEntry.hash, filename: docEntry.schemaFilename, userToken: userToken, config: config)
        guard let metaEntry = subIndex.first(where: { $0.filename.hasSuffix(".metadata") }) else {
            throw SwiftRmError.metaDataNotFound
        }

        var metadata: RmMetadata = try await SwiftRmNetwork.request(config.blobUrl + metaEntry.hash, userToken: userToken, filename: metaEntry.filename)
        metadata.parent = newParentUUID
        metadata.version += 1
        metadata.lastModified = String(Int64(Date().timeIntervalSince1970 * 1000))
        metadata.metadataModified = true

        let metaData = try JSONEncoder().encode(metadata)
        let newMetaHash = SHA256.hash(data: metaData).hexString

        try await SwiftRmNetwork.uploadBlob(
            config.blobUrl + newMetaHash,
            filename: uuid + ".metadata",
            body: metaData,
            userToken: userToken
        )

        let updatedSubIndex = subIndex.map { entry -> RmIndexEntry in
            entry.filename.hasSuffix(".metadata")
                ? RmIndexEntry(hash: newMetaHash, type: entry.type, filename: entry.filename, subfiles: entry.subfiles, size: metaData.count)
                : entry
        }

        let (docIndexData, newDocHash) = buildSubDocIndex(entries: updatedSubIndex)

        try await SwiftRmNetwork.uploadBlob(
            config.blobUrl + newDocHash,
            filename: uuid + ".docSchema",
            body: docIndexData,
            userToken: userToken
        )

        let (rootHash, generation) = try await getRootHashAndGeneration(userToken: userToken, config: config)
        let rootIndex = try await fetchIndex(hash: rootHash, filename: RmIndexEntry.rootFilename, userToken: userToken, config: config)

        let updatedRootIndex = rootIndex.map { entry -> RmIndexEntry in
            entry.filename == uuid
                ? RmIndexEntry(hash: newDocHash, type: entry.type, filename: entry.filename, subfiles: entry.subfiles, size: entry.size)
                : entry
        }
        let (rootIndexData, newRootHash) = buildRootIndex(entries: updatedRootIndex)

        try await SwiftRmNetwork.uploadBlob(
            config.blobUrl + newRootHash,
            filename: RmIndexEntry.rootFilename,
            body: rootIndexData,
            userToken: userToken
        )

        try await updateRoot(hash: newRootHash, generation: generation, userToken: userToken, config: config)
    }


    // MARK: - Upload helpers

    private struct FileBlob {
        let filename: String
        let data: Data
        let hash: String

        init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
            self.hash = SHA256.hash(data: data).hexString
        }
    }

    private static func uploadBlobsAndAppendToRoot(
        id: String,
        blobs: [FileBlob],
        userToken: SwiftRmToken,
        config: RemarkableConfig
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for blob in blobs {
                group.addTask {
                    try await SwiftRmNetwork.uploadBlob(
                        config.blobUrl + blob.hash,
                        filename: blob.filename,
                        body: blob.data,
                        userToken: userToken
                    )
                }
            }
            try await group.waitForAll()
        }

        let subEntries = blobs.map {
            RmIndexEntry(hash: $0.hash, type: "0", filename: $0.filename, subfiles: 0, size: $0.data.count)
        }
        let (docIndexData, docHash) = buildSubDocIndex(entries: subEntries)

        try await SwiftRmNetwork.uploadBlob(
            config.blobUrl + docHash,
            filename: id + ".docSchema",
            body: docIndexData,
            userToken: userToken
        )

        let (rootHash, generation) = try await getRootHashAndGeneration(userToken: userToken, config: config)
        let rootIndex = try await fetchIndex(hash: rootHash, filename: RmIndexEntry.rootFilename, userToken: userToken, config: config)

        var newRootEntries = rootIndex
        let totalSize = blobs.reduce(0) { $0 + $1.data.count }
        newRootEntries.append(RmIndexEntry(hash: docHash, type: "0", filename: id, subfiles: blobs.count, size: totalSize))

        let (rootIndexData, newRootHash) = buildRootIndex(entries: newRootEntries)

        try await SwiftRmNetwork.uploadBlob(
            config.blobUrl + newRootHash,
            filename: RmIndexEntry.rootFilename,
            body: rootIndexData,
            userToken: userToken
        )

        try await updateRoot(hash: newRootHash, generation: generation, userToken: userToken, config: config)
    }


    // MARK: - Upload document

    private static func uploadDocument(name: String, fileData: Data, parentUUID: String, userToken: SwiftRmToken, config: RemarkableConfig) async throws {
        let id = UUID().uuidString.lowercased()
        let rawExt = URL(fileURLWithPath: name).pathExtension.lowercased()
        let ext = rawExt.isEmpty ? "pdf" : rawExt
        let pageCount = pdfPageCount(fileData)
        Log.msg("upload: start \(name) ext=\(ext) id=\(id) parent=\(parentUUID) size=\(fileData.count) pages=\(pageCount)")

        let metadataJSON = RmMetadata(
            visibleName: name,
            type: "DocumentType",
            parent: parentUUID,
            lastModified: String(Int64(Date().timeIntervalSince1970 * 1000)),
            lastOpened: "",
            lastOpenedPage: 0,
            version: 0,
            metadataModified: false,
            pinned: false,
            synced: true,
            modified: false,
            deleted: false
        )
        let contentJSON = RmContent(fileType: ext, originalPageCount: pageCount, pageCount: pageCount, sizeInBytes: fileData.count)

        let blobs = [
            FileBlob(filename: id + ".content",  data: try JSONEncoder().encode(contentJSON)),
            FileBlob(filename: id + ".metadata", data: try JSONEncoder().encode(metadataJSON)),
            FileBlob(filename: id + ".pagedata", data: Data(String(repeating: "\n", count: pageCount).utf8)),
            FileBlob(filename: id + "." + ext,   data: fileData),
        ]

        try await uploadBlobsAndAppendToRoot(id: id, blobs: blobs, userToken: userToken, config: config)
        Log.msg("upload: done")
    }

    private static func pdfPageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { return 0 }
        return pdf.numberOfPages
    }


    // MARK: - Create folder

    private static func createFolder(name: String, parentUUID: String, userToken: SwiftRmToken, config: RemarkableConfig) async throws {
        let id = UUID().uuidString.lowercased()
        Log.msg("createFolder: \(name) id=\(id) parent=\(parentUUID)")

        let metadataJSON = RmMetadata(
            visibleName: name,
            type: "CollectionType",
            parent: parentUUID,
            lastModified: String(Int64(Date().timeIntervalSince1970 * 1000)),
            lastOpened: "",
            lastOpenedPage: 0,
            version: 0,
            metadataModified: false,
            pinned: false,
            synced: true,
            modified: false,
            deleted: false
        )

        let blobs = [
            FileBlob(filename: id + ".content",  data: Data("{}".utf8)),
            FileBlob(filename: id + ".metadata", data: try JSONEncoder().encode(metadataJSON)),
        ]

        try await uploadBlobsAndAppendToRoot(id: id, blobs: blobs, userToken: userToken, config: config)
        Log.msg("createFolder: done")
    }

}


public struct RemarkableConfig: Sendable {
    public let deviceTokenURL: String
    public let userTokenURL: String
    public let blobUrl: String
    public let rootGet: String
    public let rootPut: String
    public let keychainKey: String

    static let defaultDeviceDesc = "desktop-windows"

    public static let remarkableCloud = RemarkableConfig(
        deviceTokenURL: "https://webapp-prod.cloud.remarkable.engineering/token/json/2/device/new",
        userTokenURL:   "https://webapp-prod.cloud.remarkable.engineering/token/json/2/user/new",
        blobUrl:        "https://internal.cloud.remarkable.com/sync/v3/files/",
        rootGet:        "https://internal.cloud.remarkable.com/sync/v4/root",
        rootPut:        "https://internal.cloud.remarkable.com/sync/v3/root",
        keychainKey:    "remarkableDeviceToken"
    )

    public static func rmfakecloud(host: String) -> RemarkableConfig {
        let base = "https://\(host)"
        return RemarkableConfig(
            deviceTokenURL: "\(base)/token/json/2/device/new",
            userTokenURL:   "\(base)/token/json/2/user/new",
            blobUrl:        "\(base)/sync/v3/files/",
            rootGet:        "\(base)/sync/v4/root",
            rootPut:        "\(base)/sync/v3/root",
            keychainKey:    "rmDeviceToken_\(host)"
        )
    }
}


extension SwiftRm {
    public static func registerDevice(token: String, config: RemarkableConfig = .remarkableCloud) async throws -> String {
        return try await SwiftRmNetwork.registerDevice(token: token, config: config)
    }
}


extension Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
