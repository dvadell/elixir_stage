defmodule Soundai.Conversation.Tools.SaveMessageTest do
  use Soundai.DataCase, async: true

  alias Soundai.Conversation.Tools.SaveMessage
  alias Soundai.Messages

  describe "tool/0" do
    test "builds the save_message tool with a callback" do
      tool = SaveMessage.tool()

      assert %ReqLLM.Tool{name: "save_message", callback: callback} = tool
      assert is_function(callback, 1)
    end
  end

  describe "save_message/1 (callback)" do
    test "persists the message and confirms naming the recipient" do
      assert {:ok, "Mensaje guardado para Diego."} =
               SaveMessage.save_message(%{
                 "to" => "Diego",
                 "body" => "no te olvides de tomar agua hoy",
                 "from" => "Mamá"
               })

      assert [%{body: "no te olvides de tomar agua hoy", to_name: "Diego", from_name: "Mamá"}] =
               Messages.pending_messages()
    end

    test "trims the recipient name before confirming" do
      assert {:ok, "Mensaje guardado para Diego."} =
               SaveMessage.save_message(%{"to" => " Diego ", "body" => "hola"})
    end

    test "stores a NULL sender when none was given" do
      assert {:ok, _} = SaveMessage.save_message(%{"to" => "Diego", "body" => "hola"})

      assert [%{from_name: nil}] = Messages.pending_messages()
    end

    test "rejects a missing or blank recipient" do
      assert {:error, "missing to"} = SaveMessage.save_message(%{"body" => "hola"})
      assert {:error, "missing to"} = SaveMessage.save_message(%{"to" => "   ", "body" => "hola"})
    end

    test "rejects a missing or blank body" do
      assert {:error, "missing body"} = SaveMessage.save_message(%{"to" => "Diego"})
      assert {:error, "missing body"} = SaveMessage.save_message(%{"to" => "Diego", "body" => ""})
    end

    test "rejects an oversized body through the changeset cap" do
      assert {:error, msg} =
               SaveMessage.save_message(%{"to" => "Diego", "body" => String.duplicate("a", 501)})

      assert msg =~ "body: should be at most 500 byte(s)"
    end

    test "accepts names at exactly the byte cap" do
      name_at_limit = String.duplicate("a", 100)

      assert {:ok, _} =
               SaveMessage.save_message(%{
                 "to" => "Diego",
                 "body" => "hola",
                 "from" => name_at_limit
               })

      assert [%{from_name: ^name_at_limit}] = Messages.pending_messages()
    end

    test "rejects an oversized name before hitting the database" do
      long_name = String.duplicate("a", 101)

      assert {:error, "from is too long (over 100 bytes)"} =
               SaveMessage.save_message(%{"to" => "Diego", "body" => "hola", "from" => long_name})

      assert {:error, "to is too long (over 100 bytes)"} =
               SaveMessage.save_message(%{"to" => long_name, "body" => "hola"})

      assert Messages.pending_messages() == []
    end
  end
end
