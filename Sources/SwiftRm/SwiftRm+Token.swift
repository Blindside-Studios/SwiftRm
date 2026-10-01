//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 07.04.26.
//

import Foundation

actor SwiftRmToken {
    private var currentToken: String
    private let deviceToken: String
    private let userTokenURL: String

    init(config: RemarkableConfig) async throws {
        guard let deviceToken = SwiftRmKeychain.load(config.keychainKey) else {
            throw SwiftRmError.notRegistered
        }
        self.deviceToken = deviceToken
        self.userTokenURL = config.userTokenURL
        self.currentToken = try await SwiftRmNetwork.renewUserToken(deviceToken: deviceToken, url: config.userTokenURL)
    }

    public func validToken() async throws -> String {
        if isExpired(currentToken) {
            currentToken = try await SwiftRmNetwork.renewUserToken(deviceToken: deviceToken, url: userTokenURL)
        }
        return currentToken
    }

    private func isExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }

        // JWT payloads are base64url: map back to standard base64 before decoding.
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }

        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(300)
    }
}
