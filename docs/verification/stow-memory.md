# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports two active guarantees: Firstmate can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude`, and a Claude primary is made to stow before its conversation compacts.
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
For `W = 350000` on a model whose maximum output is at least 20,000 tokens, compaction triggers at 317,000 tokens, 33,000 below the window.
The same bundle arms a background summary at `min(E - 0.2 * E, E - 13000)` with `E = W - 20000`, which is 264,000 tokens for that window; that path runs the PreCompact hook when the summary starts and swaps it in later without running the hook again.
Claude Code's threshold check starts from the newest API usage's `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` and adds an estimate for messages appended since; the guard reads the same sum from the transcript without that estimate, so it trails by the newest tool results.
The live run below agrees: with `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` on Haiku 4.5 the debug log reported `effectiveWindow=80000`, and its checks read `level=warn` before the 66,976-token request and `level=compact` before the 89,511-token request, consistent with the computed 67,000-token point.

Completed `/stow` runs in this home's own Claude transcripts grew the context by 14,870, 25,099, and 33,694 tokens, measured from the usage just before the invocation to the end of that turn.
A 270,000-token stow threshold therefore leaves 47,000 tokens before the 317,000-token compaction point, above the largest measured stow.

### What a hook can enforce

A PreCompact hook that exits 2 blocks compaction in 2.1.283, for both triggers; the bundle raises `Compaction blocked by PreCompact hook` for a manual `/compact`, and a blocked automatic compaction returns a `hook_blocked` result that continues the turn uncompacted rather than counting as a failure.
A PreCompact hook cannot start a stow, because a stow needs a model turn; a successful PreCompact hook's stdout becomes extra summary instructions, so the guard prints nothing when it allows.
A synchronous Stop hook that exits 2 holds the turn open and hands its stderr to the model, which is how the guard asks for the stow.

The live probe used a disposable primary-shaped directory whose `.claude/settings.json` registered only the guard's `--stop` and `--precompact` hooks, with `FM_ROOT_OVERRIDE` pointing at that directory:

```bash
claude --version
printf '5000\n' > config/claude-stow-threshold
claude -p --model claude-haiku-4-5-20251001 --output-format json "Reply with the single word hello. If a hook asks you to run /stow, reply only: stow unavailable here."
claude -p --model claude-haiku-4-5-20251001 --resume "$SESSION" --output-format json "/compact"
claude -p --model claude-haiku-4-5-20251001 --resume "$SESSION" --output-format json "/compact"
claude -p --model claude-haiku-4-5-20251001 --resume "$SESSION" --output-format json "Reply with the single word again. If a hook asks you to run /stow, reply only: stow unavailable here."
```

The first call returned `num_turns` 2 and the result `stow unavailable here`, so the Stop hook held the turn open once.
The first `/compact` returned `Compaction blocked by PreCompact hook: [...]: No /stow has run since the previous compaction, ...`, the second wrote a `compact_boundary` entry with `"trigger":"manual","preTokens":22242` to the same transcript file, and the last call received `This session compacted (trigger manual, at 22242 tokens) with no /stow since the previous compaction.` ahead of the stow instruction.

The automatic path used a second directory with `config/claude-stow-threshold` set to `30000` and four text files of about 22,500 tokens each:

```bash
CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000 claude -p --model claude-haiku-4-5-20251001 --allowedTools Read --output-format json --debug-file debug.log "Use the Read tool to read a.txt, then b.txt, then c.txt, then d.txt, one file per tool call, in that order. After reading all four, reply with the single word done. If a hook asks you to run /stow, reply only: stow unavailable here."
```

The main-chain request sizes were 21,850, 44,434, 66,976, 89,511, and 112,078 tokens, then 19,195 after compaction.
The debug log showed `PreCompact:auto` followed by `Reactive compact blocked by PreCompact hook` and `Reactive compact skipped` twice, before the 89,511 and 112,078 requests, then the Stop hook's `Context is at 112078 tokens, past the 30000-token stow threshold` instruction, then a third `PreCompact:auto` that the guard allowed because the context had reached the 100,000-token window, followed by the compaction request.
The transcript then held one `compact_boundary`, and the next turn end reported it as a compaction with no stow.
