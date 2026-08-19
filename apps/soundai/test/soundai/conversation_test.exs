defmodule Soundai.ConversationTest do
  use ExUnit.Case, async: false

  alias Soundai.Conversation
  alias Soundai.Conversation.LLM.FakeAdapter
  alias Soundai.Conversation.Store

  setup do
    previous = Application.get_env(:soundai, Soundai.Conversation)

    Application.put_env(:soundai, Soundai.Conversation,
      adapter: FakeAdapter,
      fake_capture_pid: self()
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:soundai, Soundai.Conversation, previous)
      else
        Application.delete_env(:soundai, Soundai.Conversation)
      end
    end)

    :ok
  end

  describe "submit_transcript/2" do
    test "returns the LLM text (not the echo) and a conversation id" do
      assert {:ok, "Respuesta simulada", id} = Conversation.submit_transcript("¿Qué hora es?")
      assert byte_size(id) > 0
      assert {:ok, _context} = Store.get(id)
    end

    test "starts a conversation with the STT-aware default system prompt" do
      {:ok, _, _id} = Conversation.submit_transcript("Hola")
      assert_received {:fake_llm_called, %{messages: [system | _]}}

      content = Enum.map_join(system.content, "\n", & &1.text)
      assert system.role == :system
      assert content =~ "reconocimiento de voz"
      assert content =~ "partir o unir palabras"
      assert content =~ "frases cortas y sencillas"
    end

    test "honors a configured :system_prompt override" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        system_prompt: "Custom prompt"
      )

      {:ok, _, _id} = Conversation.submit_transcript("Hola")
      assert_received {:fake_llm_called, %{messages: [system | _]}}
      assert Enum.map_join(system.content, "\n", & &1.text) == "Custom prompt"
    end

    test "a second turn with the same id sees the previous assistant turn" do
      {:ok, "Respuesta simulada", id} = Conversation.submit_transcript("Primera pregunta")
      assert_received {:fake_llm_called, %{messages: first_messages}}
      refute Enum.any?(first_messages, &(&1.role == :assistant))

      assert {:ok, "Respuesta simulada", ^id} =
               Conversation.submit_transcript("Segunda pregunta", id)

      assert_received {:fake_llm_called, %{messages: second_messages}}
      assert Enum.any?(second_messages, &(&1.role == :assistant))
    end

    test "nil and unknown ids start a fresh conversation" do
      {:ok, _, id1} = Conversation.submit_transcript("Hola")
      {:ok, _, id2} = Conversation.submit_transcript("Hola de nuevo", "unknown-id")

      assert id1 != id2
      assert_received {:fake_llm_called, %{messages: fresh_messages}}
      refute Enum.any?(fresh_messages, &(&1.role == :user))
    end

    test "caps long responses with a trailing ellipsis" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        max_response_chars: 5
      )

      assert {:ok, "Respu…", _id} = Conversation.submit_transcript("Hola")
    end

    test "rejects blank text" do
      assert Conversation.submit_transcript("   ") == {:error, :empty}
      assert Conversation.submit_transcript("") == {:error, :empty}
    end

    test "rejects oversized text" do
      assert Conversation.submit_transcript(String.duplicate("a", 4001)) == {:error, :too_long}
    end

    test "rejects non-binary input" do
      assert Conversation.submit_transcript(123) == {:error, :invalid}
    end

    test "maps LLM failures to stable reasons" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        fake_error: "Error: some provider failure"
      )

      assert Conversation.submit_transcript("Hola") == {:error, :llm_unavailable}

      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        fake_error: "Timed out waiting for LLM response after 30000ms"
      )

      assert Conversation.submit_transcript("Hola") == {:error, :llm_timeout}
    end
  end

  describe "Soundai.Conversation.Store TTL" do
    test "idle conversations expire and are dropped by sweep/1" do
      {:ok, _response, id} = Conversation.submit_transcript("Hola")
      assert {:ok, _context} = Store.get(id)

      ttl =
        Application.get_env(:soundai, Soundai.Conversation, [])[:store_ttl_ms] ||
          30 * 60 * 1000

      future = System.monotonic_time(:millisecond) + ttl + 1000

      assert is_integer(Store.sweep(future))
      assert Store.get(id) == :error
    end

    test "recent conversations survive a sweep" do
      {:ok, _response, id} = Conversation.submit_transcript("Hola")
      now = System.monotonic_time(:millisecond)

      Store.sweep(now + 1_000)
      assert {:ok, _context} = Store.get(id)
    end

    test "delete/1 removes a conversation" do
      {:ok, _response, id} = Conversation.submit_transcript("Hola")
      assert Store.delete(id) == :ok
      assert Store.get(id) == :error
    end
  end
end
