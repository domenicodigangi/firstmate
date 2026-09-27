---
name: pr-description
description: >-
  Agent-only writing standard for pull-request titles and descriptions.
  Use before writing or rewriting a pull-request title or description for any project we own.
user-invocable: false
metadata:
  internal: true
---

# pr-description

Use this standard for every pull request aimed at a repository we own.
When contributing to a repository we do not own, follow that project's conventions instead.

## Title

Write the title as `<type>(<area>): <the outcome in plain words>`.
Choose the type from `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, or `perf`.
Use the subsystem or product area for `area`.
Keep the title to one line of around 60 characters and state what is different after the merge.
Do not include ticket numbers, internal identifiers, or phrases such as "as requested".

## Body

Use these sections in this order.
Omit an optional section when it has no useful content instead of writing "n/a".

```markdown
## What

State the outcome first in one to three sentences.

## Why

Explain the decision, problem, or requirement behind the change.

## How

- Describe the approach.
- Name a notable choice.
- Explain what was rejected when that helps explain the result.

## Notes

- Note limits, risks, or follow-ups.

## Next

- Give the concrete next step and any relevant Wayfinder map or ticket links.
```

`## Notes` and `## Next` are optional.
Write `## What` so a reader who stops there still knows what changed.
Prefer short bullets to paragraphs and keep the body around 250 words unless necessary evidence genuinely needs more.
When the scope was narrowed, state what was deliberately left out.

State the substance without relying on pre-existing context.
Do not write "as discussed" or "see the ticket" as a substitute for the decision or requirement.
State the substance first, then add a link when it helps.
Wayfinder map and ticket links are welcome in `## Next`.

Keep internal vocabulary out of the description, including harness names, pipeline details, worktree details, task IDs, status lines, validation labels, and delivery-mode names.
Translate implementation process into reader-facing outcomes, decisions, limits, and next steps.

## Finalization

The validator writes its own description during validation.
Set the final title and description as the last act of the task.
Do not rerun validation afterward unless you will restore the final title and description again.
