# Claude-Config

Canonical, editable source for my Claude Code config. Edit here, then deploy outward. Never copy a live `~/.claude` back into this repo (it holds local settings, history and possibly secrets).

| File | Deployed as |
|---|---|
| `CLAUDE.md` | A managed block in `<config dir>/CLAUDE.md` (other content in that file is kept) |
| `settings.json` | Only these keys are merged into `<config dir>/settings.json`: `model`, `env` (two model pins), `enabledPlugins` (Superpowers off), `extraKnownMarketplaces`, `promptSuggestionEnabled`. Everything else (theme, permissions, hooks, other env/plugins) is untouched |
| `agents/grunt.md` | `<config dir>/agents/grunt.md` |
| `manifest.json` | Lists exactly what is installed |

`<config dir>` is `$env:CLAUDE_CONFIG_DIR` if set, else `~/.claude`.

## Install / update (PowerShell, one line each)

First install on a PC (preview first, then apply):

```powershell
git clone https://github.com/CClintos/Claude-Config.git; cd Claude-Config; .\install.ps1 -DryRun
```

```powershell
.\install.ps1
```

Update later (aborts if `git pull --ff-only` fails):

```powershell
.\install.ps1 -Update
```

If this PC's `CLAUDE.md` already contains an older copy of these rules, add `-AdoptExistingClaudeMd` once (otherwise the managed block is appended and rules are duplicated). Every change is backed up first to `<config dir>/claude-config-backups/<timestamp>/`. Repeat runs change nothing.

Roll back the last install (or name a timestamp):

```powershell
.\install.ps1 -Restore latest
```

Tests (temporary destination only): `pwsh -NoProfile -File tests\test-install.ps1`

## Usage policy

- Default model `opusplan`: Opus 5.5 inside formal Plan Mode, Sonnet 5.5 otherwise (both pinned). Transitions and model switches rebuild the prompt cache, so avoid switching mid-conversation. Prose about "planning" does not mean the runtime switched models; check `/model`.
- Use Opus directly (`/model opus`) for genuinely hard reasoning such as substantive DSP or architecture analysis. Use Sonnet for routine work. No automatic planner/worker/reviewer chain.
- `grunt` is a read-only Haiku extractor (`Read, Grep, Glob`, `maxTurns: 8`), only for bounded side tasks that would clutter context. Edits and interpretation stay with the main agent. A turn-limit hit is partial, not complete.
- Superpowers is installed but **off by default**. Opt in per project for substantial development with `.claude/settings.local.json` in that project: `{ "enabledPlugins": { "superpowers@superpowers-dev": true } }`.
- Effort: 5.5 models default to medium. Per-model effort is saved by `/effort` under `modelSettings`; this repo does not set it.
- Measure with `/context` and `/usage`, not assumptions.

## Where each surface gets its instructions

Local Code reads `CLAUDE.md` and `settings.json` from the config dir. Cloud Code, Chat and Cowork do **not** read this repo; each has its own instruction controls (Chat: Settings > Profile > "Instructions for Claude"; Cowork: its own instructions setting). Overlap between them is partial, so verify rather than assume. A JSON model alias does not configure Chat routing. A portable short block for Chat/Cowork is in `chat-preferences.md`.
