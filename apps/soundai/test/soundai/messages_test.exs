defmodule Soundai.MessagesTest do
  use Soundai.DataCase, async: true

  alias Soundai.Messages

  describe "save_message/1" do
    test "persists body, sender and recipient" do
      assert {:ok, message} =
               Messages.save_message(%{
                 "body" => "no te olvides de tomar agua hoy",
                 "from_name" => "Mamá",
                 "to_name" => "Diego"
               })

      assert message.body == "no te olvides de tomar agua hoy"
      assert message.from_name == "Mamá"
      assert message.to_name == "Diego"
    end

    test "trims the body and the names" do
      assert {:ok, message} =
               Messages.save_message(%{
                 "body" => "  hola  ",
                 "from_name" => "  Diego ",
                 "to_name" => " Mamá "
               })

      assert message.body == "hola"
      assert message.from_name == "Diego"
      assert message.to_name == "Mamá"
    end

    test "stores blank or missing names as NULL" do
      assert {:ok, message} =
               Messages.save_message(%{
                 "body" => "la leche está en la nevera",
                 "to_name" => "   "
               })

      assert message.from_name == nil
      assert message.to_name == nil
    end

    test "rejects a blank body" do
      assert {:error, changeset} = Messages.save_message(%{"body" => "   "})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an explicitly nil body without crashing" do
      assert {:error, changeset} = Messages.save_message(%{"body" => nil})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a body over the size cap" do
      assert {:error, changeset} = Messages.save_message(%{"body" => String.duplicate("a", 501)})

      assert %{body: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end

    test "rejects oversized names" do
      assert {:error, changeset} =
               Messages.save_message(%{
                 "body" => "hola",
                 "from_name" => String.duplicate("a", 101)
               })

      assert %{from_name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most"
    end
  end

  describe "pending_messages/0" do
    test "returns messages within the retention window oldest first" do
      {:ok, _} = Messages.save_message(%{"body" => "primero"})
      {:ok, _} = Messages.save_message(%{"body" => "segundo"})

      assert [%{body: "primero"}, %{body: "segundo"}] = Messages.pending_messages()
    end

    test "returns at most the configured number of messages, keeping the most recent" do
      for n <- 1..7 do
        {:ok, _} = Messages.save_message(%{"body" => "mensaje #{n}"})
      end

      bodies = Enum.map(Messages.pending_messages(), & &1.body)

      # the tape plays backwards-trimmed: the LAST max_messages (default 5),
      # spoken chronologically
      assert bodies == ["mensaje 3", "mensaje 4", "mensaje 5", "mensaje 6", "mensaje 7"]
    end

    test "honours a :max_messages override" do
      for n <- 1..4 do
        {:ok, _} = Messages.save_message(%{"body" => "mensaje #{n}"})
      end

      bodies = Enum.map(Messages.pending_messages(max_messages: 2), & &1.body)
      assert bodies == ["mensaje 3", "mensaje 4"]
    end

    test "messages older than the retention window are not shown" do
      {:ok, old} = Messages.save_message(%{"body" => "antiguo"})
      {:ok, _} = Messages.save_message(%{"body" => "reciente"})

      age_message(old, days: 31)

      assert [%{body: "reciente"}] = Messages.pending_messages()
    end

    test "messages just inside the retention window are shown" do
      {:ok, almost_old} = Messages.save_message(%{"body" => "casi viejo"})

      age_message(almost_old, days: 29)

      assert [%{body: "casi viejo"}] = Messages.pending_messages()
    end

    test "is empty with no messages" do
      assert Messages.pending_messages() == []
    end
  end

  describe "pending_messages/1 name filters" do
    test ":from matches case- and accent-insensitively" do
      {:ok, _} = Messages.save_message(%{"body" => "uno", "from_name" => "DIEGO"})
      {:ok, _} = Messages.save_message(%{"body" => "otro", "from_name" => "María"})

      assert [%{body: "uno"}] = Messages.pending_messages(from: "diego")
      assert [%{body: "otro"}] = Messages.pending_messages(from: "maria")
    end

    test ":to matches best-effort too" do
      {:ok, _} = Messages.save_message(%{"body" => "agua", "to_name" => "Mamá"})

      assert [%{body: "agua"}] = Messages.pending_messages(to: "mama")
      assert [] = Messages.pending_messages(to: "diego")
    end

    test "an unknown sender never matches a named :from filter" do
      {:ok, _} = Messages.save_message(%{"body" => "anónimo"})

      assert [] = Messages.pending_messages(from: "diego")
      assert [%{body: "anónimo"}] = Messages.pending_messages()
    end

    test "a message with no recipient passes any :to filter (it is for everyone)" do
      {:ok, _} = Messages.save_message(%{"body" => "general"})

      assert [%{body: "general"}] = Messages.pending_messages(to: "diego")
    end

    test ":from and :to combine" do
      {:ok, _} =
        Messages.save_message(%{"body" => "suyo", "from_name" => "Diego", "to_name" => "Mamá"})

      {:ok, _} =
        Messages.save_message(%{"body" => "ajeno", "from_name" => "María", "to_name" => "Mamá"})

      assert [%{body: "suyo"}] = Messages.pending_messages(from: "Diego", to: "mamá")
    end

    test "a non-binary filter matches nothing instead of being dropped" do
      {:ok, _} = Messages.save_message(%{"body" => "para diego", "to_name" => "Diego"})
      {:ok, _} = Messages.save_message(%{"body" => "general"})

      assert [] = Messages.pending_messages(from: 123)

      # a garbage :to still lets recipient-less notes through: they are for
      # everyone regardless of who is (or is not) named
      assert [%{body: "general"}] = Messages.pending_messages(to: 123)
    end
  end

  # Moves a message's inserted_at into the past to simulate aging. Rows are
  # never deleted or marked; visibility depends on insertion age alone.
  defp age_message(message, days: days) do
    inserted_at =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(
      from(m in Soundai.Messages.Message, where: m.id == ^message.id),
      set: [inserted_at: inserted_at]
    )
  end
end
