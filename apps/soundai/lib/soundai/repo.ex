defmodule Soundai.Repo do
  use Ecto.Repo,
    otp_app: :soundai,
    adapter: Ecto.Adapters.Postgres
end
