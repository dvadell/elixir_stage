# Messages are intentionally communal (there is no authentication in the app
# yet): anyone may save or hear anyone's messages, so skip the
# missing-authorization heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthorization
defmodule Soundai.Messages do
  @default_max_messages 5
  @default_retention_days 30

  @moduledoc """
  The family answering machine: short voice messages saved by one person and
  played back later by another.

  Deliberately communal and best-effort — there are no user accounts, names
  are free text extracted from speech, and matching is case- and
  accent-insensitive ("MAMÁ" finds a message addressed to "Mamá").

  Playback works like a 90s contestador: asking reads out the **last
  `:max_messages`** messages that are **not older than
  `:message_retention_days`**, oldest first among those selected. Nothing is
  ever deleted or marked as delivered — rows stay forever and visibility
  depends only on insertion age, so a message is always available again on
  the next ask until it ages out of the retention window.

  Configuration under `config :soundai, Soundai.Messages`:

    * `:max_messages` — how many of the most recent messages to return
      (default #{@default_max_messages}).
    * `:message_retention_days` — how many days a message stays visible
      (default #{@default_retention_days}).
  """

  import Ecto.Query, warn: false

  alias Soundai.Messages.Message
  alias Soundai.Repo

  @doc """
  Saves a message (`%{"body" => …, "from_name" => …, "to_name" => …}`).

  ## Returns

    * `{:ok, message}` — the persisted message.
    * `{:error, %Ecto.Changeset{}}` — validation failure (blank/oversized).
  """
  def save_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The last `:max_messages` messages within the `:message_retention_days`
  window, ordered as they were left on the tape (oldest first).

  ## Options

    * `:from` — only messages left by this name (best-effort match).
    * `:to` — only messages addressed to this name (best-effort match).
    * `:max_messages` / `:retention_days` — per-call overrides of the
      configured values.

  Filter semantics follow answering-machine intuition: an unknown sender
  (NULL) never matches a named `:from` filter — "dime el mensaje de Diego"
  must not read anonymous notes — while a message with no recipient is for
  everyone, so it always passes a `:to` filter and someone asking as "Diego"
  still hears the general notes. A non-binary filter value is treated as a
  named filter that matches nothing, never silently dropped.
  """
  @spec pending_messages(keyword()) :: [Message.t()]
  def pending_messages(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days(opts), :day)

    # Newest first with an id tiebreaker (same-second inserts), limited to
    # the configured maximum, then reversed to speak them chronologically.
    # Plain call, not a pipe into Repo.all: OeditusCredo's MissingPreload
    # heuristic flags the pipe (there are no associations to preload).
    selected =
      Repo.all(
        from(m in Message,
          where: m.inserted_at > ^cutoff,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^max_messages(opts)
        )
      )
      |> Enum.reverse()

    matching(selected, opts)
  end

  # Best-effort name matching over a fetched batch (see the filter semantics
  # in the `pending_messages/1` doc).
  defp matching(messages, opts) do
    Enum.filter(messages, fn message ->
      from_matches?(message.from_name, opts[:from]) and
        to_matches?(message.to_name, opts[:to])
    end)
  end

  # No `:from` filter passes everything; a named one requires an equal sender.
  # Anything non-binary counts as a named filter that matches nothing — it must
  # never degrade into "no filter" (that would read out everyone's messages).
  defp from_matches?(_stored, nil), do: true

  defp from_matches?(stored, filter) when is_binary(stored) and is_binary(filter),
    do: normalize(stored) == normalize(filter)

  defp from_matches?(_, _), do: false

  # No `:to` filter passes everything; with a named one, a message with no
  # recipient at all still passes (it is for everyone).
  defp to_matches?(_stored, nil), do: true

  defp to_matches?(nil, _filter), do: true

  defp to_matches?(stored, filter) when is_binary(stored) and is_binary(filter),
    do: normalize(stored) == normalize(filter)

  defp to_matches?(_, _), do: false

  # Downcase + strip diacritics + collapse whitespace so spoken-name variants
  # still match. Only ever called with binaries (the matches predicates gate
  # on is_binary before comparing).
  defp normalize(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
    |> String.replace(~r/\s+/u, " ")
  end

  # ------------------------------------------------------- configuration

  defp max_messages(opts) do
    opts[:max_messages] || configured(:max_messages) || @default_max_messages
  end

  defp retention_days(opts) do
    opts[:retention_days] || configured(:message_retention_days) || @default_retention_days
  end

  defp configured(key) do
    :soundai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end
end
