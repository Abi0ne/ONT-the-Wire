import CryptoKit
import Foundation
import Testing
@testable import ONTTheWireCore

struct UpdateTests {
    @Test func versionsCompareNumerically() {
        #expect(AppVersion("0.1.0")! < AppVersion("v0.1.1")!)
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1.0.0-beta") == nil)
        #expect(AppVersion("") == nil)
    }

    private func releaseJSON(tag: String = "v0.2.0", assets: [String]) -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","size":1234,"browser_download_url":"https://github.com/x/\#($0)"}"#
        }.joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/x","body":"note","assets":[\#(list)]}"#.utf8)
    }

    @Test func parsesLatestRelease() throws {
        let release = try UpdateFeed.parseLatestRelease(
            releaseJSON(assets: ["ONT-The-Wire-0.2.0.zip", "ONT-The-Wire-0.2.0.zip.sig", "ONT-The-Wire-0.2.0.dmg"]))
        #expect(release.version == AppVersion("0.2.0")!)
        #expect(release.archiveURL.lastPathComponent == "ONT-The-Wire-0.2.0.zip")
        #expect(release.signatureURL.lastPathComponent == "ONT-The-Wire-0.2.0.zip.sig")
    }

    @Test func rejectsReleaseWithoutSignature() {
        #expect(throws: UpdateError.missingAsset("ONT-The-Wire-0.2.0.zip.sig")) {
            try UpdateFeed.parseLatestRelease(releaseJSON(assets: ["ONT-The-Wire-0.2.0.zip"]))
        }
    }

    @Test func verifiesSignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let archive = Data("pacchetto".utf8)
        let signature = Data(try key.signature(for: archive).base64EncodedString().utf8)
        #expect(UpdateFeed.verify(archive: archive, signature: signature, publicKey: publicKey))
        #expect(!UpdateFeed.verify(archive: Data("altro".utf8), signature: signature, publicKey: publicKey))
        // The embedded release key must not accept a signature from another key.
        #expect(!UpdateFeed.verify(archive: archive, signature: signature))
    }

    @Test func embeddedKeyIsValid() {
        let raw = Data(base64Encoded: UpdateFeed.publicKey)
        #expect(raw.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil)
    }
}
