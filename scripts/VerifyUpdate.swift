import Foundation
import CryptoKit

func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw NSError(domain: "FileDock.UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}
func verify() throws {
    let arguments = CommandLine.arguments
    try require(arguments.count == 5, "usage: verify-update public-key appcast.xml FileDock.zip vX.Y.Z")
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: arguments[1]) ?? Data())
    let feed = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    try require(!feed.isEmpty && feed.count <= 1024 * 1024, "Invalid feed size")
    let marker = Data("<!-- sparkle-signatures:".utf8)
    guard let range = feed.range(of: marker, options: .backwards),
          let suffix = String(data: feed[range.lowerBound...], encoding: .utf8) else { throw NSError(domain: "FileDock.UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing signed feed envelope"]) }
    let pattern = try NSRegularExpression(pattern: #"\A<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*\z"#)
    guard let match = pattern.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
          let signatureRange = Range(match.range(at: 1), in: suffix), let lengthRange = Range(match.range(at: 2), in: suffix),
          let length = Int(suffix[lengthRange]), let signature = Data(base64Encoded: String(suffix[signatureRange])) else { throw NSError(domain: "FileDock.UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Malformed feed signature"]) }
    try require(length == range.lowerBound, "Incorrect signed feed length")
    try require(publicKey.isValidSignature(signature, for: feed.prefix(length)), "Invalid feed signature")
    // Parsing happens only after authentication; no remote entities are requested.
    let document = try XMLDocument(data: feed.prefix(length), options: [.nodeLoadExternalEntitiesNever])
    guard let channel = document.rootElement()?.elements(forName: "channel").first else { throw NSError(domain: "FileDock.UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing channel"]) }
    let items = channel.elements(forName: "item")
    try require(items.count == 1, "Expected one immutable release")
    let item = items[0]
    let version = item.children?.first { $0.localName == "shortVersionString" }?.stringValue
    try require(arguments[4].range(of: #"\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil, "Invalid stable tag")
    try require(version == String(arguments[4].dropFirst()), "Feed version differs from release")
    guard let enclosure = item.elements(forName: "enclosure").first,
          let archiveSignature = enclosure.attributes?.first(where: { $0.localName == "edSignature" })?.stringValue.flatMap({ Data(base64Encoded: $0) }) else { throw NSError(domain: "FileDock.UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing archive signature"]) }
    try require(enclosure.attribute(forName: "url")?.stringValue == "https://github.com/Die-Xie/FileDock/releases/download/\(arguments[4])/FileDock.zip", "Unexpected download URL")
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: [.mappedIfSafe])
    try require(!archive.isEmpty && archive.count < 95 * 1024 * 1024, "Invalid archive size")
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "Incorrect archive length")
    try require(publicKey.isValidSignature(archiveSignature, for: archive), "Invalid archive signature")
    print("PASS: fixed-key feed and archive signatures, immutable release URL, version and byte lengths")
}
do { try verify() }
catch { fputs("Update verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
