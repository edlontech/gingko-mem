plugins =
  [Phoenix.LiveView.HTMLFormatter] ++
    if Code.ensure_loaded?(Recode.FormatterPlugin), do: [Recode.FormatterPlugin], else: []

[
  import_deps: [:phoenix, :anubis_mcp],
  plugins: plugins,
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
