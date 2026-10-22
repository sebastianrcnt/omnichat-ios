# OmniChat

A native chat app for iPhone, iPad and Mac that talks to the models you already have: your own API keys, your ChatGPT
plan, Anthropic's API, servers on your own network, or Apple's on-device model.

- **Bring your own model.** Any OpenAI-compatible server (OpenAI, OpenRouter, Ollama, LM Studio, vLLM, …), Sign in with
  ChatGPT, Anthropic's Messages API with prompt caching and extended thinking, and Apple's on-device model.
- **Tools.** Web search and page reading, Python (Pyodide), SSH to your own machines, maps, artifacts, and packages that
  add more.
- **Private by default.** No account, no analytics, no tracking. Chats stay on your device unless you turn on iCloud sync,
  and keys stay in the Keychain. See the [privacy policy](docs/privacy.md).

## Building

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Strata.xcodeproj
```

The `Strata` scheme builds the iOS app, `StrataMac` the Mac app. The code still uses the project's earlier name, Strata,
for targets and identifiers.

Design notes live in [docs/](docs/).

## Support

Questions and bug reports: [GitHub Issues](https://github.com/sebastianrcnt/omnichat-ios/issues). See
[docs/support.md](docs/support.md).

## License

The app is under the [GNU GPL version 3](LICENSE) or later; the package SDK under the MIT License. Details, third-party
components and the trademark note are in [NOTICE.md](NOTICE.md). Contributions are accepted under the [CLA](CLA.md).
