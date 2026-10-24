import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let file = URL(fileURLWithPath: CommandLine.arguments[1])
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: file, options: .withoutOverwriting)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
