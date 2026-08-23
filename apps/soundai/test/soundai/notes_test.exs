defmodule Soundai.NotesTest do
  use Soundai.DataCase, async: true

  alias Soundai.Notes

  describe "save_note/1" do
    test "persists freeform text on first save" do
      assert {:ok, note} = Notes.save_note(%{"content" => "Una nota libre\ncon saltos de línea"})

      assert note.content == "Una nota libre\ncon saltos de línea"
      assert Notes.current_note().id == note.id
    end

    test "replaces the text in place: always a single row" do
      {:ok, _} = Notes.save_note(%{"content" => "versión inicial"})
      {:ok, second} = Notes.save_note(%{"content" => "versión reescrita\ncon más detalle"})

      assert [%{id: id, content: "versión reescrita\ncon más detalle"}] = Repo.all(Notes.Note)
      assert id == second.id
      assert Notes.note_text() == "versión reescrita\ncon más detalle"
    end

    test "trims surrounding whitespace" do
      assert {:ok, _note} = Notes.save_note(%{"content" => "  hola  \n"})

      assert Notes.note_text() == "hola"
    end

    test "rejects blank content" do
      assert {:error, changeset} = Notes.save_note(%{"content" => "   "})

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing content" do
      assert {:error, changeset} = Notes.save_note(%{})

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects content over the size cap" do
      assert {:error, changeset} =
               Notes.save_note(%{"content" => String.duplicate("a", 10_001)})

      assert %{content: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end
  end

  describe "current_note/0 and change_note/0" do
    test "return nil / an empty form before the first save" do
      assert Notes.current_note() == nil

      changeset = Notes.change_note()
      assert Ecto.Changeset.get_field(changeset, :content) == nil
    end

    test "prefill the form with the saved text" do
      {:ok, _} = Notes.save_note(%{"content" => "texto guardado"})

      assert Notes.current_note().content == "texto guardado"

      changeset = Notes.change_note()
      assert Ecto.Changeset.get_field(changeset, :content) == "texto guardado"
    end
  end
end
