defmodule Soundpanel.Repo do
  use Ecto.Repo,
    otp_app: :soundpanel,
    adapter: Ecto.Adapters.Postgres
end
