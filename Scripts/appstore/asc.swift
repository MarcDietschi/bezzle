// One request to the App Store Connect API. Usage: asc METHOD PATH [JSON-BODY-FILE]
// Prints the HTTP status on the first line, then the response. Never prints the key.
// Key: $ASC_KEY_PATH (.p8), $ASC_KEY_ID, $ASC_ISSUER.
import Foundation
import CryptoKit

let env = ProcessInfo.processInfo.environment
let keyPath = env["ASC_KEY_PATH"]!, keyID = env["ASC_KEY_ID"]!, issuer = env["ASC_ISSUER"]!
let args = CommandLine.arguments
let method = args[1], path = args[2]

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let pem = try! String(contentsOfFile: keyPath, encoding: .utf8)
let key = try! P256.Signing.PrivateKey(pemRepresentation: pem)
let now = Int(Date().timeIntervalSince1970)
let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]))
let claims = b64url(try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"]))
let signingInput = "\(header).\(claims)"
let signature = try! key.signature(for: Data(signingInput.utf8))
let token = "\(signingInput).\(b64url(signature.rawRepresentation))"

var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
request.httpMethod = method
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
if args.count > 3 {
    request.httpBody = try! Data(contentsOf: URL(fileURLWithPath: args[3]))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
}
let sema = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: request) { data, response, error in
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    print("HTTP \(status)")
    if let data { print(String(decoding: data, as: UTF8.self)) }
    if let error { print("error: \(error)") }
    sema.signal()
}.resume()
sema.wait()
