# What

no-mistakes now fills its pull request narrative from this repository's
`.github/pull_request_template.md`, so a no-mistakes-shipped PR reads in the same
What / Why / How shape the pr-description skill defines.

# Why

On projects that ship through no-mistakes the worker never writes the PR
description, so the pr-description skill's trigger never applied and PRs came out
in the pipeline's fixed Intent / What Changed / Risk Assessment / Pipeline shape.
Configuring `pr.template` moves that narrative back under the repository's own
standard.

# How

- Added `.github/pull_request_template.md` with the skill's What / Why / How
  sections (plus optional Notes / Next) as top-level `#` headings the pipeline
  preserves.
- Bound it in `.no-mistakes.yaml` as `pr.template: .github/pull_request_template.md`.
- Changed firstmate's brief trigger so a `no-mistakes`/`none` ship brief tells the
  worker the pipeline writes the description, while direct-PR, local-only, and
  no-mistakes-on-Gerrit briefs still load the pr-description skill.

## Notes

The template is read from the trusted default branch, so it takes effect for runs
started after this lands on the default branch.

## Next

Update the remaining firstmate-managed projects to bind their own `pr.template`.
