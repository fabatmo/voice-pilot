# Voice Pilot

Hands-free voice control for Claude Code CLI. A native macOS menu bar app that listens continuously and sends your voice commands directly to the terminal.

## What it does

- **Always-on listening** — no wake word, just talk
- **Voice commands** — say "enter", "yes", "no", "cancel", "scroll up/down"
- **Voice prompts** — speak naturally, it cleans up filler words and auto-submits to your terminal
- **Floating panel** — shows live transcript in bottom-right corner
- **Zero latency** — no API calls, all local speech recognition

## Requirements

- macOS 14+ (Sonoma or newer)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/fabianklainman/voice-pilot.git
cd voice-pilot
swift build -c release
```

## Run

```bash
.build/release/VoicePilot &
```

On first launch, macOS will ask for:
1. **Microphone permission** — required for speech recognition
2. **Accessibility permission** — required to send keystrokes to terminal

Go to System Settings → Privacy & Security to grant these.

## Usage

1. Open your terminal with Claude Code running
2. Start Voice Pilot
3. Talk — your speech appears in the floating panel
4. After 0.8s of silence, it auto-pastes and submits to the terminal

### Voice Commands

| Say | Action |
|-----|--------|
| "enter" / "submit" | Press Enter |
| "yes" / "confirm" / "one" | Type `y` + Enter |
| "no" / "deny" / "two" | Type `n` + Enter |
| "cancel" / "stop" | Send Ctrl+C |
| "scroll up" | Scroll up |
| "scroll down" | Scroll down |

Anything longer than 4 words is treated as a prompt — cleaned up and sent to the CLI.

## Auto-start at login

```bash
cp com.voicepilot.app.plist ~/Library/LaunchAgents/
```

Or create your own LaunchAgent pointing to the release binary.

## Stop

```bash
pkill VoicePilot
```

## How it works

- **Speech**: macOS native `SFSpeechRecognizer` — no Google, no API keys
- **Delivery**: AppleScript finds your terminal app and simulates paste + Enter
- **Cleanup**: Removes filler words (um, uh, like, you know) before sending
- Supports Terminal, iTerm2, Kitty, Alacritty, WezTerm, Ghostty

## License

MIT
