//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 07.04.26.
//

import Foundation

public struct RmItem: Codable, Sendable {
    public var hash: String?
    public let visibleName: String
    public let type: String        // "CollectionType" or "DocumentType"
    public let parent: String?
    public let lastModified: String?
    
    public var isFolder: Bool { type == "CollectionType" }
    public var isDocument: Bool { type == "DocumentType" }
    
    public var pinned: Bool

    enum CodingKeys: String, CodingKey {
        case hash, visibleName, type, parent, lastModified, pinned
    }
}

extension RmItem {
    // Declared in an extension so the memberwise initializer is kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        visibleName = try c.decode(String.self, forKey: .visibleName)
        type = try c.decode(String.self, forKey: .type)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}
