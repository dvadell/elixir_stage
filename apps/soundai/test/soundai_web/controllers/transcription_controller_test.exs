defmodule SoundaiWeb.TranscriptionControllerTest do
  use SoundaiWeb.ConnCase, async: true

  defp post_json(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/transcriptions", Jason.encode!(params))
  end

  describe "POST /api/transcriptions" do
    test "accepts a valid transcript and returns the ok envelope", %{conn: conn} do
      conn =
        post_json(conn, %{
          "text" => "¿Qué tiempo hace mañana?",
          "language" => "spanish"
        })

      assert conn.status == 201
      assert %{"ok" => true, "language" => "spanish"} = json_response(conn, 201)
    end

    test "language is optional", %{conn: conn} do
      conn = post_json(conn, %{"text" => "Hola"})

      assert conn.status == 201
      assert %{"ok" => true} = json_response(conn, 201)
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

    test "trims surrounding whitespace", %{conn: conn} do
      conn = post_json(conn, %{"text" => "  Hola  "})

      assert conn.status == 201
      assert %{"ok" => true} = json_response(conn, 201)
    end
  end
end
