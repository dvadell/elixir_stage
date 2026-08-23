defmodule Mix.Tasks.Soundai.LlmSmoke do
  use Mix.Task

  @shortdoc "Smoke-tests the LLM integration (live network, not part of the suite)"

  @moduledoc """
  Smoke-tests the branched_llm integration against the configured provider.

  Builds a context, sends a Spanish prompt through the LLM adapter
  (`Soundai.Conversation.LLM` → `BranchedLLM.Chat.send_message/3`, bounded by
  `llm_timeout_ms`), and prints the response. This performs a **live network
  request** and is intentionally excluded from the test suite — run it manually:

      mix soundai.llm_smoke

  The model used is the configured `:branched_llm, :ai_model` (default
  `openai:openai/gpt-oss-20b` on the NVIDIA endpoint). Requires `NVIDIA_API_KEY`
  to be set.

  Errors are printed redacted: HTTP plumbing (headers, request details) is
  dropped and every occurrence of the configured API key is replaced with
  "[redacted]" (see `sanitize_error/2`), so the provider key can never leak to
  the console or logs.
  """

  @redacted "[redacted]"
  @sensitive_atom_keys [:headers, :req_headers, :resp_headers, :request, :authorization, :api_key]
  @sensitive_binary_keys ["authorization", "proxy-authorization", "api-key", "x-api-key"]

  # "Bearer <token>" (and similar schemes) in arbitrary strings — token
  # characters only, so prose like "Bearer of good news" is left alone.
  @bearer_token_regex Regex.compile!(
                        "\\b(bearer|basic|token)\\s+[a-z0-9][a-z0-9._~+/-]{8,}=*",
                        "i"
                      )

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    model = Application.get_env(:branched_llm, :ai_model, "openai:openai/gpt-oss-20b")
    IO.puts("Using model: #{model} (timeout: #{llm_timeout_ms()} ms)")

    context = BranchedLLM.Chat.new_context("You are a helpful assistant.")

    case adapter().call(
           "¿Cómo funciona el sistema solar? Responde brevemente en español.",
           context,
           timeout: llm_timeout_ms()
         ) do
      {:ok, response, _new_context} ->
        IO.puts("\n=== LLM response ===")
        IO.puts(response)

      {:error, reason} ->
        IO.puts("\n=== LLM error ===")
        IO.puts(sanitize_error(reason))
        System.halt(1)
    end
  end

  # -- redaction ---------------------------------------------------------------

  # Header lists use lowercase binary keys; keyword-ish structures use atoms.
  defguard sensitive_key(key)
           when (is_atom(key) and key in @sensitive_atom_keys) or
                  (is_binary(key) and key in @sensitive_binary_keys)

  @doc """
  Redacts credentials from an LLM error before it is printed.

  Purely functional so the suite can unit-test it. Drops HTTP plumbing entries
  (`:headers`, `:request`, authorization keys) from maps/lists, replaces any
  string containing `secret` with "[redacted]", and renders exceptions as
  `"Module: message"`. When `secret` is omitted, the configured API key
  (`:branched_llm, :providers` — literal or `{:system, var}`) is used; when no
  key is configured, only the bearer-token scrub applies (never recursing).
  """
  def sanitize_error(reason, secret \\ nil)

  # The sentinel is resolved exactly once: an absent/unset key becomes ""
  # ("no known secret") instead of re-entering this clause. A missing key is
  # itself one of the failures this path must report.
  def sanitize_error(reason, nil), do: sanitize_error(reason, api_key() || "")

  def sanitize_error(reason, secret) when is_binary(secret) do
    cond do
      is_exception(reason) -> exception_line(reason, secret)
      is_binary(reason) -> redact(reason, secret)
      true -> inspect(redact(reason, secret), pretty: true, limit: 40)
    end
  end

  defp exception_line(exception, secret) do
    "#{inspect(exception.__struct__)}: #{redact(Exception.message(exception), secret)}"
  end

  defp redact(term, secret)

  defp redact(term, secret) when is_binary(term) do
    if byte_size(secret) > 0 and String.contains?(term, secret) do
      @redacted
    else
      # Defense-in-depth: even when the configured key is unknown (e.g. an
      # unresolved {:system, var}), never echo bearer tokens embedded in
      # inspected request dumps.
      String.replace(term, @bearer_token_regex, "[redacted]")
    end
  end

  # Structs keep their module name (as __struct__) so exception/error classes
  # stay visible in the printed output; their fields are redacted like maps.
  defp redact(%module{} = struct, secret) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, module)
    |> redact_map(secret)
  end

  defp redact(map, secret) when is_map(map), do: redact_map(map, secret)

  defp redact(list, secret) when is_list(list) do
    Enum.map(list, fn
      {key, _value} = pair when sensitive_key(key) -> put_elem(pair, 1, @redacted)
      element -> redact(element, secret)
    end)
  end

  defp redact(tuple, secret) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&redact(&1, secret))
    |> List.to_tuple()
  end

  defp redact(term, _secret), do: term

  defp redact_map(map, secret) do
    Enum.reduce(map, %{}, fn
      {key, _value}, acc when sensitive_key(key) ->
        Map.put(acc, key, @redacted)

      {key, value}, acc ->
        Map.put(acc, key, redact(value, secret))
    end)
  end

  # -- configuration -----------------------------------------------------------

  defp adapter do
    :soundai
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, Soundai.Conversation.LLM)
  end

  defp llm_timeout_ms do
    :soundai
    |> Application.get_env(Soundai.Conversation, [])
    |> Keyword.get(:llm_timeout_ms, 30_000)
  end

  defp api_key do
    providers = Application.get_env(:branched_llm, :providers, [])
    openai = Keyword.get(providers, :openai, [])
    key = Keyword.get(openai, :api_key)

    cond do
      is_binary(key) -> key
      match?({:system, var} when is_binary(var), key) -> key |> elem(1) |> System.get_env()
      true -> nil
    end
  end
end
