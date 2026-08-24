# Messages are intentionally communal (there is no authentication in the app
# yet): anyone may save or hear anyone's messages, so skip the
# missing-authorization heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthorization
defmodule Soundai.Messages do
  @max_pending_scan 200

  @moduledoc """
  The family answering machine: short voice messages saved by one person and
  played back later by another.

  Deliberately communal and best-effort — there are no user accounts, names
  are free text extracted from speech, and matching is case- and
  accent-insensitive ("MAMÁ" finds a message addressed to "Mamá"). Rows are
  kept forever; playing stamps `delivered_at` instead of deleting.
  """

  import Ecto.Query, warn: false

  alias Soundai.Messages.Message
  alias Soundai.Repo

  @doc """
  Saves a message (`%{"body" => …, "from_name" => …, "to_name" => …}).

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
  All pending messages, oldest first (the order they were left on the tape).

  ## Options

    * `:from` — only messages left by this name (best-effort match).
    * `:to` — only messages addressed to this name (best-effort match).

  Filter semantics follow answering-machine intuition: an unknown sender
  (NULL) never matches a named `:from` filter — "dime el mensaje de Diego"
  must not read anonymous notes — while a message with no recipient is for
  everyone, so it always passes a `:to` filter and someone asking as "Diego"
  still hears the general notes. A non-binary filter value is treated as a
  named filter that matches nothing, never silently dropped.

  Only the oldest #{@max_pending_scan} pending messages are considered: the
  pending set normally prunes itself when people play their messages, so the
  cap only guards a pathological never-played backlog (the tape overflows
  FIFO-style).
  """
  @spec pending_messages(keyword()) :: [Message.t()]
  def pending_messages(opts \\ []) do
    from_name = opts[:from]
    to_name = opts[:to]

    # No associations exist on Message, so there is nothing to preload.
    query =
      from(m in Message,
        where: is_nil(m.delivered_at),
        order_by: [asc: m.id],
        limit: ^@max_pending_scan
      )

    Enum.filter(Repo.all(query), fn message ->
      from_matches?(message.from_name, from_name) and to_matches?(message.to_name, to_name)
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

  @doc """
  Stamps `delivered_at` on the given messages (the ones that were just played).
  Returns `{count, nil}` like `Repo.update_all/2`.
  """
  @spec mark_delivered([Message.t()]) :: {non_neg_integer(), nil}
  def mark_delivered(messages) do
    ids = Enum.map(messages, & &1.id)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(m in Message, where: m.id in ^ids), set: [delivered_at: now])
  end

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
end
