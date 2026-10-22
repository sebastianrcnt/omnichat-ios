---
title: OpenChat Privacy Policy
permalink: /privacy/
---

# OpenChat Privacy Policy

Effective October 22, 2026.

OpenChat is made by an independent developer ("we"). This policy covers the OpenChat apps for iPhone, iPad and Mac.

## The short version

- We don't collect any data. There is no OpenChat account, no analytics, no advertising, no tracking and no server of
  ours that your chats pass through.
- Your messages go only to the model services and servers **you** choose to connect, from your device.
- Your chats are stored on your device. If you turn on iCloud sync, they are stored in your own private iCloud database,
  which we cannot read.

## What we collect

Nothing. We don't receive your chats, your API keys, your sign-ins, your contacts, your location or any usage
statistics. If you choose to share crash reports or diagnostics with app developers in your device's settings, Apple
may give us anonymous crash reports; you can turn that off at any time in Settings → Privacy & Security → Analytics &
Improvements.

## Where your data goes

OpenChat sends data directly from your device to services you set up or ask it to use:

- **Model connections.** When you send a message, the conversation (your messages, attachments, the system prompt and
  tool results) is sent to the model connection the chat uses: an OpenAI-compatible server you add, your ChatGPT account
  (Sign in with ChatGPT), Anthropic's API, or a server on your own network. Their own privacy policies and terms apply to
  what they receive. Apple's on-device model runs on your device and sends nothing.
- **Web tools.** When the assistant searches the web or opens a page, your device requests the search results (from
  Bing, DuckDuckGo or Naver) and the pages directly. Those sites see your IP address and the search or page, as when you
  browse.
- **Python.** The first time code needs a Python package, the package files are downloaded from the jsDelivr CDN.
- **SSH.** Commands you approve run on the servers you add, over SSH.
- **Location.** Only when you ask the assistant to find places near you and allow location access, your approximate
  location is given to the assistant (and so to the chat's model connection) to answer.
- **Health.** Only if you turn on Health in Settings and allow the data types, the assistant can read the health data you
  allowed, when you ask about your health. The data is sent to the chat's model connection to answer, and you can limit
  it to on-device or local-network models. Health data is never synced to iCloud, never used for advertising and never
  sold. OpenChat never writes to Health.
- **Camera, photos, microphone.** Photos and files you attach are sent with your message. Dictation is turned into text
  on your device.

## Storage and sync

Chats, settings and files are stored on your device. API keys and sign-in tokens are stored in the Keychain.

iCloud sync is off by default for chats. If you turn it on, chats and settings are stored in your private iCloud database
(CloudKit) and keys in iCloud Keychain, protected by your Apple Account. We have no access to them. Turning on chat sync
turns off Health.

## Deleting your data

Delete a chat in the app, or delete the app to remove everything on the device. To remove synced data, turn off sync and
delete OpenChat's data in Settings → [your name] → iCloud → Manage Storage. To remove a sign-in, remove the connection;
you can also revoke OpenChat's access in your ChatGPT or other account settings.

## Children

OpenChat is not directed to children under 13 and we don't knowingly collect data from anyone.

## Changes

We will post changes to this policy here, with a new effective date.

## Contact

Questions about this policy: open an issue at
[github.com/sebastianrcnt/openchat-ios/issues](https://github.com/sebastianrcnt/openchat-ios/issues).
