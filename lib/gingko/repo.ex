defmodule Gingko.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :gingko,
    adapter: Ecto.Adapters.SQLite3
end
