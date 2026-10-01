//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 07.04.26.
//

import Foundation
import SwiftData

@Model
class RmEntry {
    var uuid: String          // identity
    var contentHash: String   // version
     public var visibleName: String
     public var type: String        // "CollectionType" or "DocumentType"
     public var parent: String?
     public var lastModified: String?
    public var pinned: Bool = false
    
    init(uuid: String, contentHash: String, type: String, visibleName: String, parent: String?, lastModified: String?, pinned: Bool) {
        self.uuid = uuid
        self.contentHash = contentHash
        self.type = type
        self.visibleName = visibleName
        self.parent = parent
        self.lastModified = lastModified
        self.pinned = pinned
    }
    
}
