//
//  RmIndexEntry.swift
//  SwiftRm
//

import Foundation

public struct RmIndexEntry: Sendable {
    let hash: String
    let type: String
    let filename: String
    let subfiles: Int
    let size: Int

    static let rootFilename = "root.docSchema"

    var schemaFilename: String { filename + ".docSchema" }
}
