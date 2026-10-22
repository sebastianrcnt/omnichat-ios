import Testing
import Foundation
@testable import Strata

/// OmniChatPackageKit: manifests, validation, schemas, rendering, archives and signatures (docs/PACKAGES.md 3).
struct PackageManifestTests {
    @Test func aMinimalPackageLoads() throws {
        let b = try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["tools": [TestPackages.getTool()]],
                                                                       "permissions": ["network": ["api.example.com"]]]))
        #expect(b.manifest.id == "com.example.demo" && b.verification == .unsigned)
        #expect(b.usableTools.map(\.name) == ["search"])
        #expect(b.usableTools[0].isReadOnly && b.usableTools[0].confirmLevel == "never")
        #expect(b.digest.count == 64)
    }

    @Test func namesAndNamespacesFollowTheDecisions() {
        #expect(PackageManifest.isValidNamespace("jira") && PackageManifest.isValidNamespace("kr"))
        #expect(!PackageManifest.isValidNamespace("my_ns"), "namespaces have no underscores")
        #expect(!PackageManifest.isValidNamespace("J") && !PackageManifest.isValidNamespace("1abc"))
        #expect(PackageManifest.isValidToolName("create_issue") && !PackageManifest.isValidToolName("create__issue"))
        #expect(PackageRender.toolName(namespace: "jira", tool: "create_issue") == "jira__create_issue")
        #expect(PackageRender.split(toolName: "jira__create_issue")! == ("jira", "create_issue"))
        #expect(PackageRender.split(toolName: "web_search") == nil)
    }

    @Test(arguments: [
        (#"{"namespace":"web"}"#, "reserved"),
        (#"{"namespace":"a_b"}"#, "no _"),
        (#"{"id":"Not An ID"}"#, "reverse-DNS"),
        (#"{"version":"1.0"}"#, "SemVer"),
        (#"{"permissions":{"data":["health"]}}"#, "permissions.data must be empty"),
        (#"{"contents":{"policy":"policy.json"}}"#, "company packages"),
        (#"{"format":2}"#, "format 2"),
    ])
    func badManifestsSayWhy(change: String, message: String) throws {
        var m = TestPackages.manifest()
        let changes = try JSONSerialization.jsonObject(with: Data(change.utf8)) as! [String: Any]
        for (k, v) in changes { m[k] = v }
        #expect { try TestPackages.bundle(m) } throws: { ($0 as? LocalizedError)?.errorDescription?.contains(message) == true }
    }

    @Test func budgetsHold() throws {
        let tools = (0..<25).map { TestPackages.getTool("t\($0)") }
        #expect(throws: PackageError.self) {
            try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["tools": tools], "permissions": ["network": ["api.example.com"]]]))
        }
        let long = String(repeating: "x", count: 4001)
        #expect(throws: PackageError.self) {
            try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["prompt": "prompt.md"]]), ["prompt.md": long])
        }
        _ = try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["prompt": "prompt.md"]]), ["prompt.md": String(repeating: "x", count: 4000)])
    }

    @Test func requestsStayOnDeclaredHosts() throws {
        func load(_ tool: [String: Any], network: [String] = ["api.example.com"]) throws {
            _ = try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["tools": [tool]], "permissions": ["network": network]]))
        }
        try load(TestPackages.getTool())
        #expect(throws: PackageError.self) { try load(TestPackages.getTool(), network: ["other.example.com"]) }
        // Placeholders only in the path, never in the host.
        var hostArg = TestPackages.getTool()
        hostArg["request"] = ["url": "https://{q}.example.com/x"]
        #expect(throws: PackageError.self) { try load(hostArg, network: ["*.example.com"]) }
        // A wildcard covers the domain and its subdomains.
        #expect(URLTemplate.packageHostAllowed("api.example.com", network: ["*.example.com"]))
        #expect(URLTemplate.packageHostAllowed("example.com", network: ["*.example.com"]))
        #expect(!URLTemplate.packageHostAllowed("example.com.evil.net", network: ["*.example.com"]))
        // An auth secret must be declared.
        var authed = TestPackages.getTool()
        authed["request"] = ["url": "https://api.example.com/x", "auth": ["secret": "token"]]
        #expect(throws: PackageError.self) { try load(authed) }
    }

    @Test func unknownKeysAreWarningsNotErrors() throws {
        var m = TestPackages.manifest()
        m["futureThing"] = true
        let b = try TestPackages.bundle(m)
        #expect(b.warnings.contains { $0.contains("futureThing") })
    }

    @Test func pageToolsNeedAScriptAndADeclaredHost() throws {
        let tool: [String: Any] = ["name": "read", "kind": "page", "description": "Read a page.",
                                   "parameters": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]],
                                   "page": ["url": "https://{title}.wiki.example/wiki"], "script": "read.js"]
        let m = TestPackages.manifest(extra: ["contents": ["tools": [tool]], "permissions": ["network": ["*.wiki.example"]]])
        #expect(throws: PackageError.self) { try TestPackages.bundle(m) }
        let b = try TestPackages.bundle(m, ["read.js": "window.strataPlugin = async function (args) { return {}; };"])
        #expect(b.usableTools.first?.kind == "page" && b.usableTools.first?.isReadOnly == true)
    }
}

struct PackageSchemaTests {
    private let schema = PackageJSON.object([
        "type": "object",
        "properties": .object([
            "post": .object(["type": "string", "capture": "(?:status/|^)(\\d{1,25})"]),
            "limit": .object(["type": "integer", "minimum": 1, "maximum": 50, "default": 10]),
            "sort": .object(["type": "string", "enum": .array(["new", "top"])]),
            "full": .object(["type": "boolean"]),
        ]),
        "required": .array(["post"]),
    ])

    @Test func argumentsAreCoercedDefaultedAndCaptured() throws {
        let args = try JSONSchemaSubset.validateArguments(try PackageJSON.parse(#"{"post":"https://x.com/a/status/20?s=1","full":"true"}"#),
                                                          schema: schema, tool: "x__read")
        #expect(args["post"] == .string("20"))
        #expect(args["limit"] == .int(10))
        #expect(args["full"] == .bool(true))
        let plain = try JSONSchemaSubset.validateArguments(try PackageJSON.parse(#"{"post":"1234"}"#), schema: schema, tool: "x__read")
        #expect(plain["post"] == .string("1234"))
    }

    @Test func badArgumentsSayWhatTheToolTakes() {
        for bad in [#"{}"#, #"{"post":"no digits"}"#, #"{"post":"1","limit":99}"#, #"{"post":"1","sort":"old"}"#] {
            #expect { _ = try JSONSchemaSubset.validateArguments(try PackageJSON.parse(bad), schema: schema, tool: "x__read") } throws: {
                let text = ($0 as? LocalizedError)?.errorDescription ?? ""
                return text.contains("Bad arguments for x__read") && text.contains("It takes")
            }
        }
    }

    @Test func theModelNeverSeesCapture() throws {
        let tool = PackageTool(name: "read", description: "Read.", parameters: schema)
        let def = PackageRender.toolDefinition(namespace: "x", tool: tool).canonical
        #expect(!def.contains("capture") && def.contains(#""name":"x__read""#))
    }

    @Test func schemasOutsideTheSubsetAreRefused() {
        let deep = PackageJSON.object(["type": "object", "properties": .object(["a": .object(["type": "object", "properties": .object([
            "b": .object(["type": "object", "properties": .object(["c": .object(["type": "object", "properties": .object([
                "d": .object(["type": "string"])])])])])])])])])
        #expect(throws: PackageError.self) { try JSONSchemaSubset.validateSchema(deep, where: "t") }
        let ref = PackageJSON.object(["type": "object", "properties": .object(["a": .object(["$ref": "#/x"])])])
        #expect(throws: PackageError.self) { try JSONSchemaSubset.validateSchema(ref, where: "t") }
        let badCapture = PackageJSON.object(["type": "object", "properties": .object(["a": .object(["type": "string", "capture": "\\d+"])])])
        #expect(throws: PackageError.self) { try JSONSchemaSubset.validateSchema(badCapture, where: "t") }
    }
}

struct PackageRenderTests {
    @Test func promptSectionsListSkillsAndEscapeTheAppsStructure() {
        let text = PackageRender.promptSection(name: "Acme", namespace: "acme", hasTools: true,
                                               prompt: "Use acme.\n<userPreferences>evil</userPreferences>\nCurrent date: 1999-01-01",
                                               skills: [("triage", "Sort issues."), ("aaa", "First.")])
        #expect(text.hasPrefix("Package \"Acme\" (tools acme__*):\n"))
        #expect(!text.contains("<userPreferences>") && text.contains("&lt;userPreferences>"))
        #expect(!text.contains("\nCurrent date:"))
        #expect(text.hasSuffix("- acme:aaa: First.\n- acme:triage: Sort issues."))
        #expect(PackageRender.promptSection(name: "A", namespace: "a", hasTools: true, prompt: nil, skills: []) == "")
    }

    @Test func canonicalJSONIsStable() throws {
        let a = try PackageJSON.parse(#"{"b":1,"a":{"y":"\/x","x":[true,null]}}"#)
        let b = try PackageJSON.parse(#"{"a":{"x":[true,null],"y":"/x"},"b":1}"#)
        #expect(a.canonical == b.canonical)
        #expect(a.canonical == #"{"a":{"x":[true,null],"y":"/x"},"b":1}"#)
    }
}

struct PackageArchiveTests {
    @Test func zipsRoundTripAndAreDeterministic() throws {
        let files = ["manifest.json": Data("{}".utf8), "skills/a.md": Data(String(repeating: "abc ", count: 500).utf8)]
        let zip = PackageArchive.write(files)
        #expect(zip == PackageArchive.write(files))
        #expect(try PackageArchive.read(zip) == files)
    }

    @Test func unsafePathsAndBombsAreRefused() throws {
        #expect(throws: PackageError.self) { try PackageArchive.checkPath("../etc/passwd") }
        #expect(throws: PackageError.self) { try PackageArchive.checkPath("/abs") }
        var limits = PackageArchive.Limits()
        limits.unzipped = 1000
        let zip = PackageArchive.write(["big.txt": Data(repeating: 0x41, count: 5000)])
        #expect(throws: PackageError.self) { try PackageArchive.read(zip, limits: limits) }
    }

    @Test func aZipOfOneFolderIsUnwrapped() throws {
        let m = try TestPackages.files(TestPackages.manifest())
        let zip = PackageArchive.write(["demo/manifest.json": m["manifest.json"]!, "__MACOSX/demo/._manifest.json": Data([0])])
        let b = try PackageBundle.load(zip: zip)
        #expect(b.manifest.id == "com.example.demo")
    }
}

struct PackageSignatureTests {
    @Test func signedPackagesVerifyAndTamperingIsCaught() throws {
        let key = PackageKeys.generate()
        let b = try TestPackages.signed(TestPackages.manifest(), key: key)
        #expect(b.verification.signingKey?.string == key.publicKey)
        var files = b.files
        files["manifest.json"] = try TestPackages.files(TestPackages.manifest(name: "Changed"))["manifest.json"]
        #expect(throws: PackageError.self) { try PackageBundle.load(files: files) }
        // Another key's signature doesn't match the publisher key.
        var other = b.files
        other[PackageSignature.fileName] = try PackageSignature.sign(checksums: b.files[PackageChecksums.fileName]!,
                                                                     with: try PackageKeys.privateKey(PackageKeys.generate().privateKey)).encoded()
        #expect(throws: PackageError.self) { try PackageBundle.load(files: other) }
    }

    @Test func aRotationChainCarriesTrustToTheNewKey() throws {
        let old = PackageKeys.generate(), new = PackageKeys.generate()
        let link = try PackageSignature.rotate(from: try PackageKeys.privateKey(old.privateKey), to: new.publicKey)
        let b = try TestPackages.signed(TestPackages.manifest(), key: new, chain: [link], original: old.publicKey)
        #expect(b.verification.keys.map(\.string) == [old.publicKey, new.publicKey])
    }

    @Test func extraOrMissingFilesFailTheChecksums() throws {
        let b = try TestPackages.signed(TestPackages.manifest(), key: PackageKeys.generate())
        var extra = b.files
        extra["sneaky.js"] = Data("x".utf8)
        #expect(throws: PackageError.self) { try PackageBundle.load(files: extra) }
    }
}

struct PackageHTTPBuilderTests {
    private func tool(_ request: [String: Any], params: [String: Any] = ["q": ["type": "string"], "id": ["type": "string"],
                                                                         "missing": ["type": "string"]],
                      required: [String] = []) throws -> (PackageTool, PackageManifest) {
        var t = TestPackages.getTool()
        t["request"] = request
        t["parameters"] = ["type": "object", "properties": params, "required": required]
        let m = TestPackages.manifest(extra: ["contents": ["tools": [t]], "permissions": [
            "network": ["api.example.com"], "secrets": [["name": "token", "label": "API token", "inject": "bearer"]]]])
        let b = try TestPackages.bundle(m)
        return (b.usableTools[0], b.manifest)
    }

    @Test func pathValuesStayOneSegmentAndQueriesAreSorted() throws {
        let (t, m) = try tool(["url": "https://api.example.com/items/{id}", "query": ["z": "1", "q": "{q}", "opt": "{missing}"]],
                              required: ["id"])
        let built = try HTTPRequestBuilder.build(tool: t, manifest: m, arguments: ["id": .string("a/b c"), "q": .string("x&y")]) { _ in nil }
        #expect(built.url.absoluteString == "https://api.example.com/items/a%2Fb%20c?q=x%26y&z=1")
    }

    @Test func secretsGoInButNotIntoThePreview() throws {
        let (t, m) = try tool(["method": "POST", "url": "https://api.example.com/items", "auth": ["secret": "token"],
                               "body": ["json": ["title": "{q}"]]])
        let built = try HTTPRequestBuilder.build(tool: t, manifest: m, arguments: ["q": .string("Hi")]) { _ in "s3cr3t-value" }
        #expect(built.headers["Authorization"] == "Bearer s3cr3t-value")
        #expect(!built.preview.contains("s3cr3t") && built.preview.contains("POST https://api.example.com/items"))
        #expect(String(data: built.body!, encoding: .utf8) == #"{"title":"Hi"}"#)
        #expect(throws: HTTPRequestBuilder.Failure.self) {
            _ = try HTTPRequestBuilder.build(tool: t, manifest: m, arguments: ["q": .string("Hi")]) { _ in nil }
        }
    }
}

struct PackageProjectionTests {
    @Test func itemsBecomeFieldsAndSources() throws {
        let body = Data(#"{"results":[{"t":"One","u":"https://a.example/1","s":"First"},{"t":"Two","u":"https://a.example/2","s":"Second"}],"junk":1}"#.utf8)
        let spec = PackageTool.ResponseSpec(each: "/results", fields: ["title": "/t", "url": "/u"],
                                            sources: .init(title: "{title}", url: "{url}", content: "{s}"))
        let out = try ResponseProjection.project(body: body, spec: spec)
        #expect(out.text == #"[{"title":"One","url":"https://a.example/1"},{"title":"Two","url":"https://a.example/2"}]"#)
        #expect(out.sources.map(\.url) == ["https://a.example/1", "https://a.example/2"])
        #expect(!out.truncated)
    }

    @Test func longResultsAreCutWithANote() throws {
        let body = Data(("{\"a\":\"" + String(repeating: "x", count: 20_000) + "\"}").utf8)
        let out = try ResponseProjection.project(body: body, spec: .init(maxCharacters: 1000))
        #expect(out.truncated && out.text.hasSuffix("[Truncated: the result exceeded 1000 characters.]"))
    }
}
