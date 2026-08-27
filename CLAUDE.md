# Voice Pilot

Project-level instructions. Loaded when working in this repo.

This file contains **only** project-specific identity and pointers. Global rules (Trust Contract, workflow, git discipline, banned phrases) live in `~/.claude/` and apply automatically. Do not duplicate them here.

---

## Project identity

- **Repo:** `/Users/fabianklainman/claude-apps/voice-pilot`
- **GitHub:** fabatmo/voice-pilot
- **Stack:** Swift / macOS 26+ (Tahoe or newer)
- **Build + install:** `./build-install.sh` — builds, assembles and signs `/Applications/VoicePilot.app`
- **Run:** `open /Applications/VoicePilot.app` (menu bar accessory, `LSUIElement`)
- **Test:** `swift test` (no test target at present)

**Signing is not optional.** `build-install.sh` signs with the stable
`VoicePilot Dev` cert (`D4A1F9BB5292176F9D4537F16426491AF9888B83`). Never
ad-hoc sign — it rotates the CDHash and macOS revokes every TCC grant.
`security find-identity -v -p codesigning` reporting `0 valid identities` is
normal here (self-signed, untrusted) and does not block `codesign`.

---

## Project-specific rule files

Loaded alongside this file when relevant:

- **`GIT_WORKFLOW.md`** — branching, merging, archiving rules for this repo
- **`DEV_RULES.md`** — import architecture, pre-commit checks, module structure (if present)
- **`.claude/memory/`** — per-project feedback memories (auto-loaded by Claude Code, if present)

---

## Project-specific context

Native macOS menu bar app for hands-free dictation into the terminal and any
other app. Continuous listening, no wake word. Speech is typed into the
frontmost app via the Accessibility API, with clipboard paste as fallback;
middle-click submits. Floating panel shows the live transcript.

**Dictation only.** The former Voice Control and Prompt Builder modes, and the
three-way mode toggle, were removed in 2026-08. There are no spoken commands
(enter / yes / no / cancel / scroll) any more.

**Speech recognition** runs fully on-device — no audio leaves the machine.
Two selectable engines, switched from the menu bar (switching relaunches):

- **Analyzer** (default) — `SpeechAnalyzer` + `SpeechTranscriber`, macOS 26.
  No request-duration cap, endpointing from the model rather than a silence
  timer. Downloads its locale model on first run (~2s).
- **Legacy** — `SFSpeechRecognizer`, kept as a fallback. Subject to the ~60s
  per-request cap; the app restarts the recognizer without dropping audio.

Chosen at launch from `VOICEPILOT_ENGINE` (`analyzer`|`legacy`) or the
`VoicePilotSpeechEngine` user default.

**Requirements:** macOS 26 Tahoe or newer (`SpeechAnalyzer` is 26.0+), Xcode
Command Line Tools (`xcode-select --install`). Needs Microphone, Speech
Recognition, Accessibility and Automation permissions; macOS reads these once
at launch, so the app must be relaunched after any permission change.

**Debugging:** the app logs to `/tmp/voicepilot_debug.log` (path is per-bundle,
so side-by-side builds do not interleave). `./compare-engines.sh` extracts just
the delivered utterances. `./build-next.sh` builds a separate
`VoicePilot-Next.app` under its own bundle id for side-by-side evaluation —
never leave two builds listening at once, they will both type.

---

## Session start

Run the global session-start procedure from `~/.claude/WORKFLOW.md` §1, plus any project-specific checks defined in `DEV_RULES.md`.

---

## Session end

Run the global session-end procedure from `~/.claude/WORKFLOW.md` §8. All work on main. All branches merged or explicitly WIP. Zero stashes.
