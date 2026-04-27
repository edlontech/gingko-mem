defmodule Gingko.Summaries.Playbook do
  @moduledoc """
  Static recall playbook shipped with Gingko; seeded on project open.
  """

  @playbook_markdown """
  # Gingko Memory — Recall Playbook

  You have access to this project's memory via MCP tools. Memories live in a
  three-tier hierarchy.

  ## Tools at your disposal

  - `recall(project_id, query)` — semantic search across all raw memories.
  - `get_cluster(project_id, slug)` — expand one cluster from the index below.
  - `get_node(project_id, node_id)` — fetch a single memory by UUID.
  - `latest_memories(project_id, top_k)` — tail of most recent memories.
  - `append_step(session_id, observation, action)` — record a new memory.
  - `get_session_primer(project_id)` — re-fetch this whole document.

  ## How to use memory

  1. Read the **Project Charter** (if present) and **Project State** below for the
     big picture before doing anything.
  2. Scan the **Cluster Index** for topics relevant to the current task. If one
     matches, call `get_cluster` to read its summary.
  3. For specific factual questions, use `recall` with a targeted query.
  4. Check **Recent Memories** when you need "what was just happening" context
     that the summaries may not have absorbed yet.
  5. As you work, append observations and actions via `append_step`. These feed
     back into cluster summaries and the project state on the next regeneration.

  Always invoke the `gingko:memory` skill at session start to confirm tool-calling
  patterns and record observations as you go.
  """

  @doc "Returns the static playbook markdown shipped with Gingko."
  @spec markdown() :: String.t()
  def markdown, do: @playbook_markdown
end
