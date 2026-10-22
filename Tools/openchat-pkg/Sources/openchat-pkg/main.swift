// openchat-pkg: the package author's tool.
//
//   openchat-pkg validate <folder|file.ocpkg>          check every rule the app checks, print what the package adds
//   openchat-pkg pack <folder> [-o out.ocpkg]          normalize, write CHECKSUMS, zip
//   openchat-pkg sign <folder|file.ocpkg> --key <file> [-o out.ocpkg]
//                                                      pack and sign with an Ed25519 key from keygen
//   openchat-pkg keygen [-o name]                      write name.key (private, keep it secret) and print the public key
//   openchat-pkg run <folder|file.ocpkg> <tool> [--args '<json>'] [--secret name=value]...
//                                                      call one HTTP tool against the real network, print what the model reads
import Foundation
import OpenChatPackageKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: openchat-pkg validate|pack|sign|keygen|run … (see the top of main.swift)")
}
args.removeFirst()

/// `--name value` (removed from args), or nil.
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

@MainActor func options(_ name: String) -> [String] {
    var out: [String] = []
    while let v = option(name) { out.append(v) }
    return out
}

/// The package's files from a folder or an .ocpkg.
func readFiles(_ path: String) -> [String: Data] {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { fail("\(path) doesn't exist.") }
    do {
        if isDir.boolValue { return try PackageBundle.readFolder(url) }
        return try PackageArchive.read(try Data(contentsOf: url))
    } catch { fail(error.localizedDescription) }
}

func load(_ files: [String: Data]) -> PackageBundle {
    do { return try PackageBundle.load(files: files) } catch { fail(error.localizedDescription) }
}

func describe(_ bundle: PackageBundle) {
    let m = bundle.manifest
    print("\(m.name) \(m.version) (\(m.id), namespace \(m.namespace))")
    switch bundle.verification {
    case .unsigned: print("  unsigned")
    case .signed(let keys): print("  signed by \(keys.last!.string) (fingerprint \(keys.last!.fingerprint))")
    }
    print("  digest \(bundle.digest)")
    for tool in bundle.usableTools {
        print("  tool \(PackageRender.toolName(namespace: m.namespace, tool: tool.name)) [\(tool.kind), \(tool.isReadOnly ? "read-only" : "writes"), confirm \(tool.confirmLevel)]")
    }
    for skill in bundle.skills { print("  skill \(m.namespace):\(skill.name)") }
    for c in m.commands { print("  command /\(c.name)") }
    for c in m.connections { print("  connection \(c.name) \(c.url)") }
    if !m.network.isEmpty { print("  can reach: \(m.network.joined(separator: ", "))") }
    for s in m.secrets { print("  secret \(s.name) (\(s.inject))") }
    let section = bundle.promptSection()
    if !section.isEmpty { print("  prompt: \(section.count) characters, about \((section.utf8.count + 3) / 4) tokens") }
    for w in bundle.warnings { print("  warning: unknown key \(w) is ignored") }
}

func write(_ files: [String: Data], to output: String) {
    do { try PackageArchive.write(files).write(to: URL(fileURLWithPath: output), options: .atomic) }
    catch { fail("can't write \(output): \(error.localizedDescription)") }
    print("wrote \(output)")
}

func defaultOutput(_ bundle: PackageBundle) -> String { "\(bundle.manifest.id)-\(bundle.manifest.version).ocpkg" }

switch command {
case "validate":
    guard let path = args.first else { fail("usage: openchat-pkg validate <folder|file.ocpkg>") }
    describe(load(readFiles(path)))
    print("ok")

case "pack":
    let output = option("-o")
    guard let path = args.first else { fail("usage: openchat-pkg pack <folder> [-o out.ocpkg]") }
    let files: [String: Data]
    do { files = try PackageBundle.packed(readFiles(path)) } catch { fail(error.localizedDescription) }
    let bundle = load(files)
    describe(bundle)
    write(files, to: output ?? defaultOutput(bundle))

case "sign":
    let output = option("-o")
    guard let keyPath = option("--key"), let path = args.first else {
        fail("usage: openchat-pkg sign <folder|file.ocpkg> --key <file.key> [-o out.ocpkg]")
    }
    let privateKey: String
    do { privateKey = try String(contentsOfFile: keyPath, encoding: .utf8) } catch { fail("can't read \(keyPath).") }
    do {
        let key = try PackageKeys.privateKey(privateKey)
        let publicKey = PackageKey(raw: key.publicKey.rawRepresentation).string
        var files = try PackageBundle.packed(readFiles(path))
        let manifest = try PackageManifest.decode(files["manifest.json"] ?? Data())
        guard manifest.publisher?.key == publicKey else {
            fail("manifest.json's publisher.key must be \(publicKey) (the key you sign with).")
        }
        let signature = try PackageSignature.sign(checksums: files[PackageChecksums.fileName]!, with: key)
        files[PackageSignature.fileName] = signature.encoded()
        let bundle = load(files)
        describe(bundle)
        write(files, to: output ?? defaultOutput(bundle))
    } catch { fail(error.localizedDescription) }

case "keygen":
    let name = option("-o") ?? "openchat-package"
    let pair = PackageKeys.generate()
    let path = name + ".key"
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists; pick another name with -o.") }
    do {
        try Data((pair.privateKey + "\n").utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch { fail("can't write \(path).") }
    print("wrote \(path) (private: keep it out of the package and out of version control)")
    print("publisher.key: \(pair.publicKey)")
    print("fingerprint: \(try! PackageKey(pair.publicKey).fingerprint)")

case "run":
    let argsJSON = option("--args") ?? "{}"
    let secrets = Dictionary(options("--secret").compactMap { pair -> (String, String)? in
        guard let eq = pair.firstIndex(of: "=") else { return nil }
        return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
    }, uniquingKeysWith: { _, last in last })
    guard args.count >= 2 else { fail("usage: openchat-pkg run <folder|file.ocpkg> <tool> [--args '<json>'] [--secret name=value]") }
    let bundle = load(readFiles(args[0]))
    let name = PackageRender.split(toolName: args[1])?.tool ?? args[1]
    guard let tool = bundle.usableTools.first(where: { $0.name == name }) else {
        fail("no tool \(name); the package has \(bundle.usableTools.map(\.name).joined(separator: ", ")).")
    }
    do {
        let arguments = try JSONSchemaSubset.validateArguments(try JSONValue.parse(argsJSON), schema: tool.parameters, tool: tool.name)
        let built: HTTPRequestBuilder.Built
        do { built = try HTTPRequestBuilder.build(tool: tool, manifest: bundle.manifest, arguments: arguments) { secrets[$0] } }
        catch .missingSecret(let s) { fail("the tool needs the secret \(s.name): pass --secret \(s.name)=…") }
        catch .bad(let m) { fail(m) }
        note(built.preview)
        var request = URLRequest(url: built.url, timeoutInterval: TimeInterval(tool.timeoutSeconds))
        request.httpMethod = built.method
        request.httpBody = built.body
        for (k, v) in built.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        note("HTTP \(status), \(data.count) bytes")
        guard (200..<300).contains(status) else { fail(String(decoding: data.prefix(500), as: UTF8.self)) }
        let out = try ResponseProjection.project(body: data, spec: tool.response)
        print(out.text)
        for s in out.sources { note("source: \(s.title) <\(s.url)>") }
    } catch { fail(error.localizedDescription) }

default:
    fail("unknown command \(command): use validate, pack, sign, keygen or run.")
}
