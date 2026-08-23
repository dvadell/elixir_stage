defmodule Soundai.TTSTest do
  use ExUnit.Case, async: false

  alias Soundai.TTS

  setup do
    previous = Application.get_env(:soundai, Soundai.TTS)

    on_exit(fn ->
      if previous do
        Application.put_env(:soundai, Soundai.TTS, previous)
      else
        Application.delete_env(:soundai, Soundai.TTS)
      end
    end)

    :ok
  end

  describe "validate_text/1" do
    test "accepts non-blank text within the length cap" do
      assert TTS.validate_text("Hola") == :ok
    end

    test "rejects blank text" do
      assert TTS.validate_text("   ") == {:error, :empty}
      assert TTS.validate_text("") == {:error, :empty}
    end

    test "rejects text over 100000 bytes" do
      assert TTS.validate_text(String.duplicate("a", 100_001)) == {:error, :too_long}
    end

    test "rejects non-binary input" do
      assert TTS.validate_text(123) == {:error, :invalid}
    end
  end

  describe "synthesize/2" do
    test "delegates to the configured adapter and adds the content type" do
      Application.put_env(:soundai, Soundai.TTS, adapter: Soundai.TTS.FakeAdapter)

      assert {:ok, wav} = TTS.synthesize("Hola")
      assert wav.content_type == "audio/wav"
      assert wav.sample_rate == 16_000
    end

    test "returns not_ready when the real adapter has no running server" do
      Application.put_env(:soundai, Soundai.TTS, adapter: Soundai.TTS.OrtexServer)

      assert {:error, :not_ready} = TTS.synthesize("Hola")
    end

    test "validates before calling the adapter" do
      Application.put_env(:soundai, Soundai.TTS, adapter: Soundai.TTS.FakeAdapter)

      assert {:error, :empty} = TTS.synthesize("  ")
      assert {:error, :too_long} = TTS.synthesize(String.duplicate("a", 100_001))
      assert {:error, :invalid} = TTS.synthesize(nil)
    end
  end
end
