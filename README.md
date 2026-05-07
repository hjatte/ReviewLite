# ReviewLite

A personal "what was I doing five minutes ago?" tool for macOS. Captures periodic
screenshots of your screen, OCRs them so you can search what you saw, and silently
records local audio + transcripts of meetings (Zoom, Teams, Slack huddles, FaceTime,
Discord, Webex) so you can recap calls.

Everything runs on-device. Nothing is uploaded. Optional: bring your own Anthropic
or OpenAI API key to auto-generate structured meeting minutes from transcripts.

---

## If this saves you time…

I built this for myself and decided to share it. If you find it useful, you can
tip me here:

> _(tip jar link — to be added)_

No subscription, no account, no telemetry. Use it as long as you like.

---

## Install

Apple Silicon Mac running macOS 14 (Sonoma) or later.

1. Download the latest `ReviewLite.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag `ReviewLite.app` into `/Applications`.
3. **First launch only:** right-click `ReviewLite.app` → **Open** → confirm.
   (The app is signed locally rather than with a paid Apple Developer ID, so macOS
   asks you to confirm once. Subsequent launches just work.)
4. Grant **Screen Recording** and **Microphone** permission when prompted.

That's it. The icon lives in the menu bar.

If your Mac is locked down with strict Gatekeeper rules and step 3 still won't open,
run this in Terminal once:

```
xattr -d com.apple.quarantine /Applications/ReviewLite.app
```

## What it does

- **Timeline.** A scrubbable per-day view of your screen. Click play to scroll
  through frames in real-time; if you cross a meeting, the recorded audio plays
  back in sync.
- **Search.** Every captured frame is OCR'd via Apple's Vision framework. Type a
  phrase you remember seeing, get a list of moments where it appeared on screen.
- **Meeting auto-record.** When ReviewLite detects an active call (Zoom, Teams,
  Slack huddle, FaceTime, Discord, Webex), it records mic + system audio silently
  in the background and runs a local Whisper transcription afterwards. No
  notification, no banner, no permission per call.
- **AI minutes (optional).** Add an Anthropic Claude or OpenAI API key in
  Settings; one click generates structured meeting minutes — Summary, Key Points,
  Decisions, Action Items, Open Questions.

## Privacy

- All screen frames, audio recordings, and transcripts live in the app's sandbox
  container at `~/Library/Containers/com.reviewlite.app/Data/...`. Nothing leaves
  your Mac.
- One exception: WhisperKit downloads its speech model from Hugging Face once on
  first transcription (~140 MB).
- One opt-in exception: if you set an AI API key, transcript text is sent over
  HTTPS to your chosen provider only when you click "Generate minutes" — never
  audio, never frames.
- Old data is automatically deleted after the retention window you set in
  Settings (default 30 days), including frames, OCR text, audio, transcripts, and
  AI-generated minutes.
- **Recording meetings is your responsibility.** In many jurisdictions you must
  inform participants. Use accordingly.

## Configuration

Menu bar icon → Settings:

- **Capture quality** (5 presets, with a live disk-usage estimate)
- **Frame interval** (1–30 s, default 3 s)
- **Retention** (1–365 days, default 30)
- **Excluded apps** — frames captured while these apps are frontmost are skipped.
  Defaults: `com.apple.loginwindow`, `com.apple.ScreenSaverEngine`. Add your own.
- **AI summary** — provider picker + API key field (key stored in the app's
  sandboxed preferences, not transmitted anywhere except to your chosen provider
  when you generate minutes).

## Known limits

- Apple Silicon only.
- Browser-based meetings (Google Meet in Chrome / Safari) aren't auto-detected by
  the meeting monitor; use the "Record Meeting Now" menu item for those.
- Speech transcript is one stream — no speaker diarization yet.
- Default Whisper model is English-only (`openai_whisper-base.en`); change
  `modelName` in `Sources/Meetings/Transcriber.swift` for multilingual.

---

## Building from source

Requires Xcode 16+ and `xcodegen` (`brew install xcodegen`).

```bash
git clone https://github.com/<your-username>/ReviewLite
cd ReviewLite
xcodegen generate
xcodebuild -project ReviewLite.xcodeproj -scheme ReviewLite -configuration Debug build
```

The built app lands in `~/Library/Developer/Xcode/DerivedData/ReviewLite-…/Build/Products/Debug/ReviewLite.app`.

Two configurations:

- **Debug** — ad-hoc signed; for local development.
- **Release** — optimised, ready to be signed for distribution.

For distributing your own builds, you'd need an Apple Developer ID (US$99/year)
and would change `CODE_SIGN_IDENTITY` in the Release config of `project.yml`.

## Architecture (short version)

```
ReviewLite/
├── App.swift                      # @main + AppDelegate
├── Logging.swift                  # os.Logger subsystems
├── MenuBar/MenuBarController.swift
├── Capture/                       # ScreenCaptureKit + Vision OCR + window tracking
├── Meetings/                      # Meeting detection, audio capture, WhisperKit, AI minutes
├── Storage/                       # SQLite + FTS5 + retention
├── Settings/                      # UserDefaults preferences
├── AISummary/                     # Anthropic + OpenAI clients for meeting minutes
├── Permissions/                   # Screen Recording / Mic prompt helpers
├── UI/                            # SwiftUI views: Timeline, Meetings, Search, Settings
└── Resources/                     # Info.plist, entitlements, AppIcon.icns
```

## Contributing & support

This is a personal project I maintain in my spare time. PRs welcome but I make no
SLA promises on response times. File an issue if something's broken; I'll get to
it when I can.

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with Rewind AI. It's an independent personal tool
inspired by the same use case.
