import Testing
import Foundation
@testable import Strata

/// Against a real sshd, only when one is given: `TEST_RUNNER_SSH_IT_PORT` (a local port) and `TEST_RUNNER_SSH_IT_DIR`
/// (a folder with the keys its users accept). The setup: Debian sshd with users `pw` (password pw-secret),
/// `key` (the keys), `kbd` (keyboard-interactive only, kbd-secret), `twofa` (a key, then keyboard-interactive
/// otp-123456), and a second sshd reachable from it as `target` (the jump test). Skipped otherwise.
struct SSHIntegrationTests {
    static let port = ProcessInfo.processInfo.environment["SSH_IT_PORT"].flatMap(Int.init)
    static let dir = ProcessInfo.processInfo.environment["SSH_IT_DIR"]
    static var enabled: Bool { port != nil && dir != nil }

    private func key(_ name: String) throws -> String {
        try String(contentsOfFile: Self.dir! + "/" + name, encoding: .utf8)
    }

    private func client(prompt: SSHPromptHandler? = nil) -> (SSHClient, SSHStore) {
        let store = SSHStore(vault: InMemorySSHVault())
        return (SSHClient(checkHostKey: { try store.check($0) }, prompt: prompt), store)
    }

    private func hop(_ user: String, _ auths: [SSHAuth]) -> SSHHop {
        SSHHop(host: "127.0.0.1", port: Self.port!, user: user, auths: auths)
    }

    @Test(.enabled(if: enabled)) func password() async throws {
        let (client, store) = client()
        let r = try await client.exec([hop("pw", [.password("pw-secret")])], command: "whoami; echo err >&2; exit 3", timeout: .seconds(20))
        #expect(r.stdout.text == "pw\n" && r.stderr.text == "err\n" && r.exitStatus == 3)
        #expect(store.knownHosts.count == 1, "trusted on first use")
        await #expect(throws: SSHError.self) {
            _ = try await client.exec([hop("pw", [.password("wrong")])], command: "true", timeout: .seconds(20))
        }
    }

    @Test(.enabled(if: enabled), arguments: ["ed25519", "rsa_pem", "rsa_openssh", "ecdsa"])
    func keys(_ file: String) async throws {
        let (client, _) = client()
        let r = try await client.exec([hop("key", [.privateKey(try key(file), passphrase: nil)])], command: "whoami", timeout: .seconds(20))
        #expect(r.stdout.text == "key\n" && r.exitStatus == 0)
    }

    @Test(.enabled(if: enabled)) func encryptedKeys() async throws {
        let (client, _) = client()
        for file in ["ed25519_enc", "rsa_pem_enc"] {
            let r = try await client.exec([hop("key", [.privateKey(try key(file), passphrase: "hunter2")])], command: "whoami", timeout: .seconds(20))
            #expect(r.stdout.text == "key\n", "\(file)")
            do {
                _ = try await client.exec([hop("key", [.privateKey(try key(file), passphrase: "nope")])], command: "true", timeout: .seconds(20))
                Issue.record("a wrong passphrase got in")
            } catch let error as SSHError {
                #expect(error.errorDescription?.contains("passphrase") == true, "\(file): \(error)")
            }
        }
    }

    @Test(.enabled(if: enabled)) func generatedKeysWork() async throws {
        // The container accepts only its own keys; a generated key is checked for the format libssh2 reads.
        let (client, _) = client()
        let generated = SSHKeyGenerator.ed25519(comment: "t")
        do {
            _ = try await client.exec([hop("key", [.privateKey(generated.privateKey, passphrase: nil)])], command: "true", timeout: .seconds(20))
            Issue.record("an unknown key got in")
        } catch let error as SSHError {
            #expect(error.errorDescription?.contains("refused the key") == true, "read, signed, refused: \(error)")
        }
    }

    @Test(.enabled(if: enabled)) func keyboardInteractive() async throws {
        let (client, _) = client()
        let r = try await client.exec([hop("kbd", [.keyboardInteractive(["kbd-secret"])])], command: "whoami", timeout: .seconds(20))
        #expect(r.stdout.text == "kbd\n")
        // A password credential answers the password prompt too.
        let p = try await client.exec([hop("kbd", [.password("kbd-secret")])], command: "whoami", timeout: .seconds(20))
        #expect(p.stdout.text == "kbd\n")
    }

    @Test(.enabled(if: enabled)) func secondFactorGoesToThePrompt() async throws {
        final class Asked: @unchecked Sendable { var requests: [SSHPromptRequest] = [] }
        let asked = Asked()
        let (client, _) = client(prompt: { request in asked.requests.append(request); return ["otp-123456"] })
        let r = try await client.exec([hop("twofa", [.privateKey(try key("ed25519"), passphrase: nil)])], command: "whoami", timeout: .seconds(30))
        #expect(r.stdout.text == "twofa\n")
        #expect(asked.requests.count == 1 && asked.requests.first?.prompts.first?.echo == false)
    }

    @Test(.enabled(if: enabled)) func jumpHost() async throws {
        let (client, store) = client()
        let auth: [SSHAuth] = [.privateKey(try key("ed25519"), passphrase: nil)]
        let r = try await client.exec([hop("key", auth), SSHHop(host: "target", port: 22, user: "key", auths: auth)],
                                      command: "hostname; head -c 300000 /dev/zero | tr '\\0' x", timeout: .seconds(30))
        #expect(r.stdout.text.hasPrefix("target\n") && r.stdout.total == 7 + 300_000)
        #expect(store.knownHosts.map(\.hostPort).sorted() == ["127.0.0.1:\(Self.port!)", "target:22"])
    }

    @Test(.enabled(if: enabled)) func stdinTimeoutAndSFTP() async throws {
        let (client, _) = client()
        let h = [hop("pw", [.password("pw-secret")])]
        let sudo = try await client.exec(h, command: "sudo -S -p '' whoami", stdin: Data("pw-secret\n".utf8), timeout: .seconds(20))
        #expect(sudo.stdout.text == "root\n")
        let slow = try await client.exec(h, command: "echo started; sleep 30", timeout: .seconds(2))
        #expect(slow.timedOut && slow.stdout.text == "started\n")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        #expect(try await client.upload(h, data: payload, to: "blob.bin", timeout: .seconds(30)) == payload.count)
        let back = try await client.download(h, from: "blob.bin", limit: 1 << 20, timeout: .seconds(30))
        #expect(back.data == payload && !back.truncated)
        await #expect(throws: SSHError.self) { _ = try await client.download(h, from: "/nope/missing", limit: 10, timeout: .seconds(10)) }
    }

    @Test(.enabled(if: enabled)) func cancelling() async throws {
        let (client, _) = client()
        let task = Task { try await client.exec([hop("pw", [.password("pw-secret")])], command: "sleep 30", timeout: .seconds(60)) }
        try await Task.sleep(for: .seconds(2))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// Output that never pauses still ends at the timeout, and Stop still works.
    @Test(.enabled(if: enabled)) func endlessOutputTimesOutAndCancels() async throws {
        let (client, _) = client()
        let h = [hop("pw", [.password("pw-secret")])]
        let start = ContinuousClock.now
        let r = try await client.exec(h, command: "yes", timeout: .seconds(2))
        #expect(r.timedOut && ContinuousClock.now - start < .seconds(10))
        let task = Task { try await client.exec(h, command: "yes", timeout: .seconds(60)) }
        try await Task.sleep(for: .seconds(2))
        let stop = ContinuousClock.now
        task.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await task.value }
        #expect(ContinuousClock.now - stop < .seconds(3))
    }

    @Test(.enabled(if: enabled)) func changedHostKeyIsRefused() async throws {
        let (client, store) = client()
        try store.check(SSHHostKey(hostPort: "127.0.0.1:\(Self.port!)", type: "ssh-ed25519", fingerprint: "SHA256:old"))
        do {
            _ = try await client.exec([hop("pw", [.password("pw-secret")])], command: "true", timeout: .seconds(20))
            Issue.record("connected to a changed host")
        } catch let error as SSHError {
            guard case .hostKeyChanged = error else { Issue.record("\(error)"); return }
            #expect(error.errorDescription?.contains("Settings > SSH > Known hosts") == true)
        }
    }

    @Test(.enabled(if: enabled)) func certificate() async throws {
        let (client, _) = client()
        let cert = try key("certkey-cert.pub")
        let r = try await client.exec([hop("key", [.privateKey(try key("certkey"), passphrase: nil, certificate: cert)])],
                                      command: "whoami", timeout: .seconds(20))
        #expect(r.stdout.text == "key\n")
    }

    @Test(.enabled(if: enabled)) func theToolRunsAndPages() async throws {
        let store = SSHStore(vault: InMemorySSHVault())
        let tool = SSHTool(store: store, outputs: SSHOutputStore(),
                           client: SSHClient(checkHostKey: { try store.check($0) }, prompt: nil),
                           ask: { _ in .run }, asks: true, limit: 2000)
        let conversation = UUID()
        _ = await tool.run(name: SSHToolNames.credentialSave, arguments: #"{"name":"pw","password":"pw-secret"}"#, conversation: conversation, callID: nil)
        _ = await tool.run(name: SSHToolNames.serverSave,
                           arguments: #"{"name":"box","host":"127.0.0.1","port":\#(Self.port!),"user":"pw","credential":"pw"}"#,
                           conversation: conversation, callID: nil)
        let out = await tool.run(name: SSHToolNames.exec, arguments: #"{"server":"box","command":"seq 1 3000"}"#, conversation: conversation, callID: nil)
        #expect(!out.isError && out.text.hasPrefix("Exit code 0 · box · "), "\(out.text.prefix(200))")
        #expect(out.text.contains("Read them with ssh_output id=o1 stream=stdout offset=500"))
        let more = await tool.run(name: SSHToolNames.output, arguments: #"{"id":"o1","offset":500}"#, conversation: conversation, callID: nil)
        #expect(more.text.contains("[Showing characters 500–2500 of"))
    }
}
