import Foundation
import CryptoKit
let args=CommandLine.arguments
if args[1]=="generate" {
    let url=URL(fileURLWithPath:args[2]); if FileManager.default.fileExists(atPath:url.path){fatalError("Refusing to replace key")}
    let key=Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to:url,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
    let key=try Curve25519.Signing.PrivateKey(rawRepresentation:Data(contentsOf:URL(fileURLWithPath:args[2])))
    print(try key.signature(for:Data(contentsOf:URL(fileURLWithPath:args[3]))).base64EncodedString())
}
