//
//  File.swift
//  SwiftRm
//
//  Created by Liam Wittig on 07.04.26.
//

import Foundation
import CryptoKit

struct SwiftRmNetwork{

    private static let maxAttempts = 3
    private static let transientErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost]

    /// GETs are retried with backoff on timeouts, dropped connections, 429 and 5xx.
    private static func rawData(_ path: String, userToken: SwiftRmToken, method: String = "GET", filename: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            let canRetry = method == "GET" && attempt < maxAttempts
            do {
                let token = try await userToken.validToken()
                var request = URLRequest(url: URL(string: path)!, timeoutInterval: 20)
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let filename { request.setValue(filename, forHTTPHeaderField: "rm-filename") }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SwiftRmError.invalidResponse }
                guard canRetry, http.statusCode == 429 || (500...599).contains(http.statusCode) else {
                    return (data, http)
                }
                Log.msg("rawData: \(path.suffix(40)) → HTTP \(http.statusCode), retrying (\(attempt)/\(maxAttempts))", level: .error)
            } catch let error as URLError where canRetry && transientErrors.contains(error.code) {
                Log.msg("rawData: \(path.suffix(40)) → \(error.code.rawValue), retrying (\(attempt)/\(maxAttempts))", level: .error)
            }
            try await Task.sleep(for: .seconds(1 << (attempt - 1)))
            attempt += 1
        }
    }

    public static func request<T: Decodable>(_ path: String, userToken: SwiftRmToken, method: String = "GET", filename: String? = nil) async throws -> T {
        let (data, http) = try await rawData(path, userToken: userToken, method: method, filename: filename)
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            Log.msg("request FAILED: \(method) \(path.suffix(40)) → HTTP \(http.statusCode) body: \(body)", level: .error)
            throw SwiftRmError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public static func requestText(_ path: String, userToken: SwiftRmToken, filename: String? = nil) async throws -> String {
        let (data, http) = try await rawData(path, userToken: userToken, filename: filename)
        guard http.statusCode == 200 else { throw SwiftRmError.invalidResponse }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func requestData(_ path: String, userToken: SwiftRmToken, filename: String? = nil) async throws -> Data {
        let (data, http) = try await rawData(path, userToken: userToken, filename: filename)
        guard http.statusCode == 200 else { throw SwiftRmError.invalidResponse }
        return data
    }

    public static func renewUserToken(deviceToken: String, url: String) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw SwiftRmError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            Log.msg("renewUserToken FAILED: HTTP \(http.statusCode) body: \(body)", level: .error)
            throw SwiftRmError.invalidResponse
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func uploadBlob(_ path: String, filename: String, body: Data, userToken: SwiftRmToken) async throws {
        let token = try await userToken.validToken()
        var request = URLRequest(url: URL(string: path)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(filename, forHTTPHeaderField: "rm-filename")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("crc32c=\(crc32cBase64(body))", forHTTPHeaderField: "x-goog-hash")
        request.httpBody = body

        Log.msg("uploadBlob: PUT \(filename) (\(body.count) bytes)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SwiftRmError.invalidResponse }
        Log.msg("uploadBlob: \(filename) → HTTP \(http.statusCode)")
        guard (200...299).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
            Log.msg("uploadBlob FAILED: \(filename) HTTP \(http.statusCode) body: \(responseBody)", level: .error)
            throw SwiftRmError.invalidResponse
        }
    }

    private static func crc32cBase64(_ data: Data) -> String {
        var crc: UInt32 = 0xFFFFFFFF
        let poly: UInt32 = 0x82F63B78
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1
            }
        }
        crc ^= 0xFFFFFFFF
        var bigEndian = crc.bigEndian
        let crcData = Data(bytes: &bigEndian, count: 4)
        return crcData.base64EncodedString()
    }

    public static func putRoot(hash: String, generation: Int, userToken: SwiftRmToken, config: RemarkableConfig) async throws -> RmRoot {
        let token = try await userToken.validToken()
        let payload = RmRootPut(hash: hash, generation: generation, broadcast: true)
        let body = try JSONEncoder().encode(payload)

        var request = URLRequest(url: URL(string: config.rootPut)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        Log.msg("putRoot: gen=\(generation) hash=\(hash.prefix(12))...")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SwiftRmError.invalidResponse }
        Log.msg("putRoot: HTTP \(http.statusCode)")

        if http.statusCode == 412 { throw SwiftRmError.generationConflict }
        guard (200...299).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
            Log.msg("putRoot FAILED: HTTP \(http.statusCode) body: \(responseBody)", level: .error)
            throw SwiftRmError.invalidResponse
        }

        return try JSONDecoder().decode(RmRoot.self, from: data)
    }

    public static func registerDevice(token: String, config: RemarkableConfig) async throws -> String {
        let uuid = UUID().uuidString.lowercased()
        let payload: [String: String] = [
            "code": token,
            "deviceDesc": RemarkableConfig.defaultDeviceDesc,
            "deviceID": uuid
        ]
        let body = try JSONEncoder().encode(payload)
        let url = URL(string: config.deviceTokenURL)!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw SwiftRmError.invalidResponse
        }

        let deviceToken = String(data: data, encoding: .utf8) ?? ""

        SwiftRmKeychain.save(config.keychainKey, deviceToken)

        return deviceToken
    }
}
