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

    test "plays a single message as the last one" do
      {:ok, _} = Messages.save_message(%{"body" => "toma agua", "from_name" => "Diego"})

      assert {:ok, "Este es tu último mensaje. De Diego: toma agua"} =
               GetMessages.get_messages(%{})
    end

    test "listening does not consume the tape: an immediate re-ask replays it" do
      {:ok, _} = Messages.save_message(%{"body" => "toma agua", "from_name" => "Diego"})

      assert {:ok, _} = GetMessages.get_messages(%{})

      assert {:ok, script} = GetMessages.get_messages(%{})
      assert script =~ "toma agua"
    end

    test "plays several messages oldest first, in plural" do
      {:ok, _} = Messages.save_message(%{"body" => "primero", "from_name" => "Diego"})
      {:ok, _} = Messages.save_message(%{"body" => "segundo", "from_name" => "Mamá"})

      assert {:ok, script} = GetMessages.get_messages(%{})

      assert script == "Estos son tus últimos 2 mensajes. De Diego: primero De Mamá: segundo"
    end

    test "plays only the most recent five when more exist" do
      for n <- 1..7 do
        {:ok, _} = Messages.save_message(%{"body" => "mensaje #{n}"})
      end

      assert {:ok, script} = GetMessages.get_messages(%{})

      assert script =~ "Estos son tus últimos 5 mensajes"
      refute script =~ "mensaje 1"
      refute script =~ "mensaje 2"
      assert script =~ "mensaje 3"
      assert script =~ "mensaje 7"
    end

    test "says 'de alguien' for an unknown sender" do
      {:ok, _} = Messages.save_message(%{"body" => "la leche está en la nevera"})

      assert {:ok, "Este es tu último mensaje. De alguien: la leche está en la nevera"} =
               GetMessages.get_messages(%{})
    end

    test "the :from filter excludes anonymous senders and other people" do
      {:ok, _} = Messages.save_message(%{"body" => "anónimo"})
      {:ok, _} = Messages.save_message(%{"body" => "de diego", "from_name" => "DIEGO"})
      {:ok, _} = Messages.save_message(%{"body" => "de maría", "from_name" => "María"})

      assert {:ok, "Este es tu último mensaje. De DIEGO: de diego"} =
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
  end
end
