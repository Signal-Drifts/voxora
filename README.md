# Voxora

Record Meetings and Browser Audio.

Website: [https://signal-drifts.github.io/YoFile/suite.html?app=voxora](https://signal-drifts.github.io/YoFile/suite.html?app=voxora)

Current release: **v1.4**

Voxora is a small, free macOS recorder for audio playing on your Mac. It captures meeting audio from Zoom, Microsoft Teams, FaceTime, and browser calls, as well as browser audio such as YouTube. Everything stays on the machine.

## Why this exists

Meeting recorders increasingly require an account, upload calls to a server, join as a visible meeting bot, or place transcription behind a subscription. That is unnecessary when the audio is already playing on the Mac.

Voxora records through Apple's ScreenCaptureKit and writes the result locally. There is no account, cloud upload, telemetry, or meeting bot.

The app deliberately requires the user to confirm that they have permission before each recording. Recording laws and workplace policies vary, so everyone who needs to consent should be told before recording begins.

## What it does

- Records system audio from meetings, calls, browsers, media players, and other Mac apps
- Runs in a compact native window and remains available from the menu bar
- Supports Start, Pause, Resume, and Finish & Save
- Opens the save window only after the recording is finished
- Preserves an unsaved recording if the save window is cancelled
- Offers Save or Discard for a pending recording
- Resets the timer after a successful save or confirmed discard
- Optionally reduces low rumble, high-frequency hiss, and quiet background noise
- Saves standard recordings as M4A and noise-filtered recordings as WAV

## What it avoids

| Cloud meeting recorders | Voxora |
|---|---|
| Upload the conversation to a remote service | Audio stays on the Mac |
| Require an account or subscription | No account and no payment |
| Join the meeting as a bot | Records the Mac's system-audio stream |
| Hide export behind usage limits | Record and save without artificial caps |
| Add telemetry and online dependencies | No network code |

## How to use

Download the signed Apple Silicon installer from the [latest release](https://github.com/Signal-Drifts/voxora/releases/latest).

1. Open the DMG and drag Voxora into Applications.
2. Open Voxora and grant Screen & System Audio Recording permission when macOS asks.
3. Confirm that you have permission to record, then press Start.
4. Use Pause or Resume as needed, then press Finish & Save.
5. Choose a filename and location.

Voxora does not record the microphone in the current release. It records audio produced by the Mac, including the other side of supported calls.

## Noise Filter

The optional filter is conservative signal processing rather than AI source separation. It reduces rumble, softens high-frequency hiss, and attenuates low-level sound between spoken phrases. It cannot perfectly remove music, overlapping voices, keyboard sounds, or other loud sounds.

- Without Noise Filter: M4A
- With Noise Filter: WAV

## Tech stack

**Application**

- SwiftUI and AppKit — compact native macOS interface, save panels, alerts, and menu-bar controls
- ScreenCaptureKit — captures the Mac's system-audio stream
- AVFoundation — writes M4A recordings and processes WAV audio
- Core Graphics — checks and requests macOS capture permission

**Distribution**

- `swift test` verifies the speech-oriented cleanup pass against generated audio.
- `scripts/package-macos.sh` builds `Voxora.app`, compiles the icon catalog, applies hardened-runtime Developer ID signing, and creates a versioned DMG.
- Each package run preserves older installers and creates the next filename: `Voxora-1.1.dmg`, `Voxora-1.2.dmg`, `Voxora-1.3.dmg`, and so on.
- Public builds are Developer ID signed, submitted to Apple for notarization, and stapled before release.
- macOS 14 or later and Apple Silicon are the currently tested target.

## Build from source

Requirements: macOS 14 or later and Xcode with Swift 6.

```bash
chmod +x scripts/package-macos.sh
./scripts/package-macos.sh
```

To select a signing certificate explicitly:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/package-macos.sh
```

## License

MIT.
