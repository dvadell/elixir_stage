defmodule Soundai.Conversation.Tools.GetMessagesTest do
  use Soundai.DataCase, async: true

  alias Soundai.Conversation.Tools.GetMessages
  alias Soundai.Messages

  describe "tool/0" do
    test "builds the get_messages tool with a callback" do
      tool = GetMessages.tool()

      assert %ReqLLM.Tool{name: "get_messages", callback: callback} = tool
      assert is_function(callback, 1)
    end
  end

  describe "get_messages/1 (callback)" do
    test "an empty inbox with no filters" do
      assert {:ok, "No tienes mensajes nuevos."} = GetMessages.get_messages(%{})
      assert {:ok, "No tienes mensajes nuevos."} = GetMessages.get_messages(%{"from" => ""})
    end

    test "an empty inbox phrased around the requested names" do
      assert {:ok, "No hay mensajes nuevos de Diego."} =
               GetMessages.get_messages(%{"from" => "Diego"})

      assert {:ok, "No hay mensajes nuevos de Diego para Mamá."} =
               GetMessages.get_messages(%{"from" => "Diego", "to" => "Mamá"})
    end

    test "plays a single message, marks it delivered, and replays within the grace window" do
      {:ok, _} = Messages.save_message(%{"body" => "toma agua", "from_name" => "Diego"})

      assert {:ok, "Tienes un mensaje nuevo. De Diego: toma agua"} = GetMessages.get_messages(%{})

      # a play that never reached the speaker must not eat the message: an
      # immediate re-ask replays it instead of claiming an empty inbox
      assert {:ok, script} = GetMessages.get_messages(%{})
      assert script =~ "toma agua"
    end

    test "stops replaying a message delivered before the grace window" do
      {:ok, played} = Messages.save_message(%{"body" => "toma agua"})
      {:ok, _} = GetMessages.get_messages(%{})
      stamp_delivered_before_grace(played)

      assert {:ok, "No tienes mensajes nuevos."} = GetMessages.get_messages(%{})
    end

    test "a strictly pending message takes precedence over a just-played one" do
      {:ok, _} = Messages.save_message(%{"body" => "ya escuchado"})
      {:ok, _} = GetMessages.get_messages(%{})

      # a new message arrives after the playback: asking again must advance
      # the tape instead of repeating the just-played one
      {:ok, _} = Messages.save_message(%{"body" => "recién llegado", "from_name" => "Mamá"})

      assert {:ok, script} = GetMessages.get_messages(%{})
      assert script =~ "De Mamá: recién llegado"
      refute script =~ "ya escuchado"

      # only now, with the tape exhausted, does the just-played one come back
      assert {:ok, replay_script} = GetMessages.get_messages(%{})
      assert replay_script =~ "De alguien: ya escuchado"
    end

    test "plays several messages oldest first, in plural" do
      {:ok, _} = Messages.save_message(%{"body" => "primero", "from_name" => "Diego"})
      {:ok, _} = Messages.save_message(%{"body" => "segundo", "from_name" => "Mamá"})

      assert {:ok, script} = GetMessages.get_messages(%{})

      assert script ==
               "Tienes 2 mensajes nuevos. De Diego: primero De Mamá: segundo"

      # the tape is empty of strict pending, so the just-played pair replays
      assert [%{body: "primero"}, %{body: "segundo"}] = Messages.pending_messages()
    end

    test "says 'de alguien' for an unknown sender" do
      {:ok, _} = Messages.save_message(%{"body" => "la leche está en la nevera"})

      assert {:ok, "Tienes un mensaje nuevo. De alguien: la leche está en la nevera"} =
               GetMessages.get_messages(%{})
    end

    test "the :from filter excludes anonymous senders and other people" do
      {:ok, _} = Messages.save_message(%{"body" => "anónimo"})
      {:ok, _} = Messages.save_message(%{"body" => "de diego", "from_name" => "DIEGO"})
      {:ok, _} = Messages.save_message(%{"body" => "de maría", "from_name" => "María"})

      assert {:ok, "Tienes un mensaje nuevo. De DIEGO: de diego"} =
               GetMessages.get_messages(%{"from" => "diego"})
    end

    test "the :to filter keeps recipient-less messages (they are for everyone)" do
      {:ok, _} = Messages.save_message(%{"body" => "general"})
      {:ok, _} = Messages.save_message(%{"body" => "para ti", "to_name" => "MAMÁ"})
      {:ok, _} = Messages.save_message(%{"body" => "para otro", "to_name" => "Diego"})

      assert {:ok, script} = GetMessages.get_messages(%{"to" => "mamá"})

      assert script =~ "De alguien: general"
      assert script =~ "para ti"
      refute script =~ "para otro"
    end

    test "plays at most five per call; the rest stay pending" do
      for n <- 1..7 do
        {:ok, _} = Messages.save_message(%{"body" => "mensaje #{n}"})
      end

      assert {:ok, first_script} = GetMessages.get_messages(%{})
      assert first_script =~ "Tienes 5 mensajes nuevos"
      assert first_script =~ "Quedan 2 mensajes más."
      refute first_script =~ "mensaje 6"
      refute first_script =~ "mensaje 7"

      assert [%{body: "mensaje 6"}, %{body: "mensaje 7"}] = Messages.pending_messages()

      assert {:ok, second_script} = GetMessages.get_messages(%{})
      assert second_script =~ "Tienes 2 mensajes nuevos"
      assert second_script =~ "mensaje 6"
      assert second_script =~ "mensaje 7"
      refute second_script =~ "más."
    end
  end

  # Marks a message delivered outside the replay grace window, simulating a
  # play that happened long ago (mark_delivered/1 always stamps "now").
  defp stamp_delivered_before_grace(message) do
    delivered_at =
      DateTime.utc_now()
      |> DateTime.add(-3600, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(
      from(m in Soundai.Messages.Message, where: m.id == ^message.id),
      set: [delivered_at: delivered_at]
    )
  end
end
