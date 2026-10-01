//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 07.04.26.
//

import Foundation


@Observable
public class RmFolder: Identifiable, Equatable, Hashable {
    public static func == (lhs: RmFolder, rhs: RmFolder) -> Bool {
        lhs.hash == rhs.hash
    }
    public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    
    public let hash: String
    public let visibleName: String
    public let parent: String?
    public var documents: [RmDocument] = []
    public var folders: [RmFolder] = []
    public var pinned: Bool
    
    init(hash: String, visibleName: String, parent: String?, pinned: Bool) {
        self.hash = hash
        self.visibleName = visibleName
        self.parent = parent
        self.pinned = pinned
    }
}

