# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports two active guarantees: Firstmate can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude`, and a Claude primary stows and then compacts as one automatic sequence.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns tiering, curation, archival, offload, and completion-receipt behavior.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing startup-memory setting and estimate.

## Git-excluded local skill discovery and loading

The internal skill's offload destination relies on the harness discovering and JIT-loading a skill directory whose path is listed in the clone's local `.git/info/exclude`.
This check ran on 2026-08-08 with Claude Code 2.1.226 in a disposable scratch repository.
The unique sentinel appeared only in the skill body below the frontmatter, so returning it required the fresh session to load the excluded skill rather than merely see its indexed name or description.

The exact commands run from this repository root were:

```bash
set -eu
claude --version
PROBE_ROOT="$PWD/.stow-excluded-probe-tmp"
rm -rf "$PROBE_ROOT"
mkdir -p "$PROBE_ROOT"
cd "$PROBE_ROOT"
git init -q .
mkdir -p .claude/skills/excluded-probe
cat >.claude/skills/excluded-probe/SKILL.md <<'EOF'
---
name: excluded-probe
description: A neutral probe used when explicitly requested by name.
---

# Excluded probe

The sentinel token is STOW-EXCLUDE-LOAD-8F3K1.
EOF
printf '.claude/skills/excluded-probe/\n' >>.git/info/exclude
git check-ignore -v .claude/skills/excluded-probe/SKILL.md
claude --model haiku --allowedTools Skill -p "Use your Skill tool to load the skill named 'excluded-probe', then reply with exactly the sentinel token stated inside its body and nothing else."
cd ..
rm -rf "$PROBE_ROOT"
```

The exact observed output was:

```text
2.1.226 (Claude Code)
.git/info/exclude:7:.claude/skills/excluded-probe/	.claude/skills/excluded-probe/SKILL.md
STOW-EXCLUDE-LOAD-8F3K1
```

The `git check-ignore` line proves that the local exclude rule covered the skill body, and the exact sentinel reply proves that a fresh Claude Code session loaded that body through the Skill tool.
The same day, a `.gitignore`-ignored probe directory under this repository's own `.agents/skills/` was also listed by a fresh session alongside the tracked control skill through the `.claude/skills` symlink.
The direct local-exclude probe establishes the load-bearing guarantee, while the in-repository probe independently corroborates that ignore status does not suppress filesystem discovery.

## Stow before compaction on Claude Code

[`docs/configuration.md`](../configuration.md) "Stow before compaction" owns the current behavior, and [`bin/fm-claude-stow-guard.sh`](../../bin/fm-claude-stow-guard.sh) owns its decisions; `tests/fm-claude-stow-guard.test.sh` pins them without a harness.
These checks ran on 2026-09-28 against Claude Code 2.1.283.

### Where automatic compaction triggers

Read from the 2.1.283 bundle (`strings` over the installed binary), the compaction point for a configured window `W` is `W - min(model max output, 20000) - 13000`, lowered further only by `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`.
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` wins over the `autoCompactWindow` setting, and the result is capped at the model's own context window.
For `W = 300000` on a model whose maximum output is at least 20,000 tokens, compaction triggers at 267,000 tokens; the live run below logged `effectiveWindow=280000` for that window.
The same bundle can arm a background summary at `min(E - 0.2 * E, E - 13000)` with `E = W - 20000`; that path runs the PreCompact hook when the summary starts and swaps it in later without running the hook again.
Neither live run below logged a background summary.
Claude Code's threshold check starts from the newest API usage's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` and adds an estimate for messages appended since; the guard reads the same sum from the transcript without that estimate, so it trails by the newest tool results.

Completed `/stow` runs in this home's own Claude transcripts grew the context by 14,870, 25,099, and 33,694 tokens, measured from the usage just before the invocation to the end of that turn.
Compaction after a stow therefore lands at the context of the turn end that ran it plus that much.

### What a hook can enforce

A PreCompact hook that exits 2 blocks compaction in 2.1.283, for both triggers; the bundle raises `Compaction blocked by PreCompact hook` for a manual `/compact`, and a blocked automatic compaction returns a `hook_blocked` result that continues the turn uncompacted rather than counting as a failure.
A PreCompact hook cannot start a stow, because a stow needs a model turn, and no hook can start a compaction.
A successful PreCompact hook's stdout becomes extra summary instructions, so the guard prints nothing when it allows.
A synchronous Stop hook that exits 2 holds the turn open and hands its stderr to the model, and Claude Code runs its automatic compaction check before the request that follows, which is how the guard asks for the stow and then makes compaction follow it at once.

Not enforceable:

- The stow runs at the first turn end past the threshold, so a long turn overshoots the threshold by whatever it adds before it ends.
- A background summary started before the deferral applies is swapped in without another hook call.
- A model with the 200,000-token window, or a window set below about 233,000 tokens, compacts before the deferral's 200,000-token floor is passed; the next turn end reports that compaction.

### Live runs

The automatic sequence used a disposable primary-shaped directory whose `.claude/settings.json` set `autoCompactWindow` to `300000` and registered only the guard's `--stop` and `--precompact` hooks, with `FM_ROOT_OVERRIDE` pointing at that directory, no `config/claude-stow-threshold` (the 300,000 default), a stand-in `.claude/skills/stow/SKILL.md` that only replies `stow complete`, and fourteen text files of about 22,500 tokens each:

```bash
claude -p --model 'sonnet[1m]' --allowedTools Read,Skill --output-format json --debug-file debug.log "Use the Read tool to read f01.txt, then f02.txt, and so on through f14.txt, one file per tool call and never several at once. After reading all fourteen, reply with the single word done. If a hook tells you to run /stow, invoke the stow skill with the Skill tool and follow it."
```

The main-chain request sizes climbed by about 22,500 tokens per file to 351,734.
From the request after 261,610 tokens onward, the debug log showed `level=compact`, then `PreCompact:auto` followed by `Reactive compact blocked by PreCompact hook` and `Reactive compact skipped` before every request, four times through the reads, once after the stow instruction, and once while the stow skill ran.
At the turn end at 351,734 tokens the Stop hook returned `Context is at 351734 tokens, past the 300000-token stow threshold, and compaction follows the stow.`, and the model invoked the stow skill.
At the turn end after the stow the Stop hook returned `The stow is done. Context is at 352359 tokens, past the 267000-token automatic compaction point, so Claude Code compacts before your next reply.`; 3 milliseconds later the log showed `level=compact` and a `PreCompact:auto` the guard allowed, followed by the compaction request.
The transcript then held one `compact_boundary` with `"trigger":"auto","preTokens":352487,"postTokens":4726`, the final reply `Stow's done — compaction follows.` ran at 27,187 tokens, and the next turn end reported nothing, because the stow preceded the compaction.

The manual path used a second directory with the same hooks and `config/claude-stow-threshold` set to `5000`:

```bash
claude -p --model claude-haiku-4-5-20251001 --output-format json "Reply with the single word hello. If a hook asks you to run /stow, reply only: stow unavailable here."
claude -p --model claude-haiku-4-5-20251001 --resume "$SESSION" --output-format json "/compact"
claude -p --model claude-haiku-4-5-20251001 --resume "$SESSION" --output-format json "/compact"
claude -p --model claude-haiku-4-5-20251001 --resume "$SESSION" --output-format json "Reply with the single word again. If a hook asks you to run /stow, reply only: stow unavailable here."
```

The first call returned `num_turns` 2 and the result `stow unavailable here`, so the Stop hook held the turn open once.
The first `/compact` returned `Compaction blocked by PreCompact hook: [...]: No /stow has run since the previous compaction, ...`, the second wrote a `compact_boundary` entry with `"trigger":"manual","preTokens":22242` to the same transcript file, and the last call received `This session compacted (trigger manual, at 22242 tokens) with no /stow since the previous compaction.` ahead of the stow instruction.

### When the guard itself fails

These runs replaced one of the two guard entries with a stand-in hook that failed on purpose, while the other entry kept the real guard; each stand-in entry set a 5-second hook `timeout`.
The stand-in read its failure from a file: `exit1` printed `stub guard failure` and exited 1, `crash` sent itself `SIGSEGV`, `timeout` slept for 60 seconds, and `syntax` ran a bash script that fails to parse.
Every run used `claude-haiku-4-5-20251001`; the automatic runs added `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` and read four files of about 22,500 tokens each, as in the earlier probe.

With the stand-in at PreCompact:

- Manual `/compact` after a one-word reply: the debug log showed `PreCompact:manual [...] completed with status 1`, `completed with status 139`, and `cancelled` for the three modes, each followed by a compaction; the transcripts gained a `compact_boundary` with `"trigger":"manual"` at 21,955, 21,992, and 22,010 tokens and no record of the hook failure.
  The next turn end's real guard returned `This session compacted (trigger manual, at 21955 tokens) with no /stow since the previous compaction.` and the matching lines for the other two.
- Automatic compaction: `PreCompact:auto [...] completed with status 1`, `completed with status 139`, and `cancelled`, each followed within 25 milliseconds by a `source=compact` request, with boundaries of `"trigger":"auto"` at 76,904, 76,982, and 76,974 tokens, and the same report at the next turn end.
- `syntax`: both `/compact` attempts returned `Compaction blocked by PreCompact hook: [...]` after `completed with status 2`, and the transcript gained no boundary.

With the stand-in at Stop:

- `exit1` and `crash` ended the turn with `num_turns` 1 and the reply `hello`; the transcripts gained a `hook_non_blocking_error` attachment with `"exitCode":1` and `"stderr":"Failed with non-blocking status code: stub guard failure"`, or `"exitCode":139` and `Segmentation fault (core dumped)`.
- `timeout` ended the turn the same way after the debug log's `Hook Stop [...] timed out after 5000ms`, and the transcript gained a `hook_cancelled` attachment.
- `syntax`, run with `--max-turns 4`, returned `error_max_turns` after `num_turns` 5, with four `Hook Stop (Stop) error:` entries carrying the bash parse error, so each turn end was held open again.

Claude Code's default hook timeout is `600000` milliseconds in the 2.1.283 bundle (`timeout?e.timeout*1000:Fa` with `Fa=600000` beside the hook runner), and the tracked guard entries set no `timeout`.
