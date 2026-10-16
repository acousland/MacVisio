// Verify archives or pinned Sparkle 2.10 signed feeds using only a public key.
// No Keychain access, signing, network request or update installation occurs.
import CryptoKit
import Foundation

struct VerificationFailure: Error {
    let message: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationFailure(message: message) }
}

func boundedFeed(_ url: URL) throws -> Data {
    let limit = 1024 * 1024
    let stream = try FileHandle(forReadingFrom: url)
    defer { try? stream.close() }
    var data = Data()
    while let chunk = try stream.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        try require(data.count <= limit, "Signed feed exceeds the 1 MiB limit.")
    }
    return data
}

func signedFeed(_ data: Data) throws -> (payload: Data, signature: Data) {
    // Parse raw byte positions, never XML reserialization or normalized text.
    guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
        throw VerificationFailure(message: "Signed feed must be UTF-8 XML.")
    }
    let token = "sparkle-signatures"
    let lower = text.lowercased()
    guard let first = lower.range(of: token),
          lower.range(of: token, range: first.upperBound..<lower.endIndex) == nil,
          let marker = data.range(of: Data("<!-- sparkle-signatures:\n".utf8)) else {
        throw VerificationFailure(message: "Signed feed requires one canonical signature footer.")
    }
    let length = marker.lowerBound
    let footerBytes = data.suffix(from: length)
    try require(footerBytes.count <= 256, "Signed feed has trailing content or an oversized footer.")
    let footer = String(decoding: footerBytes, as: UTF8.self)
    // This exact footer and final LF were observed in actual pinned 2.10 output.
    // Ed25519 is 64 bytes, encoded canonically as 88 base64 characters ending ==.
    let grammar = try NSRegularExpression(pattern: #"\A<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([1-9][0-9]{0,6})\n-->\n\z"#)
    guard let match = grammar.firstMatch(in: footer, range: NSRange(footer.startIndex..., in: footer)),
          let signatureRange = Range(match.range(at: 1), in: footer),
          let lengthRange = Range(match.range(at: 2), in: footer),
          Int(footer[lengthRange]) == length,
          let signature = Data(base64Encoded: String(footer[signatureRange])),
          signature.count == 64,
          signature.base64EncodedString() == footer[signatureRange] else {
        throw VerificationFailure(message: "Invalid signed feed footer or signed-prefix length.")
    }
    return (Data(data.prefix(length)), signature)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    fputs("Usage: verify-update-signature.swift archive public-key signature\n       verify-update-signature.swift --feed appcast.xml public-key\n", stderr)
    exit(1)
}
do {
    let feedMode = arguments[0] == "--feed"
    let publicKey = feedMode ? arguments[2] : arguments[1]
    guard let keyData = Data(base64Encoded: publicKey) else {
        throw VerificationFailure(message: "Invalid update public key.")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let payload: Data
    let signature: Data
    if feedMode {
        (payload, signature) = try signedFeed(boundedFeed(URL(fileURLWithPath: arguments[1])))
    } else {
        payload = try Data(contentsOf: URL(fileURLWithPath: arguments[0]), options: .mappedIfSafe)
        guard let decoded = Data(base64Encoded: arguments[2]) else {
            throw VerificationFailure(message: "Invalid archive signature.")
        }
        signature = decoded
    }
    try require(key.isValidSignature(signature, for: payload),
                "Update \(feedMode ? "feed" : "archive") does not match the pinned public key.")
} catch let error as VerificationFailure {
    fputs(error.message + "\n", stderr)
    exit(1)
} catch {
    fputs("Could not verify update signature.\n", stderr)
    exit(1)
}
