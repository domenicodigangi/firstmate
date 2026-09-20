---
name: wayfinder-intake
description: >-
  Agent-only intake, routing, and completion procedure for a project whose planning lives as an in-repo decision-ticket map.
  Use before choosing, dispatching, resolving, or completing work from such a map.
user-invocable: false
metadata:
  internal: true
---

# wayfinder-intake

Use this procedure before intake, dispatch, resolution, or completion for a project whose planning lives as an in-repo decision-ticket map.
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

The project-side claim is the concurrency guard visible to other sessions and working copies, so a private in-flight record does not replace it.
Claiming a selected ticket through the project's existing tracker mechanism writes inside the project, so do it before dispatch only for a project where the captain has concretely approved that write under `AGENTS.md` hard rule 1.
Without that approval the ticket goes unclaimed, and the map's guard against two sessions taking one ticket is not in force for that project.
Do not simulate the claim from outside the project or present an unclaimed ticket as guarded.
Ask the captain to approve that project write to turn the guard on.
Never mirror a map into Firstmate's backlog.
When dispatching a ticket, add only one backlog item whose note is a one-line pointer naming that ticket, then follow the backlog contract in `AGENTS.md` section 10.
Leave an undispatched ticket out of the backlog, except a ticket routed to a captain session, which is a main-side thread worth durable tracking and is filed and held as its own work item under that same section.

## Route the ticket

Apply `AGENTS.md` section 7's ship-versus-scout classification and selected-delivery-path contract to the ticket's required outcome.
A research ticket routes as a scout, and a ticket that builds something routes as a ship.
Keep work that requires live exchange with the captain, such as an interview or iterative review of a rough artifact, in a captain session under `AGENTS.md` hard rule 4 rather than dispatching it.

## Resolve the ticket with the work

When completed work lands through a project change, write the ticket's resolution and corresponding map update in that same change.
Landing a research deliverable, ticket resolution, or map update inside a project is a separate project write under `AGENTS.md` hard rule 1, never authority inherited from an approved claim.
Firstmate makes only the completion writes concretely named by the captain's approval.
Without approval covering those writes, keep the scout report in Firstmate's private record, leave the map unchanged, and either wait for approval or route the resolution through normal delivery as a follow-on ship task.
A captain-session ticket produces no worker-carried change, so the captain must land its resolution or a follow-on ship task must carry it through normal delivery.
Use `AGENTS.md` section 7 for the delivery and merge lifecycle instead of defining another path here.
