defmodule SoundaiWeb.NotesControllerTest do
  use SoundaiWeb.ConnCase, async: true

  alias Soundai.Notes
  alias Soundai.Repo

  describe "GET /notes" do
    test "renders the note form with a Guardar button", %{conn: conn} do
      conn = get(conn, ~p"/notes")

      assert html_response(conn, 200) =~ "Guardar"
    end

    test "prefills the form with the saved text", %{conn: conn} do
      {:ok, _} = Notes.save_note(%{"content" => "texto guardado antes"})

      conn = get(conn, ~p"/notes")

      assert html_response(conn, 200) =~ "texto guardado antes"
    end
  end

  describe "POST /notes" do
    test "saves the content and redirects with a success flash", %{conn: conn} do
      conn = post(conn, ~p"/notes", %{"note" => %{"content" => "Recuerda comprar leche"}})

      assert redirected_to(conn) == ~p"/notes"

      assert Notes.note_text() == "Recuerda comprar leche"

      conn = get(conn, ~p"/notes")
      assert html_response(conn, 200) =~ "Nota guardada."
    end

    test "replaces the previous text instead of appending a new note", %{conn: conn} do
      {:ok, _} = Notes.save_note(%{"content" => "versión inicial"})

      conn = post(conn, ~p"/notes", %{"note" => %{"content" => "versión reescrita"}})

      assert redirected_to(conn) == ~p"/notes"
      assert [%{content: "versión reescrita"}] = Repo.all(Notes.Note)
    end

    test "re-renders the form when content is blank", %{conn: conn} do
      conn = post(conn, ~p"/notes", %{"note" => %{"content" => "   "}})

      assert html_response(conn, 422) =~ "Guardar"
      assert Notes.current_note() == nil
    end
  end
end
