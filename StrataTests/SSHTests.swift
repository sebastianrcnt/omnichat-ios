import Testing
import Foundation
import SwiftData
@testable import Strata

struct SSHKeyTests {
    @Test(arguments: SSHKeyFixtures.all.map(\.file))
    func readsThePublicHalfLikeSSHKeygen(_ file: String) throws {
        let key = SSHKeyFixtures.key(file)
        let info = try #require(SSHKeyFormat.inspect(key.privateKey))
        let type = String(key.publicKey.prefix { $0 != " " })
        if file == "rsapemenc" {
            #expect(info.encrypted && info.publicKey == nil && info.type == "ssh-rsa", "a legacy encrypted PEM hides everything")
            return
        }
        #expect(info.encrypted == (file == "edenc"))
        #expect(info.type == type)
        let line = try #require(info.publicKey)
        #expect(line.hasPrefix(key.publicKey), "\(line)")
        #expect(SSHKeyFormat.fingerprint(ofPublicKey: line) == key.fingerprint)
    }

    @Test func formatsAndSizes() throws {
        #expect(SSHKeyFormat.inspect(SSHKeyFixtures.key("ed").privateKey)?.format == .openSSH)
        #expect(SSHKeyFormat.inspect(SSHKeyFixtures.key("rsapem").privateKey)?.format == .pem)
        #expect(SSHKeyFormat.inspect(SSHKeyFixtures.key("rsap8").privateKey)?.bits == 1024)
        #expect(SSHKeyFormat.inspect(SSHKeyFixtures.key("ecp8").privateKey)?.type == "ecdsa-sha2-nistp384")
        #expect(SSHKeyFormat.inspect(SSHKeyFixtures.key("ed").privateKey)?.publicKey?.hasSuffix(" fixture-ed") == true, "the comment")
        #expect(SSHKeyFormat.inspect("ssh-ed25519 AAAA… not a private key") == nil)
        #expect(SSHKeyFormat.inspect("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n")?.format == .putty)
        // Pasted with CRLF and spaces around it.
        let crlf = "  \n" + SSHKeyFixtures.key("ed").privateKey.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        #expect(SSHKeyFormat.inspect(crlf)?.type == "ssh-ed25519")
    }

    @Test func generatesKeysThatReadBack() throws {
        let ed = SSHKeyGenerator.ed25519(comment: "phone")
        let info = try #require(SSHKeyFormat.inspect(ed.privateKey))
        #expect(info.format == .openSSH && !info.encrypted && info.type == "ssh-ed25519")
        #expect(info.publicKey == ed.publicKey && ed.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5") && ed.publicKey.hasSuffix(" phone"))
        #expect(ed.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n") && ed.privateKey.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))

        let rsa = try SSHKeyGenerator.rsa(bits: 2048, comment: "r")
        let rsaInfo = try #require(SSHKeyFormat.inspect(rsa.privateKey))
        #expect(rsaInfo.type == "ssh-rsa" && rsaInfo.bits == 2048 && rsaInfo.publicKey == rsa.publicKey)
    }

    @Test func wireFormatAndFingerprints() throws {
        var w = SSHWireWriter()
        w.mpint(Data([0x00, 0x00, 0x80, 0x01]))
        #expect(w.data == Data([0, 0, 0, 3, 0x00, 0x80, 0x01]), "no leading zeros, one zero before a high bit")
        let parsed = try #require(SSHKeyFormat.parsePublicKey("from=\"10.0.0.1\" " + SSHKeyFixtures.key("ed").publicKey + " me@host"))
        #expect(parsed.type == "ssh-ed25519" && parsed.comment == "me@host")
        #expect(SSHKeyFormat.fingerprint(ofBlob: parsed.blob) == SSHKeyFixtures.key("ed").fingerprint)
    }
}

struct SSHStoreTests {
    private func store() -> SSHStore { SSHStore(vault: InMemorySSHVault()) }

    @Test func savesReadsAndDeletes() throws {
        let s = store()
        try s.save(SSHCredential(name: "nas-admin", kind: .password, username: "admin", password: "pw"))
        try s.save(SSHCredential(name: "id_ed25519", kind: .privateKey, privateKey: SSHKeyFixtures.key("ed").privateKey))
        #expect(s.credentials.map(\.name) == ["id_ed25519", "nas-admin"])
        #expect(s.credential(named: "id_ed25519")?.publicKey?.hasPrefix(SSHKeyFixtures.key("ed").publicKey) == true, "filled in")
        try s.save(SSHServer(name: "nas", host: " 10.0.0.5 ", user: "admin", credential: "nas-admin"))
        #expect(s.server(named: "nas")?.host == "10.0.0.5")
        try s.deleteCredential("nas-admin")
        #expect(s.credential(named: "nas-admin") == nil && s.credentials.count == 1)
        try s.deleteServer("nas")
        #expect(s.servers.isEmpty)
    }

    @Test func refusesWhatCantWork() {
        let s = store()
        #expect(throws: SSHStoreError.self) { try s.save(SSHCredential(name: "has space", kind: .password, password: "x")) }
        #expect(throws: SSHStoreError.self) { try s.save(SSHCredential(name: "k", kind: .privateKey, privateKey: "not a key")) }
        #expect(throws: SSHStoreError.self) {
            try s.save(SSHCredential(name: "p", kind: .privateKey, privateKey: "PuTTY-User-Key-File-3: ssh-rsa\nEncryption: none\n"))
        }
        #expect(throws: SSHStoreError.self) { try s.save(SSHCredential(name: "p", kind: .password)) }
        #expect(throws: SSHStoreError.self) { try s.save(SSHServer(name: "a", host: "h", port: 70000, user: "u")) }
        #expect(throws: SSHStoreError.self) { try s.save(SSHServer(name: "a", host: "h", user: "u", jump: ["a"])) }
    }

    @Test func trustsOnFirstUseAndRefusesAChange() throws {
        let s = store()
        let key = SSHHostKey(hostPort: "nas:22", type: "ssh-ed25519", fingerprint: "SHA256:aaa")
        try s.check(key)
        try s.check(key)
        #expect(s.knownHosts.map(\.fingerprint) == ["SHA256:aaa"])
        var changed = key
        changed.fingerprint = "SHA256:bbb"
        #expect(throws: SSHError.hostKeyChanged(hostPort: "nas:22", type: "ssh-ed25519", expected: "SHA256:aaa", actual: "SHA256:bbb")) {
            try s.check(changed)
        }
        try s.forgetHost("nas:22")
        try s.check(changed)
        #expect(s.knownHost("nas:22")?.fingerprint == "SHA256:bbb")
    }

    @Test func credentialsOfferTheirMethods() {
        var c = SSHCredential(name: "k", kind: .privateKey, password: "sudo-pw", privateKey: "KEY", passphrase: "pp")
        #expect(c.auths == [.privateKey("KEY", passphrase: "pp"), .password("sudo-pw")])
        c.kind = .keyboardInteractive
        c.answers = ["a", "b"]
        #expect(c.auths == [.keyboardInteractive(["a", "b"]), .password("sudo-pw")])
    }
}

struct SSHArgumentTests {
    @Test func readsLeniently() {
        let a = SSHArguments(json: #"{"port":"2222","timeout":30.0,"jump":["a","b"],"answers":"one\ntwo words\n","command":"  ls  ","flag":true}"#)
        #expect(a.int("port") == 2222 && a.int("timeout") == 30)
        #expect(a.list("jump") == ["a", "b"])
        #expect(a.lines("answers") == ["one", "two words"])
        #expect(a.string("command") == "ls" && a.raw("command") == "  ls  ")
        #expect(a.string("flag") == "true" && a.string("missing") == nil)
        #expect(SSHArguments(json: "not json").values.isEmpty)
    }

    @Test func parsesAddresses() {
        #expect(SSHTargetResolver.parseAddress("me@host:2222")! == ("me", "host", 2222))
        #expect(SSHTargetResolver.parseAddress("host")! == (nil, "host", nil))
        #expect(SSHTargetResolver.parseAddress("ssh://a@[fe80::1]:22")! == ("a", "fe80::1", 22))
        #expect(SSHTargetResolver.parseAddress("fe80::1")! == (nil, "fe80::1", nil), "a bare v6 address has no port")
        #expect(SSHTargetResolver.parseAddress("") == nil)
    }

    @Test func resolvesServersCredentialsAndJumps() throws {
        let s = SSHStore(vault: InMemorySSHVault())
        try s.save(SSHCredential(name: "bastion-key", kind: .privateKey, privateKey: SSHKeyFixtures.key("ed").privateKey))
        try s.save(SSHCredential(name: "nas-pw", kind: .password, password: "pw"))
        try s.save(SSHServer(name: "bastion", host: "b.example", port: 2200, user: "jump", credential: "bastion-key"))
        try s.save(SSHServer(name: "nas", host: "10.0.0.5", user: "admin", credential: "nas-pw", jump: ["bastion", "x@inner:23"]))

        let t = try SSHTargetResolver.resolve(SSHArguments(["server": "nas", "password": "inline"]), store: s)
        #expect(t.key == "nas" && t.label == "nas")
        #expect(t.hops.map(\.label) == ["jump@b.example:2200", "x@inner:23", "admin@10.0.0.5"])
        #expect(t.hops[0].auths.first?.method == "publickey", "a saved jump host signs in with its own credential")
        #expect(t.hops[2].auths == [.password("inline"), .password("pw")], "inline first, then the saved credential")
        #expect(t.hops[1].auths == t.hops[2].auths, "an address jump uses the target's")

        let adHoc = try SSHTargetResolver.resolve(SSHArguments(["host": "Example.org", "user": "me", "port": "2022", "password": "x"]), store: s)
        #expect(adHoc.key == "me@example.org:2022" && adHoc.label == "me@Example.org:2022" && adHoc.hops.count == 1)
        let viaServerField = try SSHTargetResolver.resolve(SSHArguments(["server": "me@h", "password": "x"]), store: s)
        #expect(viaServerField.hops.map(\.label) == ["me@h"])

        #expect(throws: SSHStoreError.self) { try SSHTargetResolver.resolve(SSHArguments(["server": "nope"]), store: s) }
        #expect(throws: SSHStoreError.self) { try SSHTargetResolver.resolve(SSHArguments(["host": "h"]), store: s) }
        #expect(throws: SSHStoreError.self) { try SSHTargetResolver.resolve(SSHArguments(["host": "h", "user": "u", "credential": "nope"]), store: s) }
        #expect(throws: SSHStoreError.self) { try SSHTargetResolver.resolve(SSHArguments(["host": "h", "user": "u", "private_key": "junk"]), store: s) }
        do {
            _ = try SSHTargetResolver.resolve(SSHArguments(["server": "nope"]), store: s)
        } catch {
            #expect(error.localizedDescription.contains("Saved servers: bastion, nas."))
        }
    }

    @Test func importsSSHConfig() {
        let config = """
        Host *
            User fallback
            IdentityFile ~/.ssh/id_default

        # the NAS
        Host nas nas-alias
            HostName 10.0.0.5
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
            ProxyJump bastion

        Host bastion
            HostName=b.example.com
            User jumper

        Host *.internal !skip
            User nobody
        """
        let entries = SSHConfigImport.parse(config)
        #expect(entries.map(\.server.name) == ["nas", "nas-alias", "bastion"])
        let nas = entries[0].server
        #expect(nas.host == "10.0.0.5" && nas.port == 2222 && nas.user == "fallback" && nas.jump == ["bastion"])
        #expect(entries[0].identity == "id_ed25519" && nas.credential == "id_ed25519")
        #expect(entries[2].server.host == "b.example.com" && entries[2].server.user == "jumper" && entries[2].identity == "id_default")
    }
}

struct SSHMaskTests {
    static let args = #"{"server":"nas","command":"uptime","password":"hunter2","private_key":"-----BEGIN…","stdin":"pw\n"}"#

    @Test func theUIGetsArgumentsWithoutSecretsWhileACallRuns() {
        let record = ToolCallRecord(id: "c", name: SSHToolNames.exec, arguments: Self.args, result: "", isError: false)
        let shown = record.primaryArgument
        #expect(!shown.contains("hunter2") && !shown.contains("BEGIN") && !shown.contains("pw\\n"))
        #expect(shown.contains("uptime") && shown.contains(SSHMask.dots))
        let display = SSHCallDisplay(tool: SSHToolNames.exec, arguments: shown, output: "")
        #expect(display.server == "nas" && display.command == "uptime")
        #expect(display.secrets.allSatisfy { $0.value == SSHMask.dots } && display.secrets.count == 3)
    }

    @Test func aFinishedCallKeepsItsArgumentsAndResultForTheCard() {
        let result = "Exit code 0 · nas · 0.2s\n<stdout>\nup 3 days\n</stdout>"
        let record = ToolCallRecord(id: "c", name: SSHToolNames.exec, arguments: Self.args, result: result, isError: false)
        let shown = record.displayOnly
        #expect(shown.result == result, "the card shows the output after a relaunch")
        let call = FeedCall(record: shown)
        #expect(call.tool == SSHToolNames.exec && call.argument == Self.args && call.output == result)
        let cards = ActivityFeed.cards(calls: [call], sources: [:])
        #expect(cards.first?.kind == .ssh(tool: SSHToolNames.exec, arguments: Self.args))
        let display = SSHCallDisplay(tool: SSHToolNames.exec, arguments: Self.args, output: result)
        #expect(display.secrets.first { $0.label == "Password" }?.value == "hunter2", "revealed on tap")
        #expect(display.meta(running: false, failed: false) == nil)
        #expect(SSHResultLine.streams(result).stdout == "up 3 days")
    }

    @Test func linesSayWhatHappened() {
        func title(_ tool: String, _ args: String, _ output: String = "", running: Bool = false, failed: Bool = false) -> String {
            SSHCallDisplay(tool: tool, arguments: args, output: output).title(running: running, failed: failed).map(\.text).joined()
        }
        #expect(title(SSHToolNames.exec, Self.args, running: true) == "Running uptime on nas…")
        #expect(title(SSHToolNames.exec, Self.args, "Exit code 0 · nas · 0.1s\n<stdout></stdout>") == "Ran uptime on nas")
        #expect(title(SSHToolNames.exec, Self.args, "Error: the user declined to run this.", failed: true) == "Didn't run uptime on nas")
        #expect(title(SSHToolNames.exec, #"{"host":"h","user":"u","command":"a\nb"}"#) == "Ran a … on u@h")
        #expect(title(SSHToolNames.credentialSave, #"{"name":"k","password":"x"}"#) == "Saved credential k")
        let failed = SSHCallDisplay(tool: SSHToolNames.exec, arguments: Self.args, output: "Exit code 2 · nas · 0.1s\n<stdout></stdout>")
        #expect(failed.meta(running: false, failed: false) == "Exit 2")
        #expect(SSHMask.resultIsSecret(SSHToolNames.credentialGet) && !SSHMask.resultIsSecret(SSHToolNames.credentialList))
    }
}

struct SSHApprovalTests {
    @Test func asksUnlessTurnedOffOrAlwaysAllowed() {
        #expect(SSHApprovalPolicy.needsApproval(asks: true, alwaysAllowed: false))
        #expect(!SSHApprovalPolicy.needsApproval(asks: true, alwaysAllowed: true))
        #expect(!SSHApprovalPolicy.needsApproval(asks: false, alwaysAllowed: false))
    }

    @Test func alwaysIsSavedForTheTargetAndDenyStops() async throws {
        let store = SSHStore(vault: InMemorySSHVault())
        let approval = SSHApproval(target: "nas", server: "nas", action: .exec(command: "ls"))
        final class Count: @unchecked Sendable { var n = 0 }
        let asked = Count()
        #expect(await SSHApprovalPolicy.approve(approval, asks: true, store: store) { _ in asked.n += 1; return .always })
        #expect(store.isAlwaysAllowed("nas") && store.alwaysAllowed == ["nas"])
        #expect(await SSHApprovalPolicy.approve(approval, asks: true, store: store) { _ in asked.n += 1; return .deny })
        #expect(asked.n == 1, "not asked again")
        try store.setAlwaysAllowed(false, target: "nas")
        #expect(await !SSHApprovalPolicy.approve(approval, asks: true, store: store) { _ in .deny })
        #expect(await SSHApprovalPolicy.approve(approval, asks: false, store: store) { _ in .deny }, "the switch is off")
    }

    @Test func aDeniedCommandNeverConnects() async throws {
        let store = SSHStore(vault: InMemorySSHVault())
        try store.save(SSHServer(name: "nas", host: "203.0.113.1", user: "u"))
        let tool = SSHTool(store: store, outputs: SSHOutputStore(),
                           client: SSHClient(checkHostKey: { _ in Issue.record("connected") }, prompt: nil),
                           ask: { approval in
                               #expect(approval == SSHApproval(target: "nas", server: "nas", action: .exec(command: "rm -rf /tmp/x")))
                               return .deny
                           }, asks: true)
        let out = await tool.run(name: SSHToolNames.exec, arguments: #"{"server":"nas","command":"rm -rf /tmp/x","password":"p"}"#,
                                 conversation: nil, callID: nil)
        #expect(out.isError && out.text.hasPrefix("Error: the user declined"))
    }

    @MainActor
    @Test func requestsBelongToTheirChatAndCall() async {
        let requests = SSHRequests()
        let chat = UUID()
        let approval = SSHApproval(target: "nas", server: "nas", action: .exec(command: "ls"))
        let task = Task { await requests.askApproval(approval, conversation: chat, callID: "c1") }
        while requests.all.isEmpty { await Task.yield() }
        #expect(requests.pending(conversation: chat).count == 1 && requests.pending(conversation: UUID()).isEmpty)
        let request = try! #require(requests.request(forCall: "c1", conversation: chat))
        requests.answer(request.id, .approval(.always))
        #expect(await task.value == .always && requests.all.isEmpty)

        let cancelled = Task { await requests.askPrompt(SSHPromptRequest(hop: "h", name: "", instruction: "", prompts: []), conversation: chat, callID: "c2") }
        while requests.all.isEmpty { await Task.yield() }
        cancelled.cancel()
        #expect(await cancelled.value == nil, "a stopped reply gives up the prompt")
    }

    /// Servers without call ids send `call_0` in every chat: each chat's feed finds only its own card.
    @MainActor
    @Test func twoChatsWithTheSameCallIDSeeTheirOwnCards() async throws {
        let requests = SSHRequests()
        let chatA = UUID(), chatB = UUID()
        let approval = SSHApproval(target: "nas", server: "nas", action: .exec(command: "uptime"))
        let prompt = SSHPromptRequest(hop: "u@b", name: "", instruction: "", prompts: [.init(text: "Code:", echo: false)])
        let a = Task { await requests.askApproval(approval, conversation: chatA, callID: "call_0") }
        let b = Task {
            await ToolContext.$conversationID.withValue(chatB) {
                await ToolContext.$callID.withValue("call_0") {
                    await requests.ask(SSHRequests.Request(kind: .prompt(prompt)))
                }
            }
        }
        while requests.all.count < 2 { await Task.yield() }

        let inA = try #require(requests.request(forCall: "call_0", conversation: chatA))
        let inB = try #require(requests.request(forCall: "call_0", conversation: chatB))
        #expect(inA.kind == .approval(approval))
        #expect(inB.kind == .prompt(prompt), "the request takes its chat and call from the tool context")
        #expect(requests.request(forCall: "call_0", conversation: UUID()) == nil)
        #expect(requests.request(forCall: "call_0", conversation: nil) == nil)

        requests.answer(inB.id, .prompt(["123456"]))
        #expect(await b.value == .prompt(["123456"]))
        #expect(requests.request(forCall: "call_0", conversation: chatA) == inA, "answering one chat leaves the other waiting")
        requests.answer(inA.id, .approval(.run))
        #expect(await a.value == .run && requests.all.isEmpty)
    }
}

struct SSHToolTests {
    private func tool(_ store: SSHStore) -> SSHTool {
        SSHTool(store: store, outputs: SSHOutputStore(), client: SSHClient(checkHostKey: { _ in }, prompt: nil), ask: { _ in .run }, asks: true)
    }

    @Test func savesListsAndGetsCredentials() async throws {
        let store = SSHStore(vault: InMemorySSHVault())
        let t = tool(store)
        let key = SSHKeyFixtures.key("edenc").privateKey.replacingOccurrences(of: "\n", with: "\\n")
        let saved = await t.run(name: SSHToolNames.credentialSave, arguments: #"{"name":"laptop","private_key":"\#(key)"}"#, conversation: nil, callID: nil)
        #expect(!saved.isError && saved.text.contains("encrypted and no passphrase") && saved.text.contains("Public key: ssh-ed25519 "))
        _ = await t.run(name: SSHToolNames.credentialSave, arguments: #"{"name":"otp","answers":["123","456"]}"#, conversation: nil, callID: nil)
        let list = await t.run(name: SSHToolNames.credentialList, arguments: "{}", conversation: nil, callID: nil)
        #expect(list.text.contains("- laptop: ED25519 · OpenSSH · encrypted") && list.text.contains("- otp: 2 answers"))
        #expect(!list.text.contains("BEGIN"))
        let got = await t.run(name: SSHToolNames.credentialGet, arguments: #"{"name":"otp"}"#, conversation: nil, callID: nil)
        #expect(got.text.contains("answers:\n123\n456"))
        let missing = await t.run(name: SSHToolNames.credentialGet, arguments: #"{"name":"nope"}"#, conversation: nil, callID: nil)
        #expect(missing.isError)
    }

    @Test func keygenSavesAndReturnsThePublicKey() async throws {
        let store = SSHStore(vault: InMemorySSHVault())
        let out = await tool(store).run(name: SSHToolNames.keygen, arguments: #"{"name":"phone"}"#, conversation: nil, callID: nil)
        let line = try #require(out.text.split(separator: "\n").last.map(String.init))
        #expect(line.hasPrefix("ssh-ed25519 ") && line.hasSuffix(" phone"))
        #expect(store.credential(named: "phone")?.publicKey == line && store.credential(named: "phone")?.kind == .privateKey)
        let again = await tool(store).run(name: SSHToolNames.keygen, arguments: #"{"name":"phone"}"#, conversation: nil, callID: nil)
        #expect(again.isError, "never replaces a key")
    }

    @Test func serversFromArgumentsAndSSHConfig() async throws {
        let store = SSHStore(vault: InMemorySSHVault())
        let t = tool(store)
        let bad = await t.run(name: SSHToolNames.serverSave, arguments: #"{"name":"nas","host":"h","user":"u","credential":"nope"}"#, conversation: nil, callID: nil)
        #expect(bad.isError && bad.text.contains("ssh_credential_save"))
        let config = "Host web\\n  HostName web.example\\n  User deploy\\n  IdentityFile ~/.ssh/id_web\\n"
        let imported = await t.run(name: SSHToolNames.serverSave, arguments: #"{"ssh_config":"\#(config)"}"#, conversation: nil, callID: nil)
        #expect(imported.text.contains("- web: deploy@web.example") && imported.text.contains("ssh_credential_save name=id_web"))
        let list = await t.run(name: SSHToolNames.serverList, arguments: "{}", conversation: nil, callID: nil)
        #expect(list.text == "- web: deploy@web.example, credential id_web")
    }

    @Test func outputIsClippedAndPaged() {
        let text = (1...1000).map(String.init).joined(separator: "\n")
        let clipped = SSHOutputFormat.clip(text, limit: 400, id: "o1", stream: "stdout")
        #expect(clipped.clipped && clipped.text.hasPrefix("1\n2\n") && clipped.text.hasSuffix("999\n1000"))
        #expect(clipped.text.contains("Read them with ssh_output id=o1 stream=stdout offset=100."))
        let slice = SSHOutputFormat.slice(text, offset: 100, limit: 50, id: "o1", stream: "stdout")
        #expect(slice.hasSuffix("[Showing characters 100–150 of \(text.count). Call ssh_output with id=o1 stream=stdout offset=150 to read more.]"))
        #expect(SSHOutputFormat.slice("abc", offset: 0, limit: 50, id: "o1", stream: "stdout") == "abc\n\n[End of output, 3 characters total.]")

        var result = SSHExecResult(stdout: SSHOutput(Data("ok\n".utf8)), stderr: SSHOutput(), exitStatus: 0, duration: .milliseconds(1500))
        let target = SSHTarget(hops: [], key: "nas", label: "nas")
        let out = SSHOutputFormat.exec(result, target: target, limit: 1000, outputs: SSHOutputStore(), conversation: nil)
        #expect(out == "Exit code 0 · nas · 1.5s\n<stdout>\nok\n</stdout>")
        #expect(SSHResultLine(out) == SSHResultLine("Exit code 0 · x")) // parses
        result.timedOut = true
        #expect(SSHResultLine(SSHOutputFormat.exec(result, target: target, limit: 1000, outputs: SSHOutputStore(), conversation: nil))?.timedOut == true)
    }

    @Test func keepsTheStartAndEndOfHugeOutput() {
        var out = SSHOutput()
        out.append(Data(repeating: 0x61, count: SSHOutput.headCap))
        out.append(Data(repeating: 0x62, count: SSHOutput.tailCap + 10))
        #expect(out.total == SSHOutput.headCap + SSHOutput.tailCap + 10 && out.omitted == 10)
        #expect(out.text.contains("[… 10 bytes left out …]"))
    }
}

struct SSHPromptAndGroupTests {
    @Test func theSSHSectionComesOnlyWithTheSSHTools() {
        #expect(AppPrompt.text(tools: true, python: false, ssh: true).hasSuffix(AppPrompt.ssh))
        #expect(!AppPrompt.text(tools: true, python: true, browser: true, skills: true).contains("ssh_"))
        #expect(AppPrompt.text(tools: false, python: false, ssh: true) == AppPrompt.base)
        #expect(AppPrompt.ssh.contains("nohup") && AppPrompt.ssh.contains("tmux") && AppPrompt.ssh.contains("ssh_credential_save"))
    }

    @Test func theGroupNamesItsTools() {
        #expect(ToolGroup.group(of: SSHToolNames.exec) == .ssh && ToolGroup.group(of: SSHToolNames.keygen) == .ssh)
        let names = ToolDefinition.available(groups: [.ssh], images: false).map(\.function.name)
        #expect(names == ["show_html"] + SSHToolNames.all)
        #expect(!ToolDefinition.available(groups: [.web, .python], images: true).map(\.function.name).contains(SSHToolNames.exec))
        #expect(ToolGroup.ssh.refusal == "The user turned off SSH for this chat. Answer without it, or ask them to turn it on.")
        #expect(ToolGroup.decode(ToolGroup.encode([.ssh, .web])) == [.web, .ssh])
    }

    @MainActor
    @Test func offFromSettingsUntilTurnedOn() {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.defaultToolGroups.contains(.ssh))
        settings.sshEnabled = true
        #expect(AppSettings(defaults: defaults).defaultToolGroups.contains(.ssh))
    }

    @Test func definitionsAreStable() throws {
        // Part of the cached prefix: the same bytes every time.
        let a = try ChatRequest.encoder.encode(ToolDefinition.ssh)
        let b = try ChatRequest.encoder.encode(ToolDefinition.ssh)
        #expect(a == b)
        for definition in ToolDefinition.ssh {
            #expect(definition.function.parameters.required.allSatisfy { definition.function.parameters.properties[$0] != nil })
        }
    }
}

/// The SSH group follows the chat's frozen tool set: offered from the first request when on, refused (not removed)
/// when turned off later, added with its prompt section when turned on later.
@MainActor
struct SSHToolSwitchTests {
    private func rig(sshOn: Bool, _ plans: [([ChatDelta], ProgrammableStreamer.End)] = [])
        throws -> (ChatController, ModelContext, ProgrammableStreamer, ModelContainer) {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let settings = AppSettings(defaults: defaults)
        settings.pythonEnabled = false
        settings.generateTitles = false
        settings.sshEnabled = sshOn
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        controller.skills = SkillStore(builtIn: [], directory: nil)
        return (controller, container.mainContext, streamer, container)
    }

    private func system(_ request: ChatRequest) -> String {
        guard let first = request.messages.first, first.role == "system", case .text(let t) = first.content else { return "" }
        return t
    }

    private func send(_ controller: ChatController, _ context: ModelContext, _ text: String, _ chat: Conversation) async {
        controller.send(text: text, images: [], conversation: chat, context: context)
        await controller.waitUntilIdle()
    }

    @Test func onAtTheStartStaysOfferedWhenTurnedOff() async throws {
        let call = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: SSHToolNames.exec, arguments: #"{"server":"nas","command":"ls"}"#)])
        let (controller, context, streamer, container) = try rig(sshOn: true, [([ChatDelta(content: "ok")], .finish), ([call], .finish), ([ChatDelta(content: "done")], .finish)])
        _ = container
        let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        context.insert(chat)
        await send(controller, context, "hi", chat)
        let first = streamer.requests[0]
        #expect((first.tools ?? []).map(\.function.name).contains(SSHToolNames.exec))
        #expect(system(first).contains(AppPrompt.ssh))
        controller.setTool(.ssh, on: false, conversation: chat)
        await send(controller, context, "list files", chat)
        let second = streamer.requests[1]
        #expect(try ChatRequest.encoder.encode(second.tools ?? []) == ChatRequest.encoder.encode(first.tools ?? []))
        #expect(system(second) == system(first))
        let result = streamer.requests[2].messages.last { $0.role == "tool" }
        #expect(result?.content == .text(ToolGroup.ssh.refusal))
    }

    @Test func offAtTheStartIsAddedWhenTurnedOn() async throws {
        let (controller, context, streamer, container) = try rig(sshOn: false)
        _ = container
        let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        context.insert(chat)
        await send(controller, context, "hi", chat)
        #expect(!(streamer.requests[0].tools ?? []).map(\.function.name).contains(SSHToolNames.exec))
        #expect(!system(streamer.requests[0]).contains(AppPrompt.ssh))
        controller.setTool(.ssh, on: true, conversation: chat)
        await send(controller, context, "check the nas", chat)
        #expect((streamer.requests[1].tools ?? []).map(\.function.name).contains(SSHToolNames.exec))
        #expect(system(streamer.requests[1]).contains(AppPrompt.ssh))
        #expect(chat.offeredTools?.contains(.ssh) == true)
    }
}

struct SSHRedactionTests {
    @Test func debugBundlesHideSSHSecrets() {
        let call = #"{"name":"ssh_exec","arguments":"{\"server\":\"nas\",\"password\":\"hunter2\",\"stdin\":\"hunter2\\n\",\"command\":\"uptime\"}"}"#
        let out = DebugRedaction.redact(call)
        #expect(!out.contains("hunter2"))
        #expect(out.contains("uptime"))
        #expect(out.contains(#"\"server\":\"nas\""#))

        let key = "x -----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY----- y"
        let redactedKey = DebugRedaction.redact(key)
        #expect(!redactedKey.contains("b3BlbnNzaC1rZXktdjEAAAAA"))
        #expect(redactedKey.hasSuffix(" y"))

        let result = #"{"content":"name: nas\npassword: hunter2\nuser: pw"}"#
        let redactedResult = DebugRedaction.redact(result)
        #expect(!redactedResult.contains("hunter2"))
        #expect(redactedResult.contains(#"\nuser: pw"#))
    }
}
