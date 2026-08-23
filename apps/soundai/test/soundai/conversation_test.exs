defmodule Soundai.ConversationTest do
  # async: false: the fake LLM adapter is configured through application env,
  # shared by every test in the module.
  use Soundai.DataCase, async: false

  alias Soundai.Conversation
  alias Soundai.Conversation.LLM.FakeAdapter
  alias Soundai.Conversation.Store
  alias Soundai.Conversation.Tools.Weather
  alias Soundai.Notes

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

  describe "submit_transcript/3" do
    test "returns the LLM text (not the echo) and a conversation id" do
      assert {:ok, "Respuesta simulada", id} = Conversation.submit_transcript("¿Qué hora es?")
      assert byte_size(id) > 0
      assert {:ok, _context} = Store.get(id)
    end

    test "starts a conversation with the STT-aware default system prompt" do
      {:ok, _, _id} = Conversation.submit_transcript("Hola")
      assert_received {:fake_llm_called, %{messages: [system | _]}}

      content = system_content(system)
      assert system.role == :system
      assert content =~ "reconocimiento de voz"
      assert content =~ "partir o unir palabras"
      assert content =~ "frases cortas y sencillas"
    end

    test "keeps the system prompt static (no dynamic context in it)" do
      meta = %{
        date: "2026-08-22",
        time: "14:35:07",
        timezone: "Europe/Madrid",
        latitude: 40.4168,
        longitude: -3.7038
      }

      {:ok, _, _id} = Conversation.submit_transcript("Hola", nil, meta)
      content = system_content()

      refute content =~ "Fecha y hora actual"
      refute content =~ "Ubicación aproximada"
    end

    test "prepends the browser date and time to the last message" do
      meta = %{date: "2026-08-22", time: "14:35:07", timezone: "Europe/Madrid"}
      {:ok, _, _id} = Conversation.submit_transcript("¿Qué hora es?", nil, meta)

      message = last_message()

      assert message =~
               ~S{[Fecha y hora actual: sábado 22 de agosto de 2026, 14:35 (Europe/Madrid).]}

      assert String.ends_with?(message, "\n\n¿Qué hora es?")
    end

    test "ignores malformed browser date/time and sends the bare transcript" do
      bad_meta = %{date: "22/08/2026", time: "25:99:00", timezone: 42}
      {:ok, _, _id} = Conversation.submit_transcript("Hola", nil, bad_meta)

      assert last_message() == "Hola"
    end

    test "relays the browser geolocation in the last message" do
      meta = %{latitude: 40.4168, longitude: -3.7038, date: "2026-08-22", time: "09:00:00"}
      {:ok, _, _id} = Conversation.submit_transcript("Hola", nil, meta)

      message = last_message()
      assert message =~ "Ubicación aproximada del usuario: latitud 40,4168, longitud -3,7038"
      assert message =~ "coordenadas GPS"
    end

    test "omits the location block without geolocation" do
      {:ok, _, _id} = Conversation.submit_transcript("Hola")
      refute last_message() =~ "Ubicación aproximada"
    end

    test "ignores out-of-range coordinates" do
      {:ok, _, _id} =
        Conversation.submit_transcript("Hola", nil, %{latitude: 120.0, longitude: 999.0})

      refute last_message() =~ "Ubicación aproximada"
    end

    test "the dynamic context never leaks into the stored context" do
      {:ok, _, id} =
        Conversation.submit_transcript("Hola", nil, %{
          date: "2026-08-22",
          time: "14:35:07",
          latitude: 40.4168,
          longitude: -3.7038
        })

      # The stored conversation keeps only the configured system prompt.
      assert {:ok, context} = Store.get(id)
      [persisted_system | _] = ReqLLM.Context.to_list(context)
      refute system_content(persisted_system) =~ "Fecha y hora actual"

      # And the next turn's system prompt is byte-for-byte the same.
      {:ok, _, ^id} = Conversation.submit_transcript("Segunda pregunta", id)
      assert_received {:fake_llm_called, %{messages: [first_system | _]}}
      first_system_content = system_content(first_system)
      assert system_content() == first_system_content
    end

    test "honors a configured :system_prompt override" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        system_prompt: "Custom prompt"
      )

      {:ok, _, _id} = Conversation.submit_transcript("Hola")
      assert_received {:fake_llm_called, %{messages: [system | _]}}
      assert system_content(system) == "Custom prompt"
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

    test "caps long responses with a closing note" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        max_response_chars: 5
      )

      note =
        "Hay más para hablar de este tema, pero el texto se volvió muy largo. Me detendré acá"

      assert {:ok, "Respu " <> ^note, _id} = Conversation.submit_transcript("Hola")
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

  describe "saved notes in the last message" do
    test "includes the saved note text in the last message" do
      {:ok, _} = Notes.save_note(%{"content" => "la leche está en la nevera"})

      assert {:ok, _, _} = Conversation.submit_transcript("¿Qué notas tengo?")

      message = last_message()

      assert message =~ "[Notas del usuario:\nla leche está en la nevera]"

      assert String.ends_with?(message, "\n\n¿Qué notas tengo?")
    end

    test "includes the note verbatim, preserving line breaks, however big it is" do
      # The changeset trims surrounding whitespace, so no trailing newline.
      note =
        String.duplicate("línea de la nota\n", 400)
        |> String.trim_trailing()

      {:ok, _} = Notes.save_note(%{"content" => note})

      assert {:ok, _, _} = Conversation.submit_transcript("Hola")

      message = last_message()

      assert message =~
               "[Notas del usuario:\n#{note}]"

      assert String.ends_with?(message, "\n\nHola")
    end

    test "reflects the latest edit on every turn" do
      {:ok, _} = Notes.save_note(%{"content" => "versión inicial"})
      {:ok, _, id} = Conversation.submit_transcript("Hola")
      assert_received {:fake_llm_text, _first_turn}

      {:ok, _} = Notes.save_note(%{"content" => "versión reescrita"})
      {:ok, _, ^id} = Conversation.submit_transcript("Segunda pregunta", id)

      second_message = last_message()
      assert second_message =~ "[Notas del usuario:\nversión reescrita]"
      refute second_message =~ "versión inicial"
    end

    test "the dynamic notes never leak into the stored context" do
      {:ok, _} = Notes.save_note(%{"content" => "nota persistente"})
      {:ok, _, id} = Conversation.submit_transcript("Hola")

      assert {:ok, context} = Store.get(id)
      [persisted_system | _] = ReqLLM.Context.to_list(context)
      refute system_content(persisted_system) =~ "nota persistente"

      # A second turn re-reads the notes; they ride in that message only.
      {:ok, _, ^id} = Conversation.submit_transcript("Segunda pregunta", id)
      assert_received {:fake_llm_text, _first_turn}
      second_message = last_message()
      assert second_message =~ "nota persistente"
      assert String.ends_with?(second_message, "\n\nSegunda pregunta")
    end
  end

  describe "LLM tools" do
    test "offers the weather tool to the LLM by default" do
      assert {:ok, _, _} = Conversation.submit_transcript("¿Qué tiempo hace?")

      assert_received {:fake_llm_opts, opts}
      assert [%ReqLLM.Tool{name: "get_weather"}] = opts[:tools]
    end

    test "honors a configured :llm_tools override" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        llm_tools: [Weather]
      )

      assert {:ok, _, _} = Conversation.submit_transcript("Hola")

      assert_received {:fake_llm_opts, opts}
      assert opts[:tools] == [Weather.tool()]
    end

    test "an empty :llm_tools list disables tools" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        llm_tools: []
      )

      assert {:ok, _, _} = Conversation.submit_transcript("Hola")

      assert_received {:fake_llm_opts, opts}
      assert opts[:tools] == []
    end
  end

  describe "speech cleaning of the LLM response" do
    test "strips Markdown decoration and emoji before returning the reply" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        fake_response: "**Hola** \u{1F60A}\n\n- punto uno\n- punto dos"
      )

      assert {:ok, "Hola punto uno punto dos", _id} = Conversation.submit_transcript("Hola")
    end

    test "logs the raw LLM response" do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        fake_response: "**Hola**"
      )

      import ExUnit.CaptureLog

      previous_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          Conversation.submit_transcript("Hola")
        end)

      Logger.configure(level: previous_level)

      assert log =~ "LLM response for conversation="
      assert log =~ "**Hola**"
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

  defp last_message do
    assert_received {:fake_llm_text, text}
    text
  end

  defp system_content do
    assert_received {:fake_llm_called, %{messages: [system | _]}}
    system_content(system)
  end

  defp system_content(system) do
    Enum.map_join(system.content, "\n", & &1.text)
  end
end
