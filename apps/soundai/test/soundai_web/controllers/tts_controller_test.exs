defmodule SoundaiWeb.TTSControllerTest do
  use SoundaiWeb.ConnCase, async: false

  alias Soundai.TTS.FakeAdapter
  alias Soundai.TTS.OrtexServer

  setup do
    previous = Application.get_env(:soundai, Soundai.TTS)

    on_exit(fn ->
      if previous do
        Application.put_env(:soundai, Soundai.TTS, previous)
      else
        Application.delete_env(:soundai, Soundai.TTS)
      end
    end)

    :ok
  end

  defp post_json(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/tts", Jason.encode!(params))
  end

  describe "POST /api/tts" do
    test "returns a playable WAV for valid text", %{conn: conn} do
      Application.put_env(:soundai, Soundai.TTS, adapter: FakeAdapter)

      conn = post_json(conn, %{"text" => "Hola", "language" => "spanish"})

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["audio/wav"]
      assert get_resp_header(conn, "x-tts-model") == ["Xenova/mms-tts-spa"]
      assert get_resp_header(conn, "x-tts-duration-ms") == ["1"]
      assert conn.resp_body == FakeAdapter.wav()
    end

    test "language is optional", %{conn: conn} do
      Application.put_env(:soundai, Soundai.TTS, adapter: FakeAdapter)

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["audio/wav"]
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
      conn = post_json(conn, %{"text" => String.duplicate("a", 100_001)})

      assert conn.status == 422
      assert %{"errors" => %{"text" => "is too long"}} = json_response(conn, 422)
    end

    test "returns 503 when the model is not available", %{conn: conn} do
      Application.put_env(:soundai, Soundai.TTS, adapter: OrtexServer)

      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 503
      assert %{"errors" => %{"text" => "server TTS is not ready"}} = json_response(conn, 503)
    end
  end
end
