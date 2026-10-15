// Ed25519 keys and signatures for update packages (see docs/BUILD.md).
//   swift scripts/update-signing.swift genkey <private-key-file>   → prints the public key
//   swift scripts/update-signing.swift public <private-key-file>   → prints the public key
//   swift scripts/update-signing.swift sign <private-key-file> <file>  → prints the signature
//   swift scripts/update-signing.swift verify <public-key> <file> <signature>
// Keys and signatures are base64. The private key file must stay out of the repository.
import CryptoKit
import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { die("cannot read private key \(path)") }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
    return data
}

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.count) {
case ("genkey", 2):
    let path = args[args.startIndex + 1]
    guard !FileManager.default.fileExists(atPath: path) else { die("\(path) already exists") }
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { die("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 2):
    print(loadKey(args[args.startIndex + 1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    let key = loadKey(args[args.startIndex + 1])
    let signature = try key.signature(for: readFile(args[args.startIndex + 2]))
    print(signature.base64EncodedString())
case ("verify", 4):
    let a = Array(args)
    guard let raw = Data(base64Encoded: a[1]), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let sig = Data(base64Encoded: a[3].trimmingCharacters(in: .whitespacesAndNewlines))
    else { die("invalid public key or signature") }
    guard pub.isValidSignature(sig, for: readFile(a[2])) else { die("signature NOT valid") }
    print("signature valid")
default:
    die("usage: update-signing.swift genkey|public|sign|verify …")
}
