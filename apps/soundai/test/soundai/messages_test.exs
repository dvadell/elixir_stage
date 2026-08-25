defmodule Soundai.MessagesTest do
  use Soundai.DataCase, async: true

  alias Soundai.Messages
  alias Soundai.Messages.Message

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
      assert message.delivered_at == nil
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
    test "returns undelivered messages oldest first" do
      {:ok, first} = Messages.save_message(%{"body" => "primero"})
      {:ok, second} = Messages.save_message(%{"body" => "segundo"})

      assert [%{id: id1}, %{id: id2}] = Messages.pending_messages()
      assert id1 == first.id
      assert id2 == second.id
    end

    test "excludes delivered messages" do
      {:ok, played} = Messages.save_message(%{"body" => "ya escuchado"})
      {:ok, pending} = Messages.save_message(%{"body" => "pendiente"})

      Messages.mark_delivered([Repo.get!(Message, played.id)])

      # strictly pending messages win; a just-played one only replays when
      # nothing strictly pending matches (see the grace-window tests below)
      assert [%{id: id}] = Messages.pending_messages()
      assert id == pending.id
    end

    test "a message delivered within the grace window is still replayable" do
      {:ok, played} = Messages.save_message(%{"body" => "recién jugado"})
      Messages.mark_delivered([Repo.get!(Message, played.id)])

      assert [%{id: id, delivered_at: %DateTime{}}] = Messages.pending_messages()
      assert id == played.id
    end

    test "a message delivered before the grace window is gone" do
      {:ok, played} = Messages.save_message(%{"body" => "antiguo"})

      stamp_delivered(played, hours_ago: 1)

      assert [] = Messages.pending_messages()
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

  describe "mark_delivered/1" do
    test "stamps delivered_at on exactly the given messages" do
      {:ok, one} = Messages.save_message(%{"body" => "uno"})
      {:ok, two} = Messages.save_message(%{"body" => "dos"})

      assert {2, nil} = Messages.mark_delivered([one, two])

      reloaded_one = Repo.get!(Message, one.id)
      reloaded_two = Repo.get!(Message, two.id)
      assert %DateTime{} = reloaded_one.delivered_at
      assert DateTime.compare(reloaded_two.delivered_at, reloaded_one.delivered_at) == :eq

      # both are still within the grace window, so they stay replayable
      assert [replayed_one, replayed_two] = Messages.pending_messages()
      assert replayed_one.id == one.id
      assert replayed_two.id == two.id
    end

    test "accepts an empty list" do
      assert {0, nil} = Messages.mark_delivered([])
    end
  end

  # Stamps an explicit delivered_at in the past; mark_delivered/1 always uses
  # "now", which would land inside the replay grace window.
  defp stamp_delivered(message, hours_ago: hours) do
    delivered_at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Repo.update_all(from(m in Message, where: m.id == ^message.id),
      set: [delivered_at: DateTime.truncate(delivered_at, :second)]
    )
  end
end
