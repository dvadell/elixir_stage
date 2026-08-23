defmodule Soundai.NotesTest do
  use Soundai.DataCase, async: true

  alias Soundai.Notes

  describe "create_note/1" do
    test "persists freeform text" do
      assert {:ok, note} =
               Notes.create_note(%{"content" => "Una nota libre\ncon saltos de línea"})

      assert note.content == "Una nota libre\ncon saltos de línea"
    end

    test "trims surrounding whitespace" do
      assert {:ok, note} = Notes.create_note(%{"content" => "  hola  \n"})

      assert note.content == "hola"
    end

    test "rejects blank content" do
      assert {:error, changeset} = Notes.create_note(%{"content" => "   "})

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing content" do
      assert {:error, changeset} = Notes.create_note(%{})

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects content over the size cap" do
      assert {:error, changeset} =
               Notes.create_note(%{"content" => String.duplicate("a", 10_001)})

      assert %{content: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end
  end

  describe "list_notes/0" do
    test "returns notes newest first" do
      {:ok, first} = Notes.create_note(%{"content" => "primera"})
      {:ok, second} = Notes.create_note(%{"content" => "segunda"})

      assert [%{id: second_id}, %{id: first_id}] = Notes.list_notes()
      assert second_id == second.id
      assert first_id == first.id
    end
  end
end
