#!/usr/bin/env swift
// Minimal App Store Connect API client. Signs a short-lived ES256 token with the key named in
// ~/.appstoreconnect/omnichat.env (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH) and prints only the response,
// never the token or the key.
//
//   swift Tools/asc.swift GET '/v1/apps?filter[bundleId]=cc.coolservices.strata'
//   swift Tools/asc.swift PATCH /v1/appInfoLocalizations/<id> body.json
//   swift Tools/asc.swift POST /v1/appScreenshots body.json
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadEnv() -> [String: String] {
    let path = ProcessInfo.processInfo.environment["ASC_ENV"]
        ?? NSString(string: "~/.appstoreconnect/omnichat.env").expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Can't read \(path)") }
    var env: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        env[parts[0]] = parts[1].replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    return env
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func token(_ env: [String: String]) -> String {
    guard let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"], let keyPath = env["ASC_KEY_PATH"] else {
        fail("omnichat.env needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH")
    }
    guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("Can't load the key at ASC_KEY_PATH") }
    let now = Int(Date().timeIntervalSince1970)
    let header = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
    let claims: [String: Any] = ["iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]
    let signingInput = base64URL(try! JSONSerialization.data(withJSONObject: header)) + "."
        + base64URL(try! JSONSerialization.data(withJSONObject: claims))
    let signature = try! key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + base64URL(signature.rawRepresentation)
}

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2 else { fail("usage: asc.swift METHOD PATH [body.json]") }
let method = args[args.startIndex].uppercased()
let path = args[args.startIndex + 1]
let urlString = path.hasPrefix("http") ? path : "https://api.appstoreconnect.apple.com" + path
guard let url = URL(string: urlString) else { fail("Bad path \(path)") }

var request = URLRequest(url: url)
request.httpMethod = method
request.setValue("Bearer " + token(loadEnv()), forHTTPHeaderField: "Authorization")
if args.count >= 3 {
    let bodyPath = args[args.startIndex + 2]
    guard let body = FileManager.default.contents(atPath: bodyPath) else { fail("Can't read \(bodyPath)") }
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
}

let done = DispatchSemaphore(value: 0)
var status = 0
URLSession.shared.dataTask(with: request) { data, response, error in
    if let error { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if let data, !data.isEmpty { FileHandle.standardOutput.write(data) }
    done.signal()
}.resume()
done.wait()
FileHandle.standardError.write(Data("\nHTTP \(status)\n".utf8))
exit((200..<300).contains(status) ? 0 : 1)
