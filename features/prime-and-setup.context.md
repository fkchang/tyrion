# prime-and-setup — epic context

**Design record**: `docs/auto-engagement-options.md` (Option C, layers L1+L2). Background: `docs/beads-auto-hooking-analysis.md`, `docs/tyrion-auto-engagement.md`. **Codex adversarial review 2026-07-22**: findings folded into the feature file; the detail behind each criterion is below.

## Why

Beads auto-engages via SessionStart/PreCompact hooks running `bd prime`; Tyrion's trigger surface is pull-only. This epic makes Tyrion push. Verified 2026-07-22: beads has NOT refined its injection since the analysis doc (1.0.3 → 1.1.0 is a timeout fix + Cursor parity), so the tiered lean prime is an innovation, not catch-up.

## Design constraints

- **Inject state, not manuals.** Tyrion's skills carry the how; prime injects only state + pointers. Tier-1 ≤15 lines, rules block ≤5 lines.
- **One command, one tier matrix** (no `--compact` flag — dropped in review; a forced Tier-2 contradicted Tier-0 silence and had nothing to render with no story): untracked → silent exit 0; tracked + no owned story → Tier 1; tracked + lane-owned in_progress story → Tier 2 (pocket-shaped). Both hooks run plain `tyrion prime`.
- **Provably read-only.** ⚠️ Do NOT reuse `resolve_my_story` (lib/tyrion/commands.rb:2864) — it *adopts* assigned stories by writing `claimed_by` even with `claim_if_none: false` (commands.rb:2880). Prime needs a separate read-only lookup: never adopts, never claims, never writes lane files or initializes state. Strict tests assert DB + `.tyrion/**` snapshots byte-identical across: assigned-placeholder, unclaimed-legacy, stale pin, and two-lane cases.
- **Fail open, fully**: missing binary (shim guard), missing/corrupt DB, internal exception, timeout → exit 0, warnings stderr-only. Prime must never break session start or compaction. Mirror beads' shim timeout pattern (`BEADS_HOOK_TIMEOUT` analog).

## setup claude — implementation guidance

- Sits next to `cmd_setup_codex` (commands.rb:2489-2507); reuse `tyrion whitelist` machinery (commands.rb:2509+, note it rewrites the whole doc via `JSON.pretty_generate` + `File.write` — needs the atomic-write + preserve-foreign-keys treatment).
- **Thin shim, fat binary** (review finding): do NOT copy `hooks/claim-gate.sh` (227 lines of logic) into targets. Add a `tyrion hook claim-gate` subcommand hosting the logic; install a small versioned shim that execs it. Upgrading tyrion then upgrades every repo's gate. `--check` reports shim version staleness. Shell-escape the absolute RUBYLIB path; the F2 regression test is: post-install, the gate's `--check` reports `armed`.
- **JSON merge fixtures** (each is a test): existing unrelated hooks/permissions/unknown keys preserved with order; malformed JSON → refuse, zero writes; `hooks` present but wrong type → refuse; stale tyrion-owned entries (old command strings) replaced, not duplicated; second run byte-identical.
- **Atomicity**: preflight all inputs, build outputs complete, single rename per file. Concurrent installers must not interleave read-modify-write.
- **Target root**: resolve to the repo/worktree root the command runs in; define behavior when run from a subdirectory (walk up to root, same as `.tyrion/marker` discovery).
- **Managed block edge cases** (each is a test): hash covers block body bytes *excluding* marker lines (else self-referential); exactly one well-formed block required — duplicate/nested/reversed/unpaired markers → refuse with zero writes; no-block → append; no trailing newline; CRLF; marker-like text inside fenced code blocks; corrupt hash; older block version.
- Hook JSON shape (merge, never clobber):

  ```json
  {
    "hooks": {
      "SessionStart": [{ "hooks": [{ "command": "<shim> tyrion prime", "type": "command" }], "matcher": "" }],
      "PreCompact":   [{ "hooks": [{ "command": "<shim> tyrion prime", "type": "command" }], "matcher": "" }]
    }
  }
  ```

## Story sequencing (encode at assign time — waves, not parallel)

1. `tyrion-prime-command` (no deps)
2. `setup-claude-command` (depends: prime — it installs hooks that run prime)
3. `claude-md-managed-block` (depends: setup-claude — same command surface, same specs; kept separate for reviewability, must not run in parallel with it)

## Acceptance dogfood

Run `tyrion setup claude` in `~/work/rstreamlit/stream_weaver` (live beads repo), open a fresh Claude Code session, verify Tier-1 injection fires unprompted — side-by-side with beads in the same repo.

## Deliberately not supported (decided, not forgotten — review finding 16)

- `.tyrion/PRIME.md` per-project payload override (beads has one; add if customization is ever needed)
- Git-hook-time export (Tyrion's source of truth already runs feature-file → DB)
- `--global` scope (`~/.claude/settings.json`) — per-project only, matching beads' observed usage
- `bd onboard`-style print-a-snippet path and beads' session-close protocol block
- `--print` dry-run of the full template (add later if wanted; `--check` covers verification)
- Monitor-mode web board (L5) — separate follow-on epic, shape mode
