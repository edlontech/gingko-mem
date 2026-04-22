# Extraction Profiles

An extraction profile is a bundle of prompt templates and heuristics that
Mnemosyne uses to turn raw session steps into graph nodes. The right profile
makes extraction focus on the vocabulary and patterns that matter for your
domain; the wrong one produces generic nodes.

## Built-in profiles

| Profile            | Good for                                              |
|--------------------|-------------------------------------------------------|
| `none`             | No domain priming. Sensible fallback.                 |
| `coding`           | Software engineering workflows, repos, debugging.     |
| `research`         | Literature review, experiment logs, synthesis tasks.  |
| `customer_support` | Ticket triage, conversation summarization.            |

Set the global default in `config.toml`:

```toml
[mnemosyne]
extraction_profile = "coding"
```

## Per-project overlays

A single Gingko install can host many projects of different flavors. Rather
than forcing one global profile on all of them, each project can override the
profile *and* layer its own text on top of specific pipeline steps.

Overlays are stored in SQLite (`extraction_overlays` table), one row per
project. They expose four fields:

| Field                       | Purpose                                                    |
|-----------------------------|------------------------------------------------------------|
| `base`                      | `inherit_global`, `none`, `coding`, `research`, `customer_support`. |
| `domain_context`            | Free-form paragraph about the project. Injected into every step. |
| `steps`                     | Map of `step_name -> overlay text`. Targets individual LLM steps.   |
| `value_function_overrides`  | Per-type retrieval parameter overrides, same shape as `[value_function.params]`. |

Targetable steps for overlay text:

```
get_subgoal get_state get_reward merge_intent
reason_episodic reason_semantic reason_procedural
get_refined_query get_semantic get_procedural
get_return get_mode get_plan
```

Each overlay entry is capped at 8000 characters.

### When to use which field

- **Change `base`** when the project belongs to a different domain than the
  global default.
- **Set `domain_context`** when the project has vocabulary, acronyms, or house
  conventions that the agent should always know.
- **Set a step overlay** when extraction is systematically missing a signal you
  care about. Example: overlay `get_semantic` with "Treat configuration keys
  and env vars as first-class semantic facts." to stop them being dropped as
  noise.
- **Set `value_function_overrides`** when one project wants different retrieval
  aggressiveness than your global defaults — for instance, a research project
  that benefits from a much larger `episodic.top_k`.

### Effective configuration

When a project is opened, Gingko builds its effective `Mnemosyne.Config` like
this:

1. Start from the global `[mnemosyne]` config.
2. Choose a base profile: the overlay's `base`, or the global profile if `base
   = "inherit_global"`, or no profile if `base = "none"`.
3. Apply `domain_context` and `steps` on top of that base profile.
4. Merge `value_function_overrides` onto the global value-function params.

`open_project_memory` picks this up automatically. Changing an overlay at
runtime will close and reopen the project repo to pick up the new config —
active sessions on that project are force-closed, so warn users first.

## Editing overlays

The project-live monitor has an "Extraction Overlay" pane with a form for each
field. Saving the form calls `Gingko.Projects.upsert_extraction_overlay/2` and
then reopens the repo.

Programmatically:

```elixir
Gingko.Projects.upsert_extraction_overlay("my-app", %{
  base: "coding",
  domain_context: "Phoenix LiveView app. Ecto+SQLite. Use 'context' to mean Phoenix context module, not LLM context.",
  steps: %{
    get_semantic: "Treat migration names and module paths as semantic nodes."
  },
  value_function_overrides: %{
    episodic: %{top_k: 60}
  }
})
```

Then:

```elixir
Gingko.Memory.reload_project_config("my-app")
```

## Debugging extraction

Set `trace_verbosity = "detailed"` in `[mnemosyne]` to log each pipeline step's
input and output. Pair with a run under `mix phx.server` so you can watch the
LLM calls flow step-by-step. Turn back down to `"summary"` once extraction is
behaving — detailed tracing is expensive.
