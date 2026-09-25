---
name: wayfinder-intake
description: >-
  Agent-only intake, routing, and completion procedure for a project whose planning lives as a decision-ticket map in the project repository or a dedicated tracker repository shared by products.
  Use before choosing, dispatching, resolving, or completing work from such a map.
user-invocable: false
metadata:
  internal: true
---

# wayfinder-intake

Use this procedure before intake, dispatch, resolution, or completion for a project whose planning lives as a decision-ticket map in the project repository or a dedicated tracker repository shared by products.
Resolve the map's authoritative location per product from this home's captain preferences or the project's own instructions, never by assumption.
The authoritative map is the planning authority, while Firstmate's backlog remains the execution queue under `AGENTS.md` section 10.

## Select a ticket

Read the product's map through this home's clone of the repository that owns it before choosing work.
Run that tracker's read-only frontier helper for candidates.
Treat its output as candidates derived from ticket frontmatter, not as a decision or priority order.
Check the map prose for scope, ordering, and deferrals before selecting any candidate.
Do not select a ticket that the map defers even when the frontier helper output includes it.

Treat each ticket as dispatch-ready instructions.
Do not dispatch a separate scout to review, restate, or prepare a ticket before its work begins.
When a ticket lacks enough context or acceptance criteria for direct dispatch, report the gap as a tracker defect and leave the ticket undispatched.

## Claim and queue the work

The claim in the authoritative tracker is the concurrency guard visible to other sessions and working copies, so a private in-flight record does not replace it.
For an in-repository tracker, claim through the project's existing claim helper.
For a dedicated tracker, land `assignee:` against that tracker through its own workflow before dispatch, so the claim is visible on the authoritative branch that the frontier helper reads.
Either claim is a project write, so make it only when the captain has concretely approved that write under `AGENTS.md` hard rule 1.
Without that approval the ticket stays unclaimed and must be reported as unguarded.
Do not simulate the claim from outside the authoritative tracker or present an unclaimed ticket as guarded.
Ask the captain to approve the authoritative tracker write to turn the guard on.
Never mirror a map into Firstmate's backlog.
When dispatching a ticket, add only one backlog item whose note is a one-line pointer naming that ticket, then follow the backlog contract in `AGENTS.md` section 10.
Leave an undispatched ticket out of the backlog, except a ticket routed to a captain session, which is a main-side thread worth durable tracking and is filed and held as its own work item under that same section.

## Route the ticket

Apply `AGENTS.md` section 7's ship-versus-scout classification and selected-delivery-path contract to the ticket's required outcome.
A research ticket routes as a scout, and a ticket that builds something routes as a ship.
Keep work that requires live exchange with the captain, such as an interview or iterative review of a rough artifact, in a captain session under `AGENTS.md` hard rule 4 rather than dispatching it.

## Resolve the ticket with the work

Land the ticket's resolution and its map decision line as a change against the authoritative tracker.
When the tracker is separate from the product repository, land the tracker-side change through that repository's own workflow, cross-link it with the product change, and do so only after the product change lands so the tracker never records work that did not ship.
When that tracker takes no pull requests, as the Wayfinder tracker does, commit the tracker-side change directly to its default branch.
Landing a research deliverable, ticket resolution, or map update in the authoritative tracker is a separate project write under `AGENTS.md` hard rule 1, never authority inherited from an approved claim.
Firstmate makes only the completion writes concretely named by the captain's approval.
Without approval covering those writes, keep the resolution in Firstmate's private record and leave the authoritative tracker untouched.
Either wait for approval or route the tracker resolution through normal delivery as a follow-on ship task.
A captain-session ticket produces no worker-carried change, so the captain must land its resolution or a follow-on ship task must carry it through normal delivery.
Use `AGENTS.md` section 7 for the delivery and merge lifecycle instead of defining another path here.
