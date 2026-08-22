defmodule SoundaiWeb.ConversationAudioControllerTest do
  use SoundaiWeb.ConnCase, async: false

  alias Soundai.Conversation
  alias Soundai.Conversation.LLM.FakeAdapter, as: LLMFakeAdapter
  alias Soundai.Conversation.Store
  alias Soundai.TTS.FakeAdapter, as: TTSFakeAdapter
  alias Soundai.TTS.OrtexServer

  setup do
    previous_llm = Application.get_env(:soundai, Soundai.Conversation)
    previous_tts = Application.get_env(:soundai, Soundai.TTS)

    Application.put_env(:soundai, Soundai.Conversation,
      adapter: LLMFakeAdapter,
      fake_capture_pid: self()
    )

    Application.put_env(:soundai, Soundai.TTS, adapter: TTSFakeAdapter)

    on_exit(fn ->
      restore_env(:soundai, Soundai.Conversation, previous_llm)
      restore_env(:soundai, Soundai.TTS, previous_tts)
    end)

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, previous), do: Application.put_env(app, key, previous)

  defp post_json(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/conversations/audio", Jason.encode!(params))
  end

  describe "POST /api/conversations/audio" do
    test "returns WAV bytes with conversation headers and cookie", %{conn: conn} do
      conn = post_json(conn, %{"text" => "¿Qué tiempo hace?", "language" => "spanish"})

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["audio/wav"]
      assert get_resp_header(conn, "x-tts-model") == ["Xenova/mms-tts-spa"]
      assert get_resp_header(conn, "x-tts-duration-ms") == ["1"]
      assert conn.resp_body == TTSFakeAdapter.wav()

      assert [x_conv] = get_resp_header(conn, "x-conversation-id")
      assert byte_size(x_conv) > 0

      assert [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "soundai_conversation=#{x_conv}"
    end

    test "shares context with the text endpoint via the same conversation cookie" do
      {:ok, _text, id} = Conversation.submit_transcript("Primera pregunta")
      assert_received {:fake_llm_called, %{messages: first_messages}}
      refute Enum.any?(first_messages, &(&1.role == :assistant))

      conn =
        build_conn()
        |> put_req_cookie("soundai_conversation", id)
        |> post_json(%{"text" => "Segunda pregunta"})

      assert conn.status == 200

      assert [x_conv] = get_resp_header(conn, "x-conversation-id")
      assert x_conv == id

      assert_received {:fake_llm_called, %{messages: second_messages}}
      assert Enum.any?(second_messages, &(&1.role == :assistant))
    end

    test "reset: true deletes the stored context and returns a fresh id" do
      {:ok, _text, old_id} = Conversation.submit_transcript("Primera pregunta")
      assert {:ok, _context} = Store.get(old_id)

      conn =
        build_conn()
        |> put_req_cookie("soundai_conversation", old_id)
        |> post_json(%{"text" => "Pregunta nueva", "reset" => true})

      assert conn.status == 200
      assert [new_id] = get_resp_header(conn, "x-conversation-id")
      refute new_id == old_id
      assert Store.get(old_id) == :error

      assert [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "soundai_conversation=#{new_id}"
    end

    test "relays browser date/time and geolocation inside the last message", %{conn: conn} do
      conn =
        post_json(conn, %{
          "text" => "¿Qué tiempo hace aquí?",
          "date" => "2026-08-22",
          "time" => "14:35:07",
          "latitude" => 40.4168,
          "longitude" => -3.7038
        })

      assert conn.status == 200

      assert_received {:fake_llm_text, message}
      assert message =~ "Fecha y hora actual: sábado 22 de agosto de 2026, 14:35"
      assert message =~ "latitud 40,4168, longitud -3,7038"
    end

    test "returns 503 with the LLM text when the TTS model is absent", %{conn: conn} do
      Application.put_env(:soundai, Soundai.TTS, adapter: OrtexServer)

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 503
      assert %{"errors" => %{"text" => "server TTS is not ready"}} = json_response(conn, 503)
      assert %{"response" => "Respuesta simulada"} = json_response(conn, 503)
    end

    test "rejects missing text", %{conn: conn} do
      conn = post_json(conn, %{})

      assert conn.status == 422
      assert %{"errors" => %{"text" => "is required"}} = json_response(conn, 422)
    end

    test "rejects blank text", %{conn: conn} do
      conn = post_json(conn, %{"text" => "   "})

      assert conn.status == 422
      assert %{"errors" => %{"text" => "can't be blank"}} = json_response(conn, 422)
    end

    test "rejects oversized text", %{conn: conn} do
      conn = post_json(conn, %{"text" => String.duplicate("a", 4001)})

      assert conn.status == 422
      assert %{"errors" => %{"text" => "is too long"}} = json_response(conn, 422)
    end

    test "maps LLM unavailability to a 502 JSON error", %{conn: conn} do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: LLMFakeAdapter,
        fake_capture_pid: self(),
        fake_error: "Error: provider down"
      )

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 502
      assert %{"errors" => %{"text" => "LLM is unavailable"}} = json_response(conn, 502)
    end

    test "maps LLM timeout to a 504 JSON error", %{conn: conn} do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: LLMFakeAdapter,
        fake_capture_pid: self(),
        fake_error: "Timed out waiting for LLM response after 30000ms"
      )

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 504
      assert %{"errors" => %{"text" => "LLM timed out"}} = json_response(conn, 504)
    end
  end
end
