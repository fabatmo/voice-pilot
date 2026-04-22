# Git Workflow — Voice Pilot

Project-level git rules. Extends `~/.claude/WORKFLOW.md` — does not replace it.

---

## Branch structure

```
main          ← always stable, always deployable
feature/*     ← one branch per feature or task
fix/*         ← one branch per bug fix
archive/*     ← retired branches, preserved for reference
```

No `dev` branch. No long-lived branches. No stacked branches.

---

## Rules

### Branching
- Never commit directly to main. Always branch first.
- Names: `feature/short-description` or `fix/short-description`.
- One branch = one task. If scope changes, finish or stash current before starting a new branch.
- Merge within 1–3 working sessions. Long-lived branches are a bug.

### Merging
- Before merging: verify the feature works (paste the verification signal).
- `git checkout main && git merge feature/whatever --no-ff`
- After merge: delete the branch (`git branch -d feature/whatever`).
- Push main to remote immediately.

### Stashes
- Temporary only. Apply or drop within the same session.
- More than 1 stash = something is wrong. Stop and clean up.

### Remote
- Push main after every merge.
- Push feature branches for backup if needed, but delete after merge.
- Never let main get ahead of remote by more than 1 merge.

### Archiving (never delete work)
- No branch is permanently deleted. Archive first.
- `git branch archive/branchname-YYYY-MM && git push origin archive/branchname-YYYY-MM`
- Then delete the original.
- Archive branches are read-only. Never commit to them.
- Review and prune fully-merged archives at major milestones.

---

## Session-start check

```bash
echo "=== Git Status ==="
git status
echo "=== Current Branch ==="
git branch --show-current
echo "=== All Branches ==="
git branch -a
echo "=== Stashes ==="
git stash list
echo "=== Unpushed Commits ==="
git log origin/main..main --oneline 2>/dev/null || echo "No remote tracking"
echo "=== Unmerged Feature Branches ==="
git branch --no-merged main
```

Paste the output. Fix any unexpected state before starting work.

---

## Session-end gate (ENFORCED)

**All completed work MUST be on main before the session ends.** Unmerged feature branches with working code = work lost next session.

```bash
# Step 1: Unmerged branches?
git branch --no-merged main

# Step 2: Main pushed?
git log origin/main..main --oneline

# Step 3: Stashes?
git stash list

# Step 4: Working tree clean?
git status
```

If any of these has unexpected output: fix before ending. Non-negotiable.

---

## Merge-before-new-work (ENFORCED)

Before `git checkout -b feature/new-thing`:

```bash
git branch --no-merged main
```

Any unmerged completed branches → merge them first. Don't skip this.

---

## One-branch-at-a-time

As a solo developer: you should almost never have more than 2 branches at once (`main` + one active `feature/*` or `fix/*`). Three+ branches = stop and consolidate.
