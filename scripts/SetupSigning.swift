import Foundation
import Security
import CryptoKit

struct SigningIdentity: Codable {
    let version: Int
    let bundleIdentifier: String
    let certificateSHA1: String
    let keychainPath: String
}

enum SetupFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "Signing setup failed" }
}

func require(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw SetupFailure.message("\(operation): \(detail)")
    }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // OpenSSL progress contains no useful setup result. Errors are reported by exit status.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SetupFailure.message("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus))") }
}

let fm = FileManager.default
let bundleID = "local.diexie.folderhub-replica"
let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let directory = support.appendingPathComponent("FolderHubReplica/Signing", isDirectory: true)
let configURL = directory.appendingPathComponent("identity.plist")
let certURL = directory.appendingPathComponent("certificate.der")
let loginKeychainURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")

func requireOwnedFile(_ url: URL, directory expectedDirectory: Bool = false) throws {
    let attributes = try fm.attributesOfItem(atPath: url.path)
    let type = expectedDirectory ? FileAttributeType.typeDirectory : .typeRegular
    guard attributes[.type] as? FileAttributeType == type,
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
        throw SetupFailure.message("Signing files must be owned by this user and cannot be symlinks: \(url.lastPathComponent)")
    }
}

func fingerprint(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

func checkExisting() throws {
    try requireOwnedFile(directory, directory: true)
    try requireOwnedFile(configURL)
    try requireOwnedFile(certURL)
    let config = try PropertyListDecoder().decode(SigningIdentity.self, from: Data(contentsOf: configURL))
    let certData = try Data(contentsOf: certURL)
    guard config.version == 1, config.bundleIdentifier == bundleID,
          config.keychainPath == loginKeychainURL.path,
          config.certificateSHA1 == fingerprint(certData),
          let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
        throw SetupFailure.message("Saved signing identity is inconsistent; restore its existing files instead of generating a new identity.")
    }
    var keychain: SecKeychain?
    try require(SecKeychainOpen(config.keychainPath, &keychain), "Open signing keychain")
    var identity: SecIdentity?
    try require(SecIdentityCreateWithCertificate(keychain, certificate, &identity), "Find the existing signing identity; do not regenerate it")
    guard identity != nil else { throw SetupFailure.message("Existing signing identity unavailable") }
    print("Existing persistent signing identity verified: \(config.certificateSHA1)")
}

do {
    if fm.fileExists(atPath: configURL.path) {
        try checkExisting()
        exit(0)
    }
    if CommandLine.arguments.contains("--check") {
        throw SetupFailure.message("No persistent signing identity. Run ./setup-signing.sh once before building.")
    }
    if fm.fileExists(atPath: directory.path) { try requireOwnedFile(directory, directory: true) }
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let lock = directory.appendingPathComponent("setup.lock", isDirectory: true)
    do { try fm.createDirectory(at: lock, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { throw SetupFailure.message("Signing setup is already running or its lock remains; inspect setup.lock before retrying.") }
    defer { try? fm.removeItem(at: lock) }
    // Check again after taking the setup lock; never replace an existing signer.
    if fm.fileExists(atPath: configURL.path) { try checkExisting() }
    guard !fm.fileExists(atPath: configURL.path) else { throw SetupFailure.message("Signing setup completed concurrently; retry the check.") }
    guard !fm.fileExists(atPath: certURL.path) else {
        throw SetupFailure.message("A certificate already exists without its configuration. Restore the configuration instead of replacing the identity.")
    }
    let temporary = fm.temporaryDirectory.appendingPathComponent("FolderHubSigning-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    let keyPEM = temporary.appendingPathComponent("key.pem")
    let certPEM = temporary.appendingPathComponent("certificate.pem")
    let certDER = temporary.appendingPathComponent("certificate.der")
    let opensslConfig = temporary.appendingPathComponent("openssl.cnf")
    let configuration = """
    [req]
    distinguished_name = subject
    x509_extensions = signing
    prompt = no
    [subject]
    CN = Folder Hub Replica Local Signing
    [signing]
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature
    extendedKeyUsage = critical,codeSigning
    subjectKeyIdentifier = hash
    """
    try configuration.write(to: opensslConfig, atomically: true, encoding: .utf8)
    try run("/usr/bin/openssl", ["genrsa", "-out", keyPEM.path, "3072"])
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPEM.path)
    try run("/usr/bin/openssl", ["req", "-new", "-key", keyPEM.path, "-x509", "-sha256", "-days", "3650", "-config", opensslConfig.path, "-out", certPEM.path])
    try run("/usr/bin/openssl", ["x509", "-in", certPEM.path, "-outform", "der", "-out", certDER.path])
    let certData = try Data(contentsOf: certDER)
    guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else { throw SetupFailure.message("Invalid generated certificate") }
    var keychain: SecKeychain?
    try require(SecKeychainOpen(loginKeychainURL.path, &keychain), "Open user login keychain")
    guard let keychain else { throw SetupFailure.message("User login keychain unavailable") }
    var pathBuffer = [CChar](repeating: 0, count: 4096)
    var pathLength = UInt32(pathBuffer.count)
    try require(SecKeychainGetPath(keychain, &pathLength, &pathBuffer), "Read keychain location")
    var trustedCodesign: SecTrustedApplication?
    try require(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trustedCodesign), "Identify codesign")
    guard let trustedCodesign else { throw SetupFailure.message("codesign unavailable") }
    var access: SecAccess?
    try require(SecAccessCreate("Folder Hub Replica signing key" as CFString, [trustedCodesign] as CFArray, &access), "Limit signing key access")
    guard let access else { throw SetupFailure.message("Signing key access control unavailable") }
    let keyUsage = [kSecAttrCanSign] as CFArray
    let keyAttributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.accessRef = .passUnretained(access)
    parameters.keyUsage = .passUnretained(keyUsage)
    // Keep this private key sensitive, permanent, and non-extractable.
    parameters.keyAttributes = .passUnretained(keyAttributes)
    var format = SecExternalFormat.formatOpenSSL
    var type = SecExternalItemType.itemTypePrivateKey
    var importedItems: CFArray?
    let keyData = try Data(contentsOf: keyPEM) as CFData
    let importStatus = withExtendedLifetime((access, keyUsage, keyAttributes)) {
        SecItemImport(keyData, nil, &format, &type, [], &parameters, keychain, &importedItems)
    }
    try require(importStatus, "Import private signing key")
    guard let keys = importedItems as? [SecKey], keys.count == 1 else { throw SetupFailure.message("Expected exactly one imported signing key") }
    do {
        try require(SecCertificateAddToKeychain(certificate, keychain), "Import signing certificate")
        let config = SigningIdentity(version: 1, bundleIdentifier: bundleID, certificateSHA1: fingerprint(certData), keychainPath: String(cString: pathBuffer))
        try certData.write(to: certURL, options: .atomic)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(config).write(to: configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        try checkExisting()
    } catch {
        // Roll back only the newly imported key if setup did not become usable.
        if !fm.fileExists(atPath: configURL.path) {
            SecItemDelete([kSecClass: kSecClassKey, kSecValueRef: keys[0]] as CFDictionary)
        }
        throw error
    }
    print("Signing key is stored only in the user Keychain. No root trust was added.")
} catch {
    fputs("Signing setup: \(error)\n", stderr)
    exit(1)
}
