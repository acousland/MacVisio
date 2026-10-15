// Verify the archive against the bundle's pinned public key independently of
// the private key used by sign_update. No Keychain access or signing occurs.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let keyData = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update-signature.swift archive public-key signature\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Update archive does not match the pinned public key.\n", stderr)
        exit(1)
    }
} catch {
    fputs("Could not verify update signature.\n", stderr)
    exit(1)
}
