defmodule Soundai.Conversation.Store do
  @moduledoc """
  In-memory store for per-conversation LLM contexts.

  Entries are keyed by an opaque `conversation_id` and carry an idle timestamp.
  Conversations idle longer than `ttl` are dropped (on access and via `sweep/1`),
  so memory stays bounded. The store is a `GenServer` owned by
  `Soundai.Application`; all state lives in the owning process.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @default_ttl_ms 30 * 60 * 1000

  def start_link(opts \\ []) do
    # credo:disable-for-next-line Credo.Check.Extra.NoUnsupervisedProcesses
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Returns a fresh conversation id together with a new context built from
  `prompt`.
  """
  def new(prompt) when is_binary(prompt) do
    GenServer.call(@name, {:new, prompt})
  end

  @doc """
  Returns the live conversation for `conversation_id` or starts a new one.

  A `nil`/unknown/expired id yields a fresh id and context (from `prompt`).
  """
  def get_or_new(nil, prompt), do: new(prompt)

  def get_or_new(conversation_id, prompt) when is_binary(conversation_id) do
    case get(conversation_id) do
      {:ok, context} -> {conversation_id, context}
      :error -> new(prompt)
    end
  end

  def get_or_new(_conversation_id, prompt), do: new(prompt)

  @doc "Returns `{:ok, context}` for a live conversation, or `:error`."
  def get(conversation_id) when is_binary(conversation_id) do
    GenServer.call(@name, {:get, conversation_id})
  end

  def get(_conversation_id), do: :error

  @doc "Persists the conversation's context and refreshes its idle timestamp."
  def put(conversation_id, context) when is_binary(conversation_id) do
    GenServer.call(@name, {:put, conversation_id, context})
  end

  @doc "Deletes a conversation."
  def delete(conversation_id) when is_binary(conversation_id) do
    GenServer.call(@name, {:delete, conversation_id})
  end

  @doc "Drops conversations idle longer than the TTL. Returns the number removed."
  def sweep(now \\ now_ms()) do
    GenServer.call(@name, {:sweep, now})
  end

  @impl true
  def init(opts) do
    ttl =
      Keyword.get(opts, :ttl_ms) ||
        Application.get_env(:soundai, Soundai.Conversation, [])[:store_ttl_ms] ||
        @default_ttl_ms

    {:ok, %{entries: %{}, ttl: ttl}}
  end

  @impl true
  def handle_call({:new, prompt}, _from, state) do
    id = generate_id()
    context = BranchedLLM.Chat.new_context(prompt)
    {:reply, {id, context}, state}
  end

  def handle_call({:get, id}, _from, %{entries: entries, ttl: ttl} = state) do
    now = now_ms()

    case entries[id] do
      %{context: context, last_access: last} when now - last <= ttl ->
        {:reply, {:ok, context}, put_entry(state, id, context, now)}

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:put, id, context}, _from, state) do
    {:reply, :ok, put_entry(state, id, context, now_ms())}
  end

  def handle_call({:delete, id}, _from, state) do
    {:reply, :ok, %{state | entries: Map.delete(state.entries, id)}}
  end

  def handle_call({:sweep, now}, _from, %{entries: entries, ttl: ttl} = state) do
    {entries, removed} =
      Enum.reduce(entries, {entries, 0}, fn {id, %{last_access: last}}, {acc, count} ->
        if now - last > ttl do
          {Map.delete(acc, id), count + 1}
        else
          {acc, count}
        end
      end)

    if removed > 0 do
      Logger.debug(
        "Conversation store swept #{removed} expired conversation(s); " <>
          "#{map_size(entries)} remaining"
      )
    end

    {:reply, removed, %{state | entries: entries}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp put_entry(state, id, context, now) do
    update_in(
      state,
      [Access.key(:entries)],
      &Map.put(&1, id, %{context: context, last_access: now})
    )
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
