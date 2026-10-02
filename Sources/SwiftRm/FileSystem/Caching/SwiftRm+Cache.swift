//
//  SwiftRm+Cache.swift
//  SwiftRm
//
//  Created by Liam Wittig on 07.04.26.
//

import Foundation
import SwiftData

@MainActor
class SwiftRmCache {
    private let container: ModelContainer
    private let context: ModelContext
    private static var refreshTask: Task<[RmItem], Error>?
    
    public let session: SwiftRmSession
    
    init(session: SwiftRmSession, container: ModelContainer? = nil) throws {
        if let container {
            self.container = container
        } else {
            Log.msg("Creating container")
            self.container = try Self.makeContainer()
        }
        
        
        self.context = self.container.mainContext
        self.session = session
    }
    
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([RmEntry.self])
        
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SwiftRm.sqlite")
        
        let config = ModelConfiguration(
            schema: schema,
            url: url
        )
        
        return try ModelContainer(for: schema, configurations: [config])
    }
    
    func load() throws -> [RmEntry] {
        try context.fetch(FetchDescriptor<RmEntry>())
    }
    
    func loadItems() async throws -> [RmItem] {
        if SwiftRmCache.refreshTask == nil {
            let softRefreshTask = Task{
                let rootHash = try await session.getRootHash()
                let cachedHash = RmRootCache.getRootHashCache()
                
                if rootHash == cachedHash {
                    Log.msg("Cache is up to date")
                    return mapEntriesToItems(entries: try load())
                } else {
                    RmRootCache.setRootHashCache(hash: "Invalid hash - refresh running")
                }
                
                let rootIndex = try await session.fetchIndex(rootHash, RmIndexEntry.rootFilename)
                let cachedItems = try load()
                
                var cacheMap: [String: RmEntry] = Dictionary(
                    cachedItems.map { ($0.uuid, $0) }, uniquingKeysWith: { _, new in new }
                )
                
                var syncedItems: [RmEntry] = []
                
                for indexItem in rootIndex {
                    try Task.checkCancellation()
                    
                    let uuid = indexItem.filename.replacingOccurrences(of: ".metadata", with: "")
                    
                    if let cached = cacheMap[uuid] {
                        
                        if cached.contentHash == indexItem.hash {
                            syncedItems.append(cached)
                        } else {
                            
                            Log.msg("Updating item \(uuid)")
                            let updated = try await updateItem(cached, with: indexItem)
                            syncedItems.append(updated)
                        }
                        
                        cacheMap.removeValue(forKey: uuid)
                        
                    } else {
                        Log.msg("Download new Item \(uuid)")
                        let newItem = try await saveNewItemByHash(index: indexItem)
                        syncedItems.append(newItem)
                    }
                }
                
                try Task.checkCancellation()
                
                try cleanUpCache(deadEntries: Array(cacheMap.values))
                
                RmRootCache.setRootHashCache(hash: rootHash)
                
                return mapEntriesToItems(entries: syncedItems)
            }
            
            // free up task and return result
            do{
                if SwiftRmCache.refreshTask == softRefreshTask { SwiftRmCache.refreshTask = nil }
                return try await softRefreshTask.value
            } catch {
                if SwiftRmCache.refreshTask == softRefreshTask { SwiftRmCache.refreshTask = nil }
                return [] // task failed
            }
        } else {
            return [] // task did not run
        }
    }
    
    func rebuildCache() async throws -> [RmItem]{
        if SwiftRmCache.refreshTask == nil { SwiftRmCache.refreshTask?.cancel() }
        let hardRefreshTask = Task{
            RmRootCache.setRootHashCache(hash: "Invalid hash - refresh running")
            let cachedItems = try load()
            try cleanUpCache(deadEntries: cachedItems)
            
            let rootHash = try await session.getRootHash()
            
            let rootIndex = try await session.fetchIndex(rootHash, RmIndexEntry.rootFilename)
            
            var syncedItems: [RmEntry] = []
            
            for indexItem in rootIndex {
                try Task.checkCancellation()
                
                let uuid = indexItem.filename.replacingOccurrences(of: ".metadata", with: "")
                
                
                Log.msg("Download new Item \(uuid)")
                let newItem = try await saveNewItemByHash(index: indexItem)
                syncedItems.append(newItem)
            }
            
            try Task.checkCancellation()
                        
            RmRootCache.setRootHashCache(hash: rootHash)
            
            return mapEntriesToItems(entries: syncedItems)
        }
        
        do{
            if SwiftRmCache.refreshTask == hardRefreshTask { SwiftRmCache.refreshTask = nil }
            return try await hardRefreshTask.value
        } catch {
            if SwiftRmCache.refreshTask == hardRefreshTask { SwiftRmCache.refreshTask = nil }
            return [] // task failed
        }
    }
    
    func updateItem(_ entry: RmEntry, with index: RmIndexEntry) async throws -> RmEntry {
        guard let metadata = try await session.fetchItem(index) else {
            throw SwiftRmError.invalidResponse
        }
        
        entry.contentHash = index.hash
        entry.visibleName = metadata.visibleName
        entry.parent = metadata.parent
        entry.lastModified = metadata.lastModified
        entry.type = metadata.type
        entry.pinned = metadata.pinned
        
        try context.save()
        return entry
    }
    
    func saveNewItemByHash(index: RmIndexEntry) async throws -> RmEntry {
        guard let metadata = try await session.fetchItem(index) else {
            throw SwiftRmError.invalidResponse
        }
        
        let uuid = index.filename.replacingOccurrences(of: ".metadata", with: "")
        
        let newItem = RmEntry(
            uuid: uuid,
            contentHash: index.hash,
            type: metadata.type, visibleName: metadata.visibleName,
            parent: metadata.parent,
            lastModified: metadata.lastModified,
            pinned: metadata.pinned
        )
        
        context.insert(newItem)
        try context.save()
        
        return newItem
    }
    
    func cleanUpCache(deadEntries: [RmEntry]) throws {
        for entry in deadEntries {
            Log.msg("Delete: \(entry.uuid)")
            context.delete(entry)
        }
        try context.save()
    }
    
    func mapEntriesToItems(entries: [RmEntry]) -> [RmItem] {
        entries.map {
            RmItem(
                hash: $0.uuid,
                visibleName: $0.visibleName,
                type: $0.type,
                parent: $0.parent,
                lastModified: $0.lastModified,
                pinned: $0.pinned
            )
        }
    }
}
