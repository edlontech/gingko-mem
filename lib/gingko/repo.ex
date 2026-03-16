defmodule Gingko.Repo do
  use Ecto.Repo,
    otp_app: :gingko,
    adapter: Ecto.Adapters.Postgres
end
