---
name: wayfinder-intake
description: >-
  Agent-only intake and routing procedure for a project whose planning lives as an in-repo decision-ticket map.
  Use before choosing or dispatching work from such a map.
user-invocable: false
metadata:
  internal: true
---

# wayfinder-intake

Use this procedure before intake or dispatch for a project whose planning lives as an in-repo decision-ticket map.
The project's map is the planning authority, while Firstmate's backlog remains the execution queue under `AGENTS.md` section 10.

## Select a ticket

Read the map before choosing work.
Treat the project's takeable-list output as candidates derived from ticket frontmatter, not as a decision or priority order.
Check the map prose for scope, ordering, and deferrals before selecting any candidate.
Do not select a ticket that the map defers even when the takeable-list output includes it.

Treat each ticket as dispatch-ready instructions.
Do not dispatch a separate scout to review, restate, or prepare a ticket before its work begins.
When a ticket lacks enough context or acceptance criteria for direct dispatch, report the gap as a tracker defect and leave the ticket undispatched.

## Claim and queue the work

Claim the selected ticket through the project's existing tracker mechanism before dispatch.
The project-side claim is the concurrency guard visible to other sessions and working copies, so a private in-flight record does not replace it.
Do not add a map or its undispatched tickets to Firstmate's backlog.
When dispatching a claimed ticket, add only one backlog item whose note is a one-line pointer naming that ticket, then follow the backlog contract in `AGENTS.md` section 10.

## Route the ticket

Apply `AGENTS.md` section 7's ship-versus-scout classification and selected-delivery-path contract to the ticket's required outcome.
A research ticket routes as a scout, and a ticket that builds something routes as a ship.
Keep work that requires live exchange with the captain, such as an interview or iterative review of a rough artifact, in a captain session under `AGENTS.md` hard rule 4 rather than dispatching it.

## Resolve the ticket with the work

Write the ticket's resolution and the corresponding map update in the same project change that carries the completed work.
Keep a research deliverable in the project where the map can link it, rather than leaving it only in Firstmate's private report.
Use `AGENTS.md` section 7 for the delivery and merge lifecycle instead of defining another path here.
