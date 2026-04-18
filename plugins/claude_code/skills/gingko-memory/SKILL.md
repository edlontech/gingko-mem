---
name: gingko-memory
description: Use when working in a project with Gingko memory integration. Teaches how to record observations and actions as memory steps, search past memories, and interact with the Gingko graph-based memory engine via the gingko.sh CLI helper.
---

# Gingko Memory Integration

Gingko is a graph-based memory engine that tracks what you observe and do across sessions. Your memories persist and are available in future sessions to provide context.

## Recording Memory Steps

When you complete meaningful work, record it:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh append-step '<observation>' '<action>'
```

**Observation** = what you discovered, analyzed, or encountered:
- "Found that the auth module had a null pointer bug on line 42 of auth.ex"
- "User requested adding pagination to the projects list API"
- "Test suite was failing due to a missing mock for the HTTP client"

**Action** = what you did and why:
- "Fixed the null check by adding a guard clause, added a regression test"
- "Added offset/limit params to ProjectController.index with default page size of 20"
- "Added HTTP mock setup in test_helper.exs, all 47 tests now pass"

**When to record:**
- After fixing a bug
- After implementing a feature or part of one
- After investigating an issue (even if not yet resolved)
- After making architectural decisions
- After significant refactoring

**When NOT to record:**
- Trivial questions answered without code changes
- Reading files without acting on them
- Mid-step before you have a result

## Searching Past Memories

Search for relevant context from past sessions:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh recall 'authentication bug fixes'

$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh get-node '<node_id>'

$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh latest-memories 10
```

Use `recall` when:
- Starting work on a module you may have touched before
- Investigating a recurring issue
- Looking for context on past decisions

## Session Lifecycle

Sessions are managed automatically by hooks. You do not need to open or close sessions. Focus on recording meaningful steps.
