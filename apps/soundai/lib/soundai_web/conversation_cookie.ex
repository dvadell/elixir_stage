defmodule SoundaiWeb.ConversationCookie do
  @moduledoc """
  Shared definition of the `soundai_conversation` cookie set by the
  conversation endpoints (`POST /api/transcriptions` and
  `POST /api/conversations/audio`). It carries only an opaque conversation id.

  Flags:

    * `http_only: true` — never readable by JavaScript.
    * `secure: true` on HTTPS deployments — derived from the endpoint's
      configured URL scheme (production sets `scheme: "https"` in
      `config/runtime.exs`, including behind an SSL-terminating proxy, where
      Plug's own connection-scheme check would not fire). Plain-http dev/test
      keeps working without the flag.
    * `same_site: "Lax"`, one-week `max_age`, site-wide path.

  Because the cookie is HttpOnly, clients cannot clear it to start a fresh
  conversation; they send `reset: true` in the body instead (the server
  deletes the stored context and replaces the cookie).
  """

  @name "soundai_conversation"
  @max_age 60 * 60 * 24 * 7

  def name, do: @name

  @doc "Attaches the conversation cookie with the hardened flags."
  def put(conn, value) do
    Plug.Conn.put_resp_cookie(conn, @name, value, opts())
  end

  def opts do
    [
      max_age: @max_age,
      path: "/",
      same_site: "Lax",
      http_only: true,
      secure: secure_deployment?()
    ]
  end

  defp secure_deployment? do
    :soundai
    |> Application.get_env(SoundaiWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:scheme, "http") == "https"
  end
end
