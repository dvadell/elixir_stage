defmodule Mix.Tasks.Soundai.LlmSmoke do
  use Mix.Task

  @shortdoc "Smoke-tests the LLM integration (live network, not part of the suite)"

  @moduledoc """
  Smoke-tests the branched_llm integration against the configured provider.

  Builds a context, sends a Spanish prompt through `BranchedLLM.Chat.send_message/3`,
  and prints the response. This performs a **live network request** and is
  intentionally excluded from the test suite — run it manually:

      mix soundai.llm_smoke

  The model used is the configured `:branched_llm, :ai_model` (default
  `openai:openai/gpt-oss-20b` on the NVIDIA endpoint). Requires `NVIDIA_API_KEY`
  to be set.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    model = Application.get_env(:branched_llm, :ai_model, "openai:openai/gpt-oss-20b")
    IO.puts("Using model: #{model}")

    context = BranchedLLM.Chat.new_context("You are a helpful assistant.")

    case BranchedLLM.Chat.send_message(
           "¿Cómo funciona el sistema solar? Responde brevemente en español.",
           context
         ) do
      {:ok, response, _new_context} ->
        IO.puts("\n=== LLM response ===")
        IO.puts(response)

      {:error, reason} ->
        IO.puts("\n=== LLM error ===")
        IO.puts(inspect(reason))
        System.halt(1)
    end
  end
end
