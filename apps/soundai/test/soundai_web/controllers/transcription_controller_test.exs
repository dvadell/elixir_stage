defmodule SoundaiWeb.TranscriptionControllerTest do
  use SoundaiWeb.ConnCase, async: false

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

  defp post_json(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/transcriptions", Jason.encode!(params))
  end

  describe "POST /api/transcriptions" do
    test "returns the LLM response with a conversation id and cookie", %{conn: conn} do
      conn =
        post_json(conn, %{
          "text" => "¿Qué tiempo hace mañana?",
          "language" => "spanish"
        })

      assert conn.status == 201

      assert %{
               "ok" => true,
               "response" => "Respuesta simulada",
               "conversation_id" => id,
               "language" => "spanish"
             } = json_response(conn, 201)

      assert byte_size(id) > 0

      assert [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "soundai_conversation=#{id}"
    end

    test "reuses the conversation context from the cookie on a second turn", %{conn: conn} do
      conn = post_json(conn, %{"text" => "Primera pregunta"})
      id = json_response(conn, 201)["conversation_id"]
      assert_received {:fake_llm_called, %{messages: first_messages}}
      refute Enum.any?(first_messages, &(&1.role == :assistant))

      conn =
        build_conn()
        |> put_req_cookie("soundai_conversation", id)
        |> post_json(%{"text" => "Segunda pregunta"})

      assert conn.status == 201
      assert %{"conversation_id" => ^id} = json_response(conn, 201)
      assert_received {:fake_llm_called, %{messages: second_messages}}
      assert Enum.any?(second_messages, &(&1.role == :assistant))
    end

    test "body conversation_id takes precedence over the cookie", %{conn: conn} do
      conn = post_json(conn, %{"text" => "Primera pregunta"})
      cookie_id = json_response(conn, 201)["conversation_id"]

      conn =
        build_conn()
        |> put_req_cookie("soundai_conversation", cookie_id)
        |> post_json(%{"text" => "Otra pregunta", "conversation_id" => "unknown-body-id"})

      assert %{"conversation_id" => returned_id} = json_response(conn, 201)
      refute returned_id == cookie_id
    end

    test "reset: true deletes the stored context and returns a fresh id", %{conn: conn} do
      conn = post_json(conn, %{"text" => "Primera pregunta"})
      old_id = json_response(conn, 201)["conversation_id"]
      assert {:ok, _context} = Store.get(old_id)

      conn =
        build_conn()
        |> put_req_cookie("soundai_conversation", old_id)
        |> post_json(%{"text" => "Pregunta nueva", "reset" => true})

      assert %{"conversation_id" => new_id} = json_response(conn, 201)
      refute new_id == old_id
      assert Store.get(old_id) == :error
      assert {:ok, _context} = Store.get(new_id)
      assert_received {:fake_llm_called, %{messages: fresh_messages}}
      refute Enum.any?(fresh_messages, &(&1.role == :user))
    end

    test "language is optional", %{conn: conn} do
      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 201
      assert %{"ok" => true, "conversation_id" => _id} = json_response(conn, 201)
    end

    test "relays browser date/time and geolocation inside the last message", %{conn: conn} do
      conn =
        post_json(conn, %{
          "text" => "¿Qué tiempo hace aquí?",
          "date" => "2026-08-22",
          "time" => "14:35:07",
          "timezone" => "Europe/Madrid",
          "latitude" => 40.4168,
          "longitude" => -3.7038
        })

      assert conn.status == 201

      assert_received {:fake_llm_text, message}

      assert message =~
               ~S{[Fecha y hora actual: sábado 22 de agosto de 2026, 14:35 (Europe/Madrid). Ubicación aproximada del usuario: latitud 40,4168, longitud -3,7038}

      assert message =~ "Ubicación aproximada del usuario: latitud 40,4168, longitud -3,7038"
      assert String.ends_with?(message, "\n\n¿Qué tiempo hace aquí?")

      # Invalid values are ignored, not rejected.
      conn = build_conn() |> post_json(%{"text" => "Hola", "latitude" => "norte"})
      assert conn.status == 201

      assert_received {:fake_llm_text, bare}
      assert bare == "Hola"
    end

    test "maps LLM unavailability to a 502 JSON error", %{conn: conn} do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        fake_error: "Error: provider down"
      )

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 502
      assert %{"errors" => %{"text" => "LLM is unavailable"}} = json_response(conn, 502)
    end

    test "maps LLM timeout to a 504 JSON error", %{conn: conn} do
      Application.put_env(:soundai, Soundai.Conversation,
        adapter: FakeAdapter,
        fake_capture_pid: self(),
        fake_error: "Timed out waiting for LLM response after 30000ms"
      )

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 504
      assert %{"errors" => %{"text" => "LLM timed out"}} = json_response(conn, 504)
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
  end
end
