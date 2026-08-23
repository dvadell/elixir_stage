defmodule SoundaiWeb.NotesControllerTest do
  use SoundaiWeb.ConnCase, async: true

  alias Soundai.Notes

  describe "GET /notes" do
    test "renders the note form with a Guardar button", %{conn: conn} do
      conn = get(conn, ~p"/notes")

      assert html_response(conn, 200) =~ "Guardar"
    end
  end

  describe "POST /notes" do
    test "saves the content and redirects with a success flash", %{conn: conn} do
      conn = post(conn, ~p"/notes", %{"note" => %{"content" => "Recuerda comprar leche"}})

      assert redirected_to(conn) == ~p"/notes"

      assert [%{content: "Recuerda comprar leche"}] = Notes.list_notes()

      conn = get(conn, ~p"/notes")
      assert html_response(conn, 200) =~ "Nota guardada."
    end

    test "re-renders the form when content is blank", %{conn: conn} do
      conn = post(conn, ~p"/notes", %{"note" => %{"content" => "   "}})

      assert html_response(conn, 422) =~ "Guardar"
      assert Notes.list_notes() == []
    end
  end
end
