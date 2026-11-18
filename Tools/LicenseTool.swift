import CryptoKit
import Foundation

// EasyRead Pro offline license tool.
//
// The private key must never be committed to the public repository.
// Default location: ~/.easyread-license/private.key
//
// Usage:
//   LicenseTool init [--force] [--key PATH]
//   LicenseTool public-key [--key PATH]
//   LicenseTool generate [--count N] [--days N] [--order ID] [--out PATH] [--key PATH]
//   LicenseTool verify --code CODE [--public-key BASE64 | --key PATH]

private let productID = "easyread.pro.webdav"
private let licensePrefix = "ERPRO1"
private let defaultKeyPath = ("~/.easyread-license/private.key" as NSString).expandingTildeInPath

private enum ToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

private struct LicensePayload: Codable {
    let v: Int
    let product: String
    let kind: String
    let licenseId: String
    let issuedAt: Int
    let orderId: String?
    let expiresAt: Int?
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
    exit(1)
}

private func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
        return nil
    }
    return args[index + 1]
}

private func flag(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecode(_ string: String) -> Data? {
    var value = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 {
        value.append("=")
    }
    return Data(base64Encoded: value)
}

private func loadPrivateKey(path: String) throws -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw ToolError.message("private key not found at \(path). Run `LicenseTool init` first.")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
        throw ToolError.message("invalid private key at \(path).")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

private func loadPublicKey(args: [String], keyPath: String) throws -> Curve25519.Signing.PublicKey {
    if let encoded = value(after: "--public-key", in: args) {
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else {
            throw ToolError.message("invalid --public-key value.")
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    let publicPath = (keyPath as NSString).deletingLastPathComponent + "/public.key"
    if let text = try? String(contentsOfFile: publicPath, encoding: .utf8),
       let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
       data.count == 32 {
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    return try loadPrivateKey(path: keyPath).publicKey
}

private func writePrivateKey(_ key: Curve25519.Signing.PrivateKey, to path: String) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let encoded = key.rawRepresentation.base64EncodedString() + "\n"
    try encoded.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

    let publicPath = directory + "/public.key"
    let publicEncoded = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
    try publicEncoded.write(toFile: publicPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: publicPath)
}

private func sign(payload: LicensePayload, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payloadData = try encoder.encode(payload)
    let signature = try privateKey.signature(for: payloadData)
    return "\(licensePrefix).\(base64URL(payloadData)).\(base64URL(signature))"
}

private func verify(code: String, publicKey: Curve25519.Signing.PublicKey) throws -> LicensePayload {
    let normalized = code.components(separatedBy: .whitespacesAndNewlines).joined()
    let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == licensePrefix else {
        throw ToolError.message("license code format is invalid.")
    }
    guard let payloadData = base64URLDecode(String(parts[1])),
          let signatureData = base64URLDecode(String(parts[2])) else {
        throw ToolError.message("license code contains invalid base64 data.")
    }
    guard publicKey.isValidSignature(signatureData, for: payloadData) else {
        throw ToolError.message("license signature is invalid.")
    }
    let payload = try JSONDecoder().decode(LicensePayload.self, from: payloadData)
    guard payload.v == 1, payload.product == productID, payload.kind == "lifetime" else {
        throw ToolError.message("license payload is not supported.")
    }
    if let expiresAt = payload.expiresAt, expiresAt < Int(Date().timeIntervalSince1970) {
        throw ToolError.message("license has expired.")
    }
    return payload
}

private func isoDate(_ timestamp: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

private func printPayload(_ payload: LicensePayload) {
    print("License ID: \(payload.licenseId)")
    print("Product:    \(payload.product)")
    print("Kind:       \(payload.kind)")
    print("Issued at:  \(isoDate(payload.issuedAt))")
    if let orderId = payload.orderId, !orderId.isEmpty {
        print("Order ID:   \(orderId)")
    }
    if let expiresAt = payload.expiresAt {
        print("Expires at: \(isoDate(expiresAt))")
    } else {
        print("Expires at: never")
    }
}

private func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw ToolError.message("usage: LicenseTool <init|public-key|generate|verify> [options]")
    }
    args.removeFirst()

    let keyPath = value(after: "--key", in: args) ?? defaultKeyPath

    switch command {
    case "init", "keygen":
        if FileManager.default.fileExists(atPath: keyPath), !flag("--force", in: args) {
            let existing = try loadPrivateKey(path: keyPath)
            print("Private key already exists: \(keyPath)")
            print("Public key:")
            print(existing.publicKey.rawRepresentation.base64EncodedString())
            print("Use --force to replace it. Replacing it invalidates every issued license.")
            return
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        try writePrivateKey(privateKey, to: keyPath)
        print("Private key: \(keyPath)")
        print("Public key:  \(keyPath.replacingOccurrences(of: "/private.key", with: "/public.key"))")
        print("")
        print("Embed this public key in Sources/IntelReader/ProLicense.swift:")
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())

    case "public-key":
        let privateKey = try loadPrivateKey(path: keyPath)
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())

    case "generate":
        let privateKey = try loadPrivateKey(path: keyPath)
        let count = max(1, Int(value(after: "--count", in: args) ?? "10") ?? 10)
        guard count <= 5000 else {
            throw ToolError.message("--count is limited to 5000 per invocation.")
        }
        let days = Int(value(after: "--days", in: args) ?? "0") ?? 0
        let now = Int(Date().timeIntervalSince1970)
        let expiresAt = days > 0 ? now + days * 86400 : nil
        let requestedOrder = value(after: "--order", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let orderId = (requestedOrder?.isEmpty == false)
            ? requestedOrder
            : "BATCH-\(now)-\(String(UUID().uuidString.prefix(8)))"

        var codes: [String] = []
        codes.reserveCapacity(count)
        for _ in 0..<count {
            let payload = LicensePayload(
                v: 1,
                product: productID,
                kind: "lifetime",
                licenseId: UUID().uuidString,
                issuedAt: now,
                orderId: orderId,
                expiresAt: expiresAt
            )
            codes.append(try sign(payload: payload, privateKey: privateKey))
        }

        let output = codes.joined(separator: "\n") + "\n"
        if let outPath = value(after: "--out", in: args) {
            let expanded = (outPath as NSString).expandingTildeInPath
            try output.write(toFile: expanded, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("Wrote \(count) codes to \(expanded)\n".utf8))
        } else {
            print(output, terminator: "")
            FileHandle.standardError.write(Data("Generated \(count) codes.\n".utf8))
        }
        FileHandle.standardError.write(Data("Order ID: \(orderId ?? "-")\n".utf8))

    case "verify":
        guard let code = value(after: "--code", in: args) else {
            throw ToolError.message("verify requires --code CODE.")
        }
        let publicKey = try loadPublicKey(args: args, keyPath: keyPath)
        let payload = try verify(code: code, publicKey: publicKey)
        printPayload(payload)

    default:
        throw ToolError.message("unknown command `\(command)`.")
    }
}

do {
    try run()
} catch {
    fail(String(describing: error))
}
