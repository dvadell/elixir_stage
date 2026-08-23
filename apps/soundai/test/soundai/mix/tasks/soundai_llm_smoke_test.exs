defmodule Soundai.LlmSmokeTest do
  # Mutates application env (adapter injection, timeout, provider key).
  use ExUnit.Case, async: false

  alias Mix.Tasks.Soundai.LlmSmoke
  alias Soundai.Conversation.LLM.FakeAdapter

  defp secret, do: "nvapi-SUPER-SECRET-KEY"

  describe "sanitize_error/2" do
    test "drops HTTP plumbing and redacts the secret from error maps" do
      reason = %{
        status: 502,
        message: "request failed",
        headers: [{"authorization", "Bearer #{secret()}"}],
        request: %{url: "https://integrate.api.nvidia.com/v1/chat/completions"}
      }

      output = LlmSmoke.sanitize_error(reason, secret())

      refute output =~ secret()
      refute output =~ "authorization"
      refute output =~ "integrate.api.nvidia.com"
      assert output =~ "502"
      assert output =~ "request failed"
    end

    test "redacts keyword-list shaped errors with binary header keys" do
      reason = [
        {:headers, [{"x-api-key", secret()}]},
        {:status, 504}
      ]

      output = LlmSmoke.sanitize_error(reason, secret())

      refute output =~ secret()
      assert output =~ "504"
    end

    test "renders exceptions as class plus redacted message" do
      exception = %RuntimeError{message: "call failed after Bearer #{secret()}"}

      output = LlmSmoke.sanitize_error(exception, secret())

      # Any string containing the secret is redacted wholesale.
      assert output == "RuntimeError: [redacted]"
    end

    test "keeps harmless content intact" do
      assert LlmSmoke.sanitize_error("connection refused", secret()) == "connection refused"
      assert LlmSmoke.sanitize_error(:econnrefused, secret()) == ":econnrefused"
    end

    test "scrubs bearer tokens embedded in strings even when the key is unknown" do
      reason =
        "Stream failed: %{request: %Req.Request{headers: [{\"authorization\", \"Bearer #{secret()}\"}]}}"

      output = LlmSmoke.sanitize_error(reason, "some-other-unrelated-key")

      refute output =~ secret()
      assert output =~ "[redacted]"

      # Ordinary prose is not over-redacted.
      assert LlmSmoke.sanitize_error("Bearer of good news", "") == "Bearer of good news"
    end

    test "falls back to the configured API key when no secret is given" do
      providers = Application.get_env(:branched_llm, :providers)

      Application.put_env(:branched_llm, :providers,
        openai: [api_key: {:system, "LLM_SMOKE_TEST_KEY"}]
      )

      System.put_env("LLM_SMOKE_TEST_KEY", secret())

      try do
        output = LlmSmoke.sanitize_error("Bearer #{secret()} exploded")
        refute output =~ secret()
        assert output == "[redacted]"
      after
        System.delete_env("LLM_SMOKE_TEST_KEY")

        if providers do
          Application.put_env(:branched_llm, :providers, providers)
        else
          Application.delete_env(:branched_llm, :providers)
        end
      end
    end

    test "does not recurse when the configured key is unset" do
      # {:system, var} with the var missing — api_key/0 returns nil. This must
      # degrade to "no known secret", never loop forever.
      providers = Application.get_env(:branched_llm, :providers)

      Application.put_env(:branched_llm, :providers,
        openai: [api_key: {:system, "LLM_SMOKE_MISSING_KEY"}]
      )

      System.delete_env("LLM_SMOKE_MISSING_KEY")

      try do
        output = LlmSmoke.sanitize_error("Bearer #{secret()} exploded")

        refute output =~ secret()
        assert output =~ "[redacted]"
      after
        if providers do
          Application.put_env(:branched_llm, :providers, providers)
        else
          Application.delete_env(:branched_llm, :providers)
        end
      end
    end

    test "does not recurse when no provider key is configured at all" do
      providers = Application.get_env(:branched_llm, :providers)
      Application.delete_env(:branched_llm, :providers)

      try do
        assert LlmSmoke.sanitize_error("connection refused") == "connection refused"

        reason = %{headers: [{"authorization", "Bearer #{secret()}"}], status: 401}
        output = LlmSmoke.sanitize_error(reason)

        refute output =~ secret()
        assert output =~ "401"
      after
        if providers do
          Application.put_env(:branched_llm, :providers, providers)
        else
          Application.delete_env(:branched_llm, :providers)
        end
      end
    end
  end

  describe "run/1" do
    test "sends the prompt through the adapter bounded by llm_timeout_ms" do
      previous_task_env = Application.get_env(:soundai, LlmSmoke)
      previous_conversation = Application.get_env(:soundai, Soundai.Conversation)

      # One config key drives both sides: the task reads :llm_timeout_ms from
      # it, while FakeAdapter (the injected :adapter) reports back through
      # :fake_capture_pid.
      conversation =
        (previous_conversation || [])
        |> Keyword.merge(
          adapter: FakeAdapter,
          fake_capture_pid: self(),
          llm_timeout_ms: 1_234
        )

      Application.put_env(:soundai, LlmSmoke, adapter: FakeAdapter)
      Application.put_env(:soundai, Soundai.Conversation, conversation)

      try do
        LlmSmoke.run([])
        assert_received {:fake_llm_opts, opts}
        assert Keyword.get(opts, :timeout) == 1_234
      after
        restore(previous_task_env, previous_conversation)
      end
    end
  end

  defp restore(task_env, conversation) do
    if task_env do
      Application.put_env(:soundai, LlmSmoke, task_env)
    else
      Application.delete_env(:soundai, LlmSmoke)
    end

    if conversation do
      Application.put_env(:soundai, Soundai.Conversation, conversation)
    else
      Application.delete_env(:soundai, Soundai.Conversation)
    end
  end
end
