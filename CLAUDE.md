# Voice Pilot

Project-level instructions. Loaded when working in this repo.

This file contains **only** project-specific identity and pointers. Global rules (Trust Contract, workflow, git discipline, banned phrases) live in `~/.claude/` and apply automatically. Do not duplicate them here.

---

## Project identity

- **Repo:** `/Users/fabianklainman/claude-apps/voice-pilot`
- **GitHub:** fabatmo/voice-pilot
- **Stack:** Swift / macOS 14+ (Sonoma or newer)
- **Virtualenv / deps:** `swift build -c release`
- **Run:** `.build/release/VoicePilot &`
- **Test:** `swift test (if tests exist)`

---

## Project-specific rule files

Loaded alongside this file when relevant:

- **`GIT_WORKFLOW.md`** — branching, merging, archiving rules for this repo
- **`DEV_RULES.md`** — import architecture, pre-commit checks, module structure (if present)
- **`.claude/memory/`** — per-project feedback memories (auto-loaded by Claude Code, if present)

---

## Project-specific context

Native macOS menu bar app for hands-free voice control of Claude Code CLI. Continuous listening (no wake word). Voice commands: enter, yes, no, cancel, scroll up/down. Voice prompts: naturally spoken, filler words cleaned, auto-submitted to terminal. Floating panel shows live transcript in bottom-right corner. Zero-latency local speech recognition (no API calls).

**Requirements:** macOS 14+ Sonoma or newer, Xcode Command Line Tools (`xcode-select --install`).

---

## Session start

Run the global session-start procedure from `~/.claude/WORKFLOW.md` §1, plus any project-specific checks defined in `DEV_RULES.md`.

---

## Session end

Run the global session-end procedure from `~/.claude/WORKFLOW.md` §8. All work on main. All branches merged or explicitly WIP. Zero stashes.
