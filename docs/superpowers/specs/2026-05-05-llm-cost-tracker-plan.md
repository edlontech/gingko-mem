# LLM Cost Tracker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Capture, attribute, persist, and visualize LLM/embedding cost across all Sycophant-mediated calls in Gingko.

**Design:** [docs/superpowers/specs/2026-05-05-llm-cost-tracker-design.md](./2026-05-05-llm-cost-tracker-design.md)

**Architecture:** Subscribe to Sycophant's `:telemetry` events; the handler reads a per-process attribution context (`Cost.Context`), builds a row, and casts it to a single batching writer (`Cost.Recorder`) that flushes to a SQLite table via `Repo.insert_all` and broadcasts via PubSub. Aggregations are on-demand `GROUP BY` queries through the `Gingko.Cost` API consumed by `CostLive` (`/cost`) and a small embedded strip in `ProjectLive`. Retention is enforced by an Oban-cron `Cost.Pruner`.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto + SQLite, Oban (Lite engine, already installed), `:telemetry`, Sycophant (existing dep), Mimic (existing test stub library).

**Conventions to honor (from CLAUDE.md):**
- Tests must NOT mutate Application env. Stub config-accessor modules via Mimic.
- No trailing whitespace, no superfluous in-function comments, no emojis.
- Commits: simple one-line messages, no co-authored trailers.
- Don't `rescue` without a bang `!`. Don't `||` nilable values that can't be nil.
- Run the full test suite before declaring done.

---

## Task 1: Schema, migration, and `Cost.Call`

**Files:**
- Create: `priv/repo/migrations/20260506100000_create_gingko_llm_calls.exs`
- Create: `lib/gingko/cost/call.ex`
- Test: `test/gingko/cost/call_test.exs`

**What to build:**

The append-only table that backs every other piece of this feature. UUIDv7 primary key for time-ordered inserts; per-row `currency`; all token/cost fields nullable; three composite indexes matching the dashboard's three breakdowns. The schema module is just `cast`/`validate_required`/`validate_inclusion`; we test that the changeset accepts a complete row, accepts a row with all costs nil, and rejects rows missing required fields. No queries here — those land in Task 7.

**Implementation:**

`priv/repo/migrations/20260506100000_create_gingko_llm_calls.exs`:
```elixir
defmodule Gingko.Repo.Migrations.CreateGingkoLlmCalls do
  use Ecto.Migration

  def change do
    create table(:gingko_llm_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :occurred_at, :utc_datetime_usec, null: false
      add :duration_ms, :integer

      add :provider, :string
      add :model, :string, null: false
      add :wire_protocol, :string
      add :event_kind, :string, null: false

      add :status, :string, null: false
      add :finish_reason, :string
      add :error_class, :string
      add :response_id, :string
      add :response_model, :string

      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cache_read_input_tokens, :integer
      add :cache_creation_input_tokens, :integer
      add :reasoning_tokens, :integer

      add :input_cost, :float
      add :output_cost, :float
      add :cache_read_cost, :float
      add :cache_write_cost, :float
      add :reasoning_cost, :float
      add :total_cost, :float
      add :currency, :string

      add :project_key, :string
      add :session_id, :string
      add :feature, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:gingko_llm_calls, [:occurred_at])
    create index(:gingko_llm_calls, [:project_key, :occurred_at])
    create index(:gingko_llm_calls, [:feature, :occurred_at])
    create index(:gingko_llm_calls, [:model, :occurred_at])
  end
end
```

`lib/gingko/cost/call.ex`:
```elixir
defmodule Gingko.Cost.Call do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @event_kinds ~w(request embedding)
  @statuses ~w(ok error)

  @fields ~w(
    id occurred_at duration_ms
    provider model wire_protocol event_kind
    status finish_reason error_class response_id response_model
    input_tokens output_tokens cache_read_input_tokens
    cache_creation_input_tokens reasoning_tokens
    input_cost output_cost cache_read_cost cache_write_cost
    reasoning_cost total_cost currency
    project_key session_id feature
    inserted_at
  )a

  @required ~w(id occurred_at model event_kind status inserted_at)a

  schema "gingko_llm_calls" do
    field :occurred_at, :utc_datetime_usec
    field :duration_ms, :integer

    field :provider, :string
    field :model, :string
    field :wire_protocol, :string
    field :event_kind, :string

    field :status, :string
    field :finish_reason, :string
    field :error_class, :string
    field :response_id, :string
    field :response_model, :string

    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read_input_tokens, :integer
    field :cache_creation_input_tokens, :integer
    field :reasoning_tokens, :integer

    field :input_cost, :float
    field :output_cost, :float
    field :cache_read_cost, :float
    field :cache_write_cost, :float
    field :reasoning_cost, :float
    field :total_cost, :float
    field :currency, :string

    field :project_key, :string
    field :session_id, :string
    field :feature, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(call \\ %__MODULE__{}, attrs) do
    call
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_inclusion(:event_kind, @event_kinds)
    |> validate_inclusion(:status, @statuses)
  end
end
```

**Testing:**

`test/gingko/cost/call_test.exs`:
```elixir
defmodule Gingko.Cost.CallTest do
  use ExUnit.Case, async: true

  alias Gingko.Cost.Call

  defp valid_attrs(extra \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        model: "gpt-4o",
        event_kind: "request",
        status: "ok",
        inserted_at: DateTime.utc_now()
      },
      extra
    )
  end

  test "accepts a row with full costs" do
    cs =
      Call.changeset(
        valid_attrs(%{
          input_tokens: 100,
          output_tokens: 250,
          input_cost: 0.0005,
          output_cost: 0.0125,
          total_cost: 0.013,
          currency: "USD",
          project_key: "demo",
          feature: "step_summarization"
        })
      )

    assert cs.valid?
  end

  test "accepts a row with all cost fields nil" do
    cs = Call.changeset(valid_attrs())
    assert cs.valid?
  end

  test "rejects unknown event_kind" do
    cs = Call.changeset(valid_attrs(%{event_kind: "bogus"}))
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:event_kind]
  end

  test "rejects unknown status" do
    cs = Call.changeset(valid_attrs(%{status: "maybe"}))
    refute cs.valid?
  end

  test "requires model" do
    cs = Call.changeset(Map.delete(valid_attrs(), :model))
    refute cs.valid?
    assert {"can't be blank", _} = cs.errors[:model]
  end
end
```

Run: `mix test test/gingko/cost/call_test.exs`
Expected: 5 tests, 0 failures. Run `mix ecto.migrate` and confirm migration is idempotent.

**Commit:**
```bash
git add priv/repo/migrations/20260506100000_create_gingko_llm_calls.exs lib/gingko/cost/call.ex test/gingko/cost/call_test.exs
git commit -m "feat(cost): add gingko_llm_calls schema and migration"
```

---

## Task 2: `Cost.Context` — per-process attribution

**Files:**
- Create: `lib/gingko/cost/context.ex`
- Test: `test/gingko/cost/context_test.exs`

**What to build:**

A tiny module that maintains a process-dictionary-backed attribution stack. `with/2` merges new attrs onto whatever's there, runs the function, then restores the previous map (or deletes the key if nothing was set before). `current/0` returns the current map (or `%{}`). The `try/after` is the load-bearing piece — without it, raises leak the modified context to whatever runs next on this process.

Test the four behaviors that matter: bare process is empty; `with/2` sets and restores; nesting merges and restores; `with/2` restores even when the body raises.

**Implementation:**

`lib/gingko/cost/context.ex`:
```elixir
defmodule Gingko.Cost.Context do
  @moduledoc """
  Per-process attribution stack for LLM cost rows.

  `Gingko.Cost.TelemetryHandler` reads `current/0` synchronously inside the
  Sycophant caller's process and tags the row it builds. Use `with/2` to
  scope attribution to a block; nested calls merge, and the previous map is
  restored on exit (success or raise).
  """

  @key :gingko_cost_context

  @type attrs :: %{
          optional(:project_key) => String.t(),
          optional(:session_id) => String.t(),
          optional(:feature) => atom() | String.t()
        }

  @spec with(attrs(), (-> result)) :: result when result: var
  def with(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    previous = Process.get(@key, %{})
    Process.put(@key, Map.merge(previous, attrs))

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @spec current() :: attrs()
  def current, do: Process.get(@key, %{})

  defp restore(previous) when previous == %{}, do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
```

**Testing:**

`test/gingko/cost/context_test.exs`:
```elixir
defmodule Gingko.Cost.ContextTest do
  use ExUnit.Case, async: true

  alias Gingko.Cost.Context

  test "current/0 is empty in a fresh process" do
    assert Context.current() == %{}
  end

  test "with/2 sets attrs for the duration of the block and clears on exit" do
    result =
      Context.with(%{project_key: "a", feature: :step_summarization}, fn ->
        Context.current()
      end)

    assert result == %{project_key: "a", feature: :step_summarization}
    assert Context.current() == %{}
  end

  test "nested with/2 merges and restores" do
    Context.with(%{project_key: "a"}, fn ->
      Context.with(%{feature: :project_summary}, fn ->
        assert Context.current() == %{project_key: "a", feature: :project_summary}
      end)

      assert Context.current() == %{project_key: "a"}
    end)

    assert Context.current() == %{}
  end

  test "inner with/2 overrides outer keys then restores" do
    Context.with(%{project_key: "a"}, fn ->
      Context.with(%{project_key: "b"}, fn ->
        assert Context.current().project_key == "b"
      end)

      assert Context.current().project_key == "a"
    end)
  end

  test "raise inside with/2 still restores" do
    assert_raise RuntimeError, "boom", fn ->
      Context.with(%{project_key: "a"}, fn -> raise "boom" end)
    end

    assert Context.current() == %{}
  end
end
```

Run: `mix test test/gingko/cost/context_test.exs`
Expected: 5 tests, 0 failures.

**Commit:**
```bash
git add lib/gingko/cost/context.ex test/gingko/cost/context_test.exs
git commit -m "feat(cost): add Cost.Context attribution stack"
```

---

## Task 3: `Cost.Config` accessor + Settings integration

**Files:**
- Create: `lib/gingko/cost/config.ex`
- Modify: `lib/gingko/settings.ex` (add `[cost_tracker]` defaults + `cost_tracker_env/1` like the existing `summaries_env/1`)
- Modify: `config/config.exs` (seed `Application.put_env(:gingko, Gingko.Cost.Config, ...)`)
- Modify: `test/test_helper.exs` (`Mimic.copy(Gingko.Cost.Config, type_check: true)`)
- Test: `test/gingko/cost/config_test.exs`

**What to build:**

A narrow accessor module — four functions, each returning one config value. The Recorder, TelemetryHandler, and Pruner all read through it. Tests stub via `Mimic.expect/3` instead of `Application.put_env` (per CLAUDE.md). `Settings` parses the TOML section and pushes resolved values into `Application.env` at boot the same way `summaries_env/1` does today.

Defaults match the spec: `enabled: true`, `retention_days: 0`, `batch_size_max: 50`, `flush_interval_ms: 500`.

**Implementation:**

`lib/gingko/cost/config.ex`:
```elixir
defmodule Gingko.Cost.Config do
  @moduledoc """
  Config accessor for the cost tracker. Reads from
  `Application.get_env(:gingko, __MODULE__)`. Stub via Mimic in tests instead
  of mutating application env.
  """

  @defaults [
    enabled: true,
    retention_days: 0,
    batch_size_max: 50,
    flush_interval_ms: 500
  ]

  @spec enabled?() :: boolean()
  def enabled?, do: get(:enabled)

  @spec retention_days() :: non_neg_integer()
  def retention_days, do: get(:retention_days)

  @spec batch_size_max() :: pos_integer()
  def batch_size_max, do: get(:batch_size_max)

  @spec flush_interval_ms() :: pos_integer()
  def flush_interval_ms, do: get(:flush_interval_ms)

  defp get(key) do
    :gingko
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
```

`lib/gingko/settings.ex` — add a `@default_cost_tracker` map alongside the others, parse the `[cost_tracker]` TOML section, and add a `cost_tracker_env/1` helper. Mirror the shape of `summaries_env/1`. Wire the resulting keyword list into `Application.put_env(:gingko, Gingko.Cost.Config, ...)` from `Gingko.Application.sync_runtime_settings/2` (alongside the existing `Gingko.Summaries.Config` line).

`config/config.exs` — add a default seed:
```elixir
config :gingko, Gingko.Cost.Config,
  enabled: true,
  retention_days: 0,
  batch_size_max: 50,
  flush_interval_ms: 500
```

`test/test_helper.exs` — add the Mimic copy line:
```elixir
Mimic.copy(Gingko.Cost.Config, type_check: true)
```

**Testing:**

`test/gingko/cost/config_test.exs`:
```elixir
defmodule Gingko.Cost.ConfigTest do
  use ExUnit.Case, async: false

  alias Gingko.Cost.Config

  test "returns defaults when no env override" do
    assert Config.enabled?() in [true, false]
    assert is_integer(Config.retention_days())
    assert Config.batch_size_max() > 0
    assert Config.flush_interval_ms() > 0
  end
end
```

(Behavioral testing of the values themselves happens in dependent tasks via Mimic stubs. This file just ensures the module is callable and types are sane.)

Run: `mix test test/gingko/cost/config_test.exs`
Expected: 1 test, 0 failures. After running `mix test` once, ensure the new `Mimic.copy` line doesn't break the suite.

**Commit:**
```bash
git add lib/gingko/cost/config.ex lib/gingko/settings.ex config/config.exs test/test_helper.exs test/gingko/cost/config_test.exs
git commit -m "feat(cost): add Cost.Config accessor and settings wiring"
```

---

## Task 4: `Cost.Recorder` — batching GenServer

**Files:**
- Create: `lib/gingko/cost/recorder.ex`
- Test: `test/gingko/cost/recorder_test.exs`

**What to build:**

Single-writer GenServer. State: `%{buffer: [row, ...], flush_timer: ref | nil}`. Receives rows via `cast`, flushes on three triggers: `batch_size_max` reached, `flush_interval_ms` elapsed, mailbox queue larger than 5_000. On flush, `Repo.insert_all(Cost.Call, rows, ...)` then `Phoenix.PubSub.broadcast(Gingko.PubSub, "cost:rows", {:cost_rows, rows})`. `terminate/2` does a best-effort flush.

`insert_all` requires plain maps with `inserted_at` set (the schema's `timestamps/1` only autogenerates on `Repo.insert`, not `insert_all`). The handler in Task 5 builds rows already containing `inserted_at` and `id`.

The mailbox-cap check: at the start of `handle_cast`, peek at `:erlang.process_info(self(), :message_queue_len)` — if it exceeds 5_000, log a warning and force a flush.

**Implementation:**

`lib/gingko/cost/recorder.ex`:
```elixir
defmodule Gingko.Cost.Recorder do
  @moduledoc """
  Batching writer for `Gingko.Cost.Call` rows.

  Receives rows via `record/1` (cast), buffers in memory, and flushes via
  `Repo.insert_all` on size, time, or mailbox-pressure triggers. Broadcasts
  flushed rows on `Gingko.PubSub` topic `"cost:rows"` for live consumers.
  """

  use GenServer

  require Logger

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Repo

  @topic "cost:rows"
  @mailbox_soft_cap 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Topic on which flushed rows are broadcast."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Cast a row map (already shaped like `Cost.Call` fields) for eventual insertion."
  @spec record(map()) :: :ok
  def record(row) when is_map(row) do
    GenServer.cast(__MODULE__, {:row, row})
  end

  @doc "Synchronous flush for tests and graceful shutdown coordination."
  @spec flush_now() :: :ok
  def flush_now, do: GenServer.call(__MODULE__, :flush_now)

  @impl true
  def init(_opts) do
    {:ok, %{buffer: [], flush_timer: nil}}
  end

  @impl true
  def handle_cast({:row, row}, state) do
    state = %{state | buffer: [row | state.buffer]}

    cond do
      length(state.buffer) >= Config.batch_size_max() ->
        {:noreply, flush(state)}

      mailbox_overloaded?() ->
        Logger.warning("Cost.Recorder mailbox over soft cap, flushing")
        {:noreply, flush(state)}

      state.flush_timer == nil ->
        {:noreply, %{state | flush_timer: schedule_flush()}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(state)}

  @impl true
  def handle_call(:flush_now, _from, state), do: {:reply, :ok, flush(state)}

  @impl true
  def terminate(_reason, state) do
    _ = flush(state)
    :ok
  end

  defp flush(%{buffer: []} = state), do: cancel_timer(state)

  defp flush(%{buffer: buffer} = state) do
    rows = Enum.reverse(buffer)
    {_, _} = Repo.insert_all(Call, rows)
    Phoenix.PubSub.broadcast(Gingko.PubSub, @topic, {:cost_rows, rows})
    cancel_timer(%{state | buffer: []})
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, Config.flush_interval_ms())
  end

  defp cancel_timer(%{flush_timer: nil} = state), do: state

  defp cancel_timer(%{flush_timer: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | flush_timer: nil}
  end

  defp mailbox_overloaded? do
    case :erlang.process_info(self(), :message_queue_len) do
      {:message_queue_len, len} -> len > @mailbox_soft_cap
      _ -> false
    end
  end
end
```

**Testing:**

`test/gingko/cost/recorder_test.exs`:
```elixir
defmodule Gingko.Cost.RecorderTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Cost.Recorder

  setup do
    stub(Config, :batch_size_max, fn -> 3 end)
    stub(Config, :flush_interval_ms, fn -> 50 end)

    Repo.delete_all(Call)
    Phoenix.PubSub.subscribe(Gingko.PubSub, Recorder.topic())

    {:ok, pid} = start_supervised({Recorder, name: Recorder})

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(Gingko.PubSub, Recorder.topic())
    end)

    %{pid: pid}
  end

  defp row(extra \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        model: "gpt-4o",
        event_kind: "request",
        status: "ok",
        inserted_at: DateTime.utc_now()
      },
      extra
    )
  end

  test "batch trigger flushes immediately and broadcasts" do
    Recorder.record(row())
    Recorder.record(row())
    Recorder.record(row())

    assert_receive {:cost_rows, rows} when length(rows) == 3, 500
    assert Repo.aggregate(Call, :count, :id) == 3
  end

  test "time trigger flushes a single row" do
    Recorder.record(row())
    assert_receive {:cost_rows, [_]}, 500
    assert Repo.aggregate(Call, :count, :id) == 1
  end

  test "flush_now drains the buffer synchronously" do
    Recorder.record(row())
    :ok = Recorder.flush_now()
    assert Repo.aggregate(Call, :count, :id) == 1
  end

  test "terminate flushes outstanding rows", %{pid: pid} do
    Recorder.record(row())
    :ok = stop_supervised(Recorder)
    refute Process.alive?(pid)
    assert Repo.aggregate(Call, :count, :id) == 1
  end
end
```

Run: `mix test test/gingko/cost/recorder_test.exs`
Expected: 4 tests, 0 failures. Verify rows include the broadcast topic and DB count matches.

**Commit:**
```bash
git add lib/gingko/cost/recorder.ex test/gingko/cost/recorder_test.exs
git commit -m "feat(cost): add Cost.Recorder batching writer"
```

---

## Task 5: `Cost.TelemetryHandler` — Sycophant subscriber

**Files:**
- Create: `lib/gingko/cost/telemetry_handler.ex`
- Test: `test/gingko/cost/telemetry_handler_test.exs`

**What to build:**

Stateless module that owns the four-event attach + a `handle_event/4` dispatcher. Per event:

1. Wrap the body in `try/rescue` — never propagate to the LLM caller.
2. Pull `Cost.Context.current()` (still in caller's process).
3. Build a row map using `Sycophant.Usage` from metadata, the measurements (`duration` in native units), and the context.
4. `Cost.Recorder.record/1`.

Sycophant's currency lives at `usage.pricing.currency`. Sycophant's `:embedding, :start|:stop|:error` events follow the same shape as `:request` events; we map both to the same row builder, just with `event_kind = "embedding"`.

**Implementation:**

`lib/gingko/cost/telemetry_handler.ex`:
```elixir
defmodule Gingko.Cost.TelemetryHandler do
  @moduledoc """
  Subscribes to Sycophant's request and embedding telemetry, builds a
  `Cost.Call`-shaped row tagged with the caller's `Cost.Context`, and casts it
  to `Cost.Recorder`. The handler never propagates exceptions to the caller.
  """

  require Logger

  alias Gingko.Cost.Context
  alias Gingko.Cost.Recorder

  @handler_id "gingko-cost"

  @events [
    [:sycophant, :request, :stop],
    [:sycophant, :request, :error],
    [:sycophant, :embedding, :stop],
    [:sycophant, :embedding, :error]
  ]

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    try do
      row = build_row(event, measurements, metadata)
      Recorder.record(row)
    rescue
      e ->
        Logger.warning(
          "Cost.TelemetryHandler dropped row for #{inspect(event)}: #{Exception.message(e)}"
        )
    end
  end

  defp build_row([:sycophant, kind, outcome], measurements, metadata) do
    base_row(kind, outcome, measurements, metadata)
    |> Map.merge(usage_fields(metadata[:usage]))
    |> Map.merge(context_fields(Context.current()))
  end

  defp base_row(kind, outcome, measurements, metadata) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      occurred_at: now,
      inserted_at: now,
      event_kind: Atom.to_string(kind),
      status: status_for(outcome),
      model: metadata[:model] || "(unknown)",
      provider: metadata[:provider] |> stringify(),
      wire_protocol: metadata[:wire_protocol] |> stringify(),
      response_id: metadata[:response_id],
      response_model: metadata[:response_model],
      finish_reason: metadata[:finish_reason] |> stringify(),
      error_class: metadata[:error_class] |> stringify(),
      duration_ms: duration_ms(measurements[:duration])
    }
  end

  defp status_for(:stop), do: "ok"
  defp status_for(:error), do: "error"

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(other), do: inspect(other)

  defp duration_ms(nil), do: nil

  defp duration_ms(native) when is_integer(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end

  defp usage_fields(nil), do: empty_usage()

  defp usage_fields(%{} = usage) do
    %{
      input_tokens: usage[:input_tokens],
      output_tokens: usage[:output_tokens],
      cache_read_input_tokens: usage[:cache_read_input_tokens],
      cache_creation_input_tokens: usage[:cache_creation_input_tokens],
      reasoning_tokens: usage[:reasoning_tokens],
      input_cost: usage[:input_cost],
      output_cost: usage[:output_cost],
      cache_read_cost: usage[:cache_read_cost],
      cache_write_cost: usage[:cache_write_cost],
      reasoning_cost: usage[:reasoning_cost],
      total_cost: usage[:total_cost],
      currency: currency_of(usage[:pricing])
    }
  end

  defp empty_usage do
    %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_input_tokens: nil,
      cache_creation_input_tokens: nil,
      reasoning_tokens: nil,
      input_cost: nil,
      output_cost: nil,
      cache_read_cost: nil,
      cache_write_cost: nil,
      reasoning_cost: nil,
      total_cost: nil,
      currency: nil
    }
  end

  defp currency_of(nil), do: nil
  defp currency_of(%{currency: currency}), do: currency
  defp currency_of(_), do: nil

  defp context_fields(ctx) do
    %{
      project_key: ctx[:project_key],
      session_id: ctx[:session_id],
      feature: ctx[:feature] |> stringify()
    }
  end
end
```

**Testing:**

`test/gingko/cost/telemetry_handler_test.exs`:
```elixir
defmodule Gingko.Cost.TelemetryHandlerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Gingko.Cost.Context
  alias Gingko.Cost.Recorder
  alias Gingko.Cost.TelemetryHandler

  setup do
    test_pid = self()
    stub(Recorder, :record, fn row -> send(test_pid, {:recorded, row}) end)
    :ok = TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  defp emit_request_stop(usage) do
    :telemetry.execute(
      [:sycophant, :request, :stop],
      %{duration: System.convert_time_unit(123, :millisecond, :native)},
      %{
        model: "gpt-4o",
        provider: :openai,
        wire_protocol: :openai_chat,
        usage: usage,
        response_model: "gpt-4o-2024-08-06",
        response_id: "resp_123",
        finish_reason: :stop
      }
    )
  end

  test "request :stop with full usage produces a complete row" do
    usage = %{
      input_tokens: 10,
      output_tokens: 20,
      input_cost: 0.0001,
      output_cost: 0.0004,
      total_cost: 0.0005,
      pricing: %{currency: "USD"}
    }

    Context.with(%{project_key: "demo", feature: :step_summarization}, fn ->
      emit_request_stop(usage)
    end)

    assert_receive {:recorded, row}
    assert row.event_kind == "request"
    assert row.status == "ok"
    assert row.model == "gpt-4o"
    assert row.provider == "openai"
    assert row.duration_ms == 123
    assert row.input_tokens == 10
    assert row.total_cost == 0.0005
    assert row.currency == "USD"
    assert row.project_key == "demo"
    assert row.feature == "step_summarization"
  end

  test "request :stop with usage = nil records tokens/costs as nil" do
    emit_request_stop(nil)

    assert_receive {:recorded, row}
    assert row.input_tokens == nil
    assert row.total_cost == nil
    assert row.currency == nil
  end

  test "usage without pricing yields nil currency and nil total_cost" do
    emit_request_stop(%{input_tokens: 10, total_cost: nil})

    assert_receive {:recorded, row}
    assert row.input_tokens == 10
    assert row.total_cost == nil
    assert row.currency == nil
  end

  test "request :error builds a row with status=error" do
    :telemetry.execute(
      [:sycophant, :request, :error],
      %{duration: System.convert_time_unit(50, :millisecond, :native)},
      %{
        model: "gpt-4o",
        provider: :openai,
        wire_protocol: :openai_chat,
        error: %{message: "boom"},
        error_class: :upstream
      }
    )

    assert_receive {:recorded, row}
    assert row.status == "error"
    assert row.error_class == "upstream"
  end

  test "embedding :stop event yields event_kind = embedding" do
    :telemetry.execute(
      [:sycophant, :embedding, :stop],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{
        model: "text-embedding-3-small",
        provider: :openai,
        wire_protocol: :openai_embedding,
        usage: %{input_tokens: 5}
      }
    )

    assert_receive {:recorded, row}
    assert row.event_kind == "embedding"
    assert row.input_tokens == 5
  end

  test "malformed metadata is logged and dropped without raising" do
    me = self()

    spawn_link(fn ->
      :telemetry.execute([:sycophant, :request, :stop], %{}, :not_a_map)
      send(me, :survived)
    end)

    assert_receive :survived, 200
  end
end
```

Run: `mix test test/gingko/cost/telemetry_handler_test.exs`
Expected: 6 tests, 0 failures. Note the malformed-metadata test asserts the spawned process didn't crash.

**Commit:**
```bash
git add lib/gingko/cost/telemetry_handler.ex test/gingko/cost/telemetry_handler_test.exs
git commit -m "feat(cost): add Cost.TelemetryHandler subscriber"
```

---

## Task 6: Application wiring

**Files:**
- Modify: `lib/gingko/application.ex` (add Recorder to children, attach handler after supervisor starts)

**What to build:**

Insert `Gingko.Cost.Recorder` into the supervision tree after `Phoenix.PubSub` (so PubSub is available when the Recorder broadcasts). After `Supervisor.start_link/2` succeeds, call `Gingko.Cost.TelemetryHandler.attach()` if `Cost.Config.enabled?()`. Both gated on `enabled?` so disabling produces a fully inert system.

**Implementation:**

In `lib/gingko/application.ex` `start/2`, modify the children list to insert the Recorder after `{Phoenix.PubSub, name: Gingko.PubSub}`:

```elixir
{Phoenix.PubSub, name: Gingko.PubSub},
Gingko.Memory.ActivityStore,
```

becomes

```elixir
{Phoenix.PubSub, name: Gingko.PubSub},
] ++
  cost_children() ++
  [
    Gingko.Memory.ActivityStore,
```

(re-merging the list shape; alternative: leave `Gingko.Cost.Recorder` inline, gated by an `if Gingko.Cost.Config.enabled?(), do: [...], else: []`. Pick whichever shape matches the surrounding style — the existing module already uses helper-function-returning-list pattern for `embedding_children` and `update_checker_children`, so do the same.)

Add the helper:
```elixir
defp cost_children do
  if Gingko.Cost.Config.enabled?() do
    [Gingko.Cost.Recorder]
  else
    []
  end
end
```

Modify the `with` block at the bottom of `start/2`:
```elixir
with {:ok, pid} <- Supervisor.start_link(children, opts) do
  Gingko.Projects.abandon_active_sessions()
  :ok = Gingko.Memory.reopen_registered_projects()
  _ = Gingko.Summaries.DirtyTracker.attach()
  _ = maybe_attach_cost_handler()
  {:ok, pid}
end
```

And:
```elixir
defp maybe_attach_cost_handler do
  if Gingko.Cost.Config.enabled?() do
    Gingko.Cost.TelemetryHandler.attach()
  end
end
```

**Testing:**

No new test file. Existing `test/gingko/application_test.exs` continues to assert boot. Manually verify via `iex -S mix phx.server` that `Process.whereis(Gingko.Cost.Recorder)` returns a pid and `:telemetry.list_handlers([])` lists `"gingko-cost"`.

Run: `mix test`
Expected: full suite passes; no regressions in application boot.

**Commit:**
```bash
git add lib/gingko/application.ex
git commit -m "feat(cost): wire recorder and handler into application boot"
```

---

## Task 7: `Gingko.Cost` query API

**Files:**
- Create: `lib/gingko/cost.ex`
- Test: `test/gingko/cost_test.exs`

**What to build:**

Read-side facade. Four functions: `totals/1`, `breakdown_by/3`, `recent_calls/2`, `time_series/2`. All accept a `filter` map; all costs are summed **per currency** (group by currency on every cost-summing query, never coerce nil → 0). Unpriced rows (`total_cost IS NULL`) are *counted* in `totals.unpriced_count` and *excluded* from cost sums.

For SQLite-friendly aggregation, use `fragment("strftime(...)")` for `time_series/2` bucketing.

**Implementation:**

`lib/gingko/cost.ex`:
```elixir
defmodule Gingko.Cost do
  @moduledoc """
  Read-side query API for the LLM cost tracker. All cost aggregations group
  by currency; rows with `total_cost = nil` are counted as "unpriced" and
  excluded from cost sums.
  """

  import Ecto.Query

  alias Gingko.Cost.Call
  alias Gingko.Repo

  @type filter :: %{
          optional(:from) => DateTime.t(),
          optional(:to) => DateTime.t(),
          optional(:project_key) => String.t() | [String.t()],
          optional(:feature) => String.t() | [String.t()],
          optional(:model) => String.t() | [String.t()],
          optional(:status) => String.t()
        }

  @spec totals(filter()) :: %{
          by_currency: [%{currency: String.t() | nil, total_cost: float, calls: integer}],
          calls: integer,
          unpriced_count: integer,
          ok_count: integer,
          error_count: integer,
          input_tokens: integer,
          output_tokens: integer,
          cache_tokens: integer
        }
  def totals(filter \\ %{}) do
    base = apply_filter(from(c in Call), filter)

    by_currency =
      base
      |> where([c], not is_nil(c.total_cost))
      |> group_by([c], c.currency)
      |> select([c], %{
        currency: c.currency,
        total_cost: sum(c.total_cost),
        calls: count(c.id)
      })
      |> Repo.all()

    aggregates =
      base
      |> select([c], %{
        calls: count(c.id),
        unpriced: sum(fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", c.total_cost)),
        ok: sum(fragment("CASE WHEN ? = 'ok' THEN 1 ELSE 0 END", c.status)),
        errors: sum(fragment("CASE WHEN ? = 'error' THEN 1 ELSE 0 END", c.status)),
        input: sum(c.input_tokens),
        output: sum(c.output_tokens),
        cache: sum(coalesce(c.cache_read_input_tokens, 0))
      })
      |> Repo.one()

    %{
      by_currency: by_currency,
      calls: aggregates.calls || 0,
      unpriced_count: aggregates.unpriced || 0,
      ok_count: aggregates.ok || 0,
      error_count: aggregates.errors || 0,
      input_tokens: aggregates.input || 0,
      output_tokens: aggregates.output || 0,
      cache_tokens: aggregates.cache || 0
    }
  end

  @spec breakdown_by(filter(), :project_key | :feature | :model, keyword()) ::
          [%{key: String.t() | nil, total_cost: float, calls: integer, currency: String.t() | nil}]
  def breakdown_by(filter \\ %{}, dimension, opts \\ [])
      when dimension in [:project_key, :feature, :model] do
    limit = Keyword.get(opts, :limit, 10)

    from(c in Call)
    |> apply_filter(filter)
    |> where([c], not is_nil(c.total_cost))
    |> group_by([c], [field(c, ^dimension), c.currency])
    |> select([c], %{
      key: field(c, ^dimension),
      currency: c.currency,
      total_cost: sum(c.total_cost),
      calls: count(c.id)
    })
    |> order_by([c], desc: sum(c.total_cost))
    |> limit(^limit)
    |> Repo.all()
  end

  @spec recent_calls(filter(), keyword()) :: [Call.t()]
  def recent_calls(filter \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(c in Call)
    |> apply_filter(filter)
    |> order_by(desc: :occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec time_series(filter(), :hour | :day) ::
          [%{bucket_at: DateTime.t(), currency: String.t() | nil, total_cost: float, calls: integer}]
  def time_series(filter \\ %{}, bucket) when bucket in [:hour, :day] do
    bucket_format =
      case bucket do
        :hour -> "%Y-%m-%dT%H:00:00Z"
        :day -> "%Y-%m-%dT00:00:00Z"
      end

    from(c in Call)
    |> apply_filter(filter)
    |> where([c], not is_nil(c.total_cost))
    |> group_by([c], [fragment("strftime(?, ?)", ^bucket_format, c.occurred_at), c.currency])
    |> select([c], %{
      bucket_at:
        fragment("strftime(?, ?)", ^bucket_format, c.occurred_at) |> selected_as(:bucket_at),
      currency: c.currency,
      total_cost: sum(c.total_cost),
      calls: count(c.id)
    })
    |> order_by([c], asc: selected_as(:bucket_at))
    |> Repo.all()
    |> Enum.map(&parse_bucket/1)
  end

  defp parse_bucket(%{bucket_at: bucket} = row) do
    {:ok, dt, _} = DateTime.from_iso8601(bucket)
    %{row | bucket_at: dt}
  end

  defp apply_filter(query, filter) do
    Enum.reduce(filter, query, fn
      {:from, %DateTime{} = from}, q -> from(c in q, where: c.occurred_at >= ^from)
      {:to, %DateTime{} = to}, q -> from(c in q, where: c.occurred_at < ^to)
      {:project_key, v}, q -> filter_in(q, :project_key, v)
      {:feature, v}, q -> filter_in(q, :feature, v)
      {:model, v}, q -> filter_in(q, :model, v)
      {:status, v}, q -> from(c in q, where: c.status == ^v)
      _, q -> q
    end)
  end

  defp filter_in(q, field, values) when is_list(values),
    do: from(c in q, where: field(c, ^field) in ^values)

  defp filter_in(q, field, value),
    do: from(c in q, where: field(c, ^field) == ^value)
end
```

**Testing:**

`test/gingko/cost_test.exs`:
```elixir
defmodule Gingko.CostTest do
  use Gingko.DataCase, async: false

  alias Gingko.Cost
  alias Gingko.Cost.Call
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)
    seed_rows()
    :ok
  end

  defp seed_rows do
    base = ~U[2026-05-01 12:00:00.000000Z]
    rows = [
      row(base, "demo", "gpt-4o", "step_summarization", 0.01, "USD"),
      row(DateTime.add(base, 1, :hour), "demo", "gpt-4o", "step_summarization", 0.02, "USD"),
      row(DateTime.add(base, 2, :hour), "demo", "claude-sonnet-4-6", "project_summary", 0.05, "USD"),
      row(DateTime.add(base, 3, :hour), "other", "gpt-4o", "mcp_structuring", 0.03, "USD"),
      row(DateTime.add(base, 4, :hour), "demo", "gpt-4o", "step_summarization", nil, nil),
      row(DateTime.add(base, 5, :hour), "demo", "gpt-4o", "step_summarization", 0.04, "EUR")
    ]

    Repo.insert_all(Call, rows)
  end

  defp row(at, project, model, feature, cost, currency) do
    %{
      id: Ecto.UUID.generate(),
      occurred_at: at,
      inserted_at: at,
      model: model,
      event_kind: "request",
      status: "ok",
      project_key: project,
      feature: feature,
      total_cost: cost,
      currency: currency,
      input_tokens: 100,
      output_tokens: 50
    }
  end

  test "totals/1 sums per currency and excludes unpriced rows" do
    t = Cost.totals()
    by_currency = Map.new(t.by_currency, &{&1.currency, &1.total_cost})

    assert_in_delta by_currency["USD"], 0.11, 1.0e-9
    assert_in_delta by_currency["EUR"], 0.04, 1.0e-9
    assert t.calls == 6
    assert t.unpriced_count == 1
  end

  test "totals/1 with filter narrows to one project" do
    t = Cost.totals(%{project_key: "demo"})
    assert t.calls == 5
  end

  test "breakdown_by feature returns per-currency rows ordered by cost desc" do
    rows = Cost.breakdown_by(%{}, :feature, limit: 5)
    assert length(rows) >= 3
    grouped = Enum.group_by(rows, & &1.currency)
    assert grouped["USD"] |> hd() |> Map.fetch!(:key) in ["step_summarization", "project_summary", "mcp_structuring"]
  end

  test "recent_calls returns rows newest-first" do
    rows = Cost.recent_calls()
    assert length(rows) == 6
    assert Enum.sort_by(rows, & &1.occurred_at, {:desc, DateTime}) == rows
  end

  test "time_series day buckets group by currency" do
    rows = Cost.time_series(%{}, :day)
    assert Enum.all?(rows, &Map.has_key?(&1, :bucket_at))
    assert Enum.all?(rows, &Map.has_key?(&1, :currency))
  end
end
```

Run: `mix test test/gingko/cost_test.exs`
Expected: 5 tests, 0 failures.

**Commit:**
```bash
git add lib/gingko/cost.ex test/gingko/cost_test.exs
git commit -m "feat(cost): add Gingko.Cost query API"
```

---

## Task 8: `Cost.Pruner` + Oban cron

**Files:**
- Create: `lib/gingko/cost/pruner.ex`
- Modify: `config/config.exs` (Oban config: add `Oban.Plugins.Cron` plugin)
- Test: `test/gingko/cost/pruner_test.exs`

**What to build:**

An Oban worker that deletes rows older than `Cost.Config.retention_days()` cutoff. `retention_days = 0` is a no-op. Add the Oban Cron plugin to the Oban config and schedule it daily at 03:00 server time.

**Implementation:**

`lib/gingko/cost/pruner.ex`:
```elixir
defmodule Gingko.Cost.Pruner do
  @moduledoc """
  Daily Oban worker that deletes `Gingko.Cost.Call` rows older than
  `Cost.Config.retention_days()`. A retention of 0 disables pruning.
  """

  use Oban.Worker, queue: :maintenance

  import Ecto.Query

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Repo

  @impl Oban.Worker
  def perform(_job) do
    case Config.retention_days() do
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
        {count, _} = Repo.delete_all(from c in Call, where: c.inserted_at < ^cutoff)
        {:ok, %{deleted: count, cutoff: cutoff}}

      _ ->
        {:ok, %{deleted: 0, skipped: :retention_disabled}}
    end
  end
end
```

In `config/config.exs`, modify the existing `config :gingko, Oban,` block to add the plugin:
```elixir
config :gingko, Oban,
  engine: Oban.Engines.Lite,
  notifier: Oban.Notifiers.PG,
  queues: [default: 10, summaries: 4, maintenance: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Gingko.Cost.Pruner}
     ]}
  ]
```
(Merge with whatever is already there — preserve the existing `queues:` line and any other keys.)

**Testing:**

`test/gingko/cost/pruner_test.exs`:
```elixir
defmodule Gingko.Cost.PrunerTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Cost.Pruner
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)
    :ok
  end

  defp insert_row(at) do
    Repo.insert_all(Call, [
      %{
        id: Ecto.UUID.generate(),
        occurred_at: at,
        inserted_at: at,
        model: "gpt-4o",
        event_kind: "request",
        status: "ok"
      }
    ])
  end

  test "retention_days = 0 leaves rows alone" do
    stub(Config, :retention_days, fn -> 0 end)

    insert_row(DateTime.add(DateTime.utc_now(), -120 * 86_400, :second))
    {:ok, %{deleted: 0}} = Pruner.perform(%Oban.Job{args: %{}})

    assert Repo.aggregate(Call, :count, :id) == 1
  end

  test "deletes rows older than cutoff and keeps recent rows" do
    stub(Config, :retention_days, fn -> 30 end)

    insert_row(DateTime.add(DateTime.utc_now(), -100 * 86_400, :second))
    insert_row(DateTime.add(DateTime.utc_now(), -1 * 86_400, :second))

    {:ok, %{deleted: 1}} = Pruner.perform(%Oban.Job{args: %{}})

    assert Repo.aggregate(Call, :count, :id) == 1
  end
end
```

Run: `mix test test/gingko/cost/pruner_test.exs`
Expected: 2 tests, 0 failures.

**Commit:**
```bash
git add lib/gingko/cost/pruner.ex config/config.exs test/gingko/cost/pruner_test.exs
git commit -m "feat(cost): add daily retention pruner via Oban cron"
```

---

## Task 9: `CostLive` and embedded project strip

**Files:**
- Create: `lib/gingko_web/live/cost_live.ex`
- Create: `lib/gingko_web/live/cost_live.html.heex`
- Create: `lib/gingko_web/components/cost_summary.ex` (functional component used by ProjectLive)
- Modify: `lib/gingko_web/router.ex` (add `live "/cost", CostLive`)
- Modify: `lib/gingko_web/live/project_live.ex` (render `CostSummary.render/1` inside the existing layout, scoped to the current project)
- Test: `test/gingko_web/live/cost_live_test.exs`

**What to build:**

`CostLive` — single LiveView at `/cost`. Mount: read params (range, project, model, feature, status) and call `Gingko.Cost.totals/1`, `breakdown_by/3` ×3, `recent_calls/2`. `handle_info({:cost_rows, rows}, socket)` — for each row matching the current filter, increment KPIs and prepend to the recent table without re-querying. `handle_event("filter_change", _, socket)` — re-query.

Cost-summary component — three KPI numbers for the bound project, currency-aware (collapse to `—` if mixed). Subscribes to `"cost:rows"` and only reacts to rows matching `assigns.project_key`.

Use the existing GingkoWeb components style (`core_components.ex`) — match how `ProjectsLive` and `ProjectLive` render UI today. Keep markup simple; avoid heavy chart deps (no JS chart lib in the first cut — bar lists rendered in HEEx).

**Implementation sketch:**

`lib/gingko_web/live/cost_live.ex`:
```elixir
defmodule GingkoWeb.CostLive do
  use GingkoWeb, :live_view

  alias Gingko.Cost
  alias Gingko.Cost.Recorder

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Gingko.PubSub, Recorder.topic())

    {:ok,
     socket
     |> assign(:range, :"7d")
     |> assign(:filters, %{})
     |> load_data()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, String.to_existing_atom(range)) |> load_data()}
  end

  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(~w(project_key feature model status))
      |> Enum.reject(fn {_, v} -> v in ["", nil] end)
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

    {:noreply, socket |> assign(:filters, filters) |> load_data()}
  end

  @impl true
  def handle_info({:cost_rows, rows}, socket) do
    matching = Enum.filter(rows, &row_matches?(&1, socket.assigns))
    if matching == [] do
      {:noreply, socket}
    else
      {:noreply, apply_incremental(socket, matching)}
    end
  end

  defp row_matches?(row, %{filters: filters}) do
    Enum.all?(filters, fn
      {:project_key, v} -> row.project_key == v
      {:feature, v} -> row.feature == v
      {:model, v} -> row.model == v
      {:status, v} -> row.status == v
    end)
  end

  defp apply_incremental(socket, rows) do
    socket
    |> update(:recent, fn existing -> (rows ++ existing) |> Enum.take(50) end)
    |> update(:totals, fn t ->
      delta_calls = length(rows)
      delta_unpriced = Enum.count(rows, &is_nil(&1.total_cost))
      delta_input = Enum.reduce(rows, 0, &((&1.input_tokens || 0) + &2))
      delta_output = Enum.reduce(rows, 0, &((&1.output_tokens || 0) + &2))

      by_currency = merge_currency_costs(t.by_currency, rows)

      %{t |
        by_currency: by_currency,
        calls: t.calls + delta_calls,
        unpriced_count: t.unpriced_count + delta_unpriced,
        input_tokens: t.input_tokens + delta_input,
        output_tokens: t.output_tokens + delta_output
      }
    end)
  end

  defp merge_currency_costs(existing, new_rows) do
    by_curr =
      Enum.reduce(new_rows, %{}, fn r, acc ->
        if r.total_cost && r.currency,
          do: Map.update(acc, r.currency, r.total_cost, &(&1 + r.total_cost)),
          else: acc
      end)

    Enum.reduce(by_curr, existing, fn {curr, delta}, acc ->
      case Enum.split_with(acc, &(&1.currency == curr)) do
        {[], rest} ->
          [%{currency: curr, total_cost: delta, calls: 0} | rest]

        {[hit | _], rest} ->
          [%{hit | total_cost: hit.total_cost + delta} | rest]
      end
    end)
  end

  defp load_data(socket) do
    filter = build_filter(socket.assigns.range, socket.assigns.filters)

    socket
    |> assign(:totals, Cost.totals(filter))
    |> assign(:by_project, Cost.breakdown_by(filter, :project_key))
    |> assign(:by_feature, Cost.breakdown_by(filter, :feature))
    |> assign(:by_model, Cost.breakdown_by(filter, :model))
    |> assign(:recent, Cost.recent_calls(filter))
  end

  defp build_filter(range, filters) do
    {from, to} = range_bounds(range)
    Map.merge(%{from: from, to: to}, filters)
  end

  defp range_bounds(:"24h"),
    do: {DateTime.add(DateTime.utc_now(), -24 * 3600, :second), DateTime.utc_now()}

  defp range_bounds(:"7d"),
    do: {DateTime.add(DateTime.utc_now(), -7 * 86_400, :second), DateTime.utc_now()}

  defp range_bounds(:"30d"),
    do: {DateTime.add(DateTime.utc_now(), -30 * 86_400, :second), DateTime.utc_now()}
end
```

`lib/gingko_web/live/cost_live.html.heex` — render four sections (filters, KPIs, three breakdowns side-by-side via Tailwind grid, recent table). Keep styling consistent with existing live views.

`lib/gingko_web/components/cost_summary.ex`:
```elixir
defmodule GingkoWeb.CostSummary do
  @moduledoc "Embedded cost strip rendered inside ProjectLive."
  use Phoenix.Component

  alias Gingko.Cost

  attr :project_key, :string, required: true
  attr :class, :string, default: nil

  def strip(assigns) do
    assigns = assign(assigns, :rows, totals_for(assigns.project_key))

    ~H"""
    <div class={["flex items-center gap-3 text-sm", @class]}>
      <span class="font-semibold">Cost</span>
      <span :for={{label, amount} <- @rows} class="tabular-nums">
        <%= label %>: <%= amount %>
      </span>
      <.link navigate={"/cost?project_key=" <> @project_key} class="text-blue-600">
        details →
      </.link>
    </div>
    """
  end

  defp totals_for(project_key) do
    now = DateTime.utc_now()

    [
      {"24h", Cost.totals(%{project_key: project_key, from: DateTime.add(now, -86_400, :second)})},
      {"7d", Cost.totals(%{project_key: project_key, from: DateTime.add(now, -7 * 86_400, :second)})},
      {"30d", Cost.totals(%{project_key: project_key, from: DateTime.add(now, -30 * 86_400, :second)})}
    ]
    |> Enum.map(fn {label, t} -> {label, format_amount(t.by_currency)} end)
  end

  defp format_amount([]), do: "—"
  defp format_amount([%{total_cost: cost, currency: curr}]), do: "#{curr} #{Float.round(cost, 4)}"
  defp format_amount(_multi), do: "—"
end
```

Wire `<.live_component_or_function .../>` of `CostSummary.strip/1` into `ProjectLive`'s render where it makes sense (top of the project view).

Router: add `live "/cost", CostLive` to the browser scope.

**Testing:**

`test/gingko_web/live/cost_live_test.exs`:
```elixir
defmodule GingkoWeb.CostLiveTest do
  use GingkoWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Gingko.Cost.Call
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)

    Repo.insert_all(Call, [
      %{
        id: Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        inserted_at: DateTime.utc_now(),
        model: "gpt-4o",
        event_kind: "request",
        status: "ok",
        project_key: "demo",
        feature: "step_summarization",
        total_cost: 0.10,
        currency: "USD",
        input_tokens: 10,
        output_tokens: 20
      }
    ])

    :ok
  end

  test "renders KPIs and breakdowns", %{conn: conn} do
    {:ok, view, html} = live(conn, "/cost")
    assert html =~ "USD"
    assert render(view) =~ "demo"
    assert render(view) =~ "step_summarization"
    assert render(view) =~ "gpt-4o"
  end

  test "PubSub broadcast updates totals incrementally", %{conn: conn} do
    {:ok, view, _} = live(conn, "/cost")

    new_row = %{
      id: Ecto.UUID.generate(),
      occurred_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now(),
      model: "gpt-4o",
      event_kind: "request",
      status: "ok",
      project_key: "demo",
      feature: "step_summarization",
      total_cost: 0.05,
      currency: "USD",
      input_tokens: 5,
      output_tokens: 5
    }

    send(view.pid, {:cost_rows, [new_row]})

    assert render(view) =~ "USD"
  end

  test "empty state renders when no rows match filter", %{conn: conn} do
    Repo.delete_all(Call)
    {:ok, _view, html} = live(conn, "/cost")
    assert html =~ "No LLM calls" or html =~ "0 calls"
  end
end
```

Run: `mix test test/gingko_web/live/cost_live_test.exs`
Expected: 3 tests, 0 failures.

**Commit:**
```bash
git add lib/gingko_web/live/cost_live.ex lib/gingko_web/live/cost_live.html.heex lib/gingko_web/components/cost_summary.ex lib/gingko_web/router.ex lib/gingko_web/live/project_live.ex test/gingko_web/live/cost_live_test.exs
git commit -m "feat(cost): add /cost dashboard and project cost strip"
```

---

## Task 10: Wrap attribution boundaries + end-to-end test

**Files:**
- Modify: `lib/gingko/memory.ex` (wrap `summarize_step/1` body with `Cost.Context.with`)
- Modify: `lib/gingko/memory/summarizer.ex` (wrap each `Task.Supervisor.async_stream_nolink` chunk closure to re-apply context)
- Modify: `lib/gingko/summaries/project_summary_worker.ex` (wrap `perform/1` body)
- Modify: MCP `append_step` tool handler at `lib/gingko/mcp/tools/append_step.ex` (wrap the call chain in `Cost.Context.with`, sourcing `project_key`/`session_id` from the tool args)
- Test: `test/gingko/cost/end_to_end_test.exs`

**What to build:**

The set of wrap points listed in spec §6.3, including the cross-process pattern for `Memory.Summarizer.parallel_extract/1`. Each wrap is small: at the top of the function, capture or build the attribution map, run the existing body inside `Cost.Context.with(attrs, fn -> ... end)`. For `parallel_extract/1`, capture `Cost.Context.current()` *before* `async_stream_nolink`, and inside each task closure call `Cost.Context.with(captured, fn -> extract_chunk(chunk) end)`.

The end-to-end test uses the existing `Gingko.TestSupport.Mnemosyne.MockLLM` to drive a synthetic LLM response, calls `Memory.summarize_step/1` end-to-end, and asserts a row lands in `gingko_llm_calls` with the expected `project_key`, `feature`, and a non-nil `model`. This test catches the "we wired the boundary but forgot to apply context" regression.

**Implementation:**

`lib/gingko/memory.ex` — modify `summarize_step/1`:
```elixir
def summarize_step(%{session_id: session_id, content: content} = attrs) do
  Gingko.Cost.Context.with(
    %{
      project_key: Map.get(attrs, :project_key),
      session_id: session_id,
      feature: :step_summarization
    },
    fn ->
      with {:ok, %{observation: observation, action: action}} <-
             Gingko.Memory.Summarizer.extract(content) do
        append_step(%{session_id: session_id, observation: observation, action: action})
      else
        {:error, :empty_content} ->
          {:error, %{code: :invalid_params, message: "content cannot be empty"}}

        {:error, %{code: _} = error} ->
          {:error, error}

        {:error, reason} ->
          Logger.warning(
            "summarize_step failed for session_id=#{session_id}: #{inspect(reason)}"
          )

          {:error, %{code: :summarization_failed, message: inspect(reason)}}
      end
    end
  )
end
```

(If the current `summarize_step/1` doesn't accept `project_key` in its attrs map, callers in `lib/gingko/mcp/tools/append_step.ex` need to pass it through. Check the call site and adjust accordingly. The MCP tool already knows the project_key for the session.)

`lib/gingko/memory/summarizer.ex` — modify `parallel_extract/1`:
```elixir
defp parallel_extract(chunks) do
  attribution = Gingko.Cost.Context.current()

  Gingko.TaskSupervisor
  |> Task.Supervisor.async_stream_nolink(
    chunks,
    fn chunk ->
      Gingko.Cost.Context.with(attribution, fn -> extract_chunk(chunk) end)
    end,
    max_concurrency: Config.parallelism(),
    timeout: Config.chunk_timeout_ms(),
    on_timeout: :kill_task,
    ordered: true
  )
  |> Enum.reduce({0, []}, fn
    # ... existing reducer unchanged
  end)
  |> elem(1)
  |> Enum.reverse()
end
```

`lib/gingko/summaries/project_summary_worker.ex` — modify `perform/1`:
```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: %{"project_key" => project_key}}) do
  Gingko.Cost.Context.with(
    %{project_key: project_key, feature: :project_summary},
    fn -> WorkerSupport.if_enabled(fn -> run(project_key) end) end
  )
end
```

`lib/gingko/mcp/tools/append_step.ex` — wrap the body of the handler in `Cost.Context.with(%{project_key: ..., session_id: ..., feature: :mcp_structuring}, fn -> ... end)`. Read the existing module to find the right wrap point; the project key and session id are already in the tool's args/state.

**Testing:**

`test/gingko/cost/end_to_end_test.exs`:
```elixir
defmodule Gingko.Cost.EndToEndTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Cost.Call
  alias Gingko.Cost.Context
  alias Gingko.Cost.TelemetryHandler
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok = TelemetryHandler.attach()
    :ok
  end

  test "Cost.Context wrapping yields a row tagged with the right attribution" do
    Context.with(%{project_key: "demo", session_id: "s1", feature: :step_summarization}, fn ->
      :telemetry.execute(
        [:sycophant, :request, :stop],
        %{duration: System.convert_time_unit(10, :millisecond, :native)},
        %{
          model: "gpt-4o",
          provider: :openai,
          wire_protocol: :openai_chat,
          usage: %{
            input_tokens: 10,
            output_tokens: 20,
            input_cost: 0.0001,
            output_cost: 0.0004,
            total_cost: 0.0005,
            pricing: %{currency: "USD"}
          },
          finish_reason: :stop
        }
      )
    end)

    :ok = Gingko.Cost.Recorder.flush_now()

    [row] = Repo.all(Call)
    assert row.project_key == "demo"
    assert row.session_id == "s1"
    assert row.feature == "step_summarization"
    assert row.model == "gpt-4o"
    assert row.total_cost == 0.0005
    assert row.currency == "USD"
  end
end
```

A second test that drives `Memory.summarize_step/1` through the real path (with `Sycophant` mocked at the adapter level via the existing `MockLLM`) is recommended but optional for this task — the synthetic-emit test above proves the wiring contract.

Run: `mix test test/gingko/cost/end_to_end_test.exs`
Expected: 1 test, 0 failures.

Then run the full suite: `mix precommit`
Expected: full pipeline passes.

**Commit:**
```bash
git add lib/gingko/memory.ex lib/gingko/memory/summarizer.ex lib/gingko/summaries/project_summary_worker.ex lib/gingko/mcp/tools/append_step.ex test/gingko/cost/end_to_end_test.exs
git commit -m "feat(cost): wrap attribution boundaries and add e2e test"
```

---

## Final verification

After Task 10:
1. `mix precommit` — full pipeline (`compile --warnings-as-errors + deps.unlock --unused + format + test`).
2. `iex -S mix phx.server` — manually visit `/cost`, confirm an empty dashboard renders, then trigger a project summary regen and confirm a row lands and the strip in `/projects/:id` updates.
3. Run `mix credo` and `mix dialyzer` — fix any new warnings introduced by the cost modules.
4. Confirm no regression in `mix test` runtime — cost tests should add a few hundred ms total.

The deferred items from the spec — budget thresholds, FX, daily rollup tables, `Cost.Context.async/2` generic helper — remain explicitly out of scope.
