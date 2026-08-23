# The notes page is intentionally public (there is no authentication in the
# app yet), so skip the missing-authentication heuristic.
# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
defmodule SoundaiWeb.NotesController do
  use SoundaiWeb, :controller

  alias Soundai.Notes

  # Controllers do not import Phoenix.Component, but to_form/2 lives there.
  defp to_form(changeset, opts), do: Phoenix.Component.to_form(changeset, opts)

  def index(conn, _params) do
    render(conn, :index, form: to_form(Notes.changeset(%Notes.Note{}, %{}), as: :note))
  end

  def create(conn, %{"note" => note_params}) do
    case Notes.create_note(note_params) do
      {:ok, _note} ->
        conn
        |> put_flash(:info, gettext("Nota guardada."))
        |> redirect(to: ~p"/notes")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_flash(:error, gettext("No se pudo guardar la nota."))
        |> render(:index, form: to_form(changeset, as: :note))
    end
  end
end
