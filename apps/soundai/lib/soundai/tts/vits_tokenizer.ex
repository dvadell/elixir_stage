defmodule Soundai.TTS.VitsTokenizer do
  @moduledoc """
  Character-level tokenization for the `Xenova/mms-tts-spa` VITS model.

  Mirrors the Hugging Face `VitsTokenizer` (`tokenizer.json`) rules exactly:

    1. lowercase the input;
    2. drop every character outside the model's vocabulary;
    3. trim surrounding whitespace;
    4. insert the `"7"` separator token (id `0`) before every character and
       once more at the end.

  The output is the pair `{input_ids, attention_mask}` used by the ONNX graph.
  """

  @sample_rate 16_000

  @vocab %{
    "7" => 0,
    "a" => 1,
    "v" => 2,
    "c" => 3,
    "—" => 4,
    "0" => 5,
    "5" => 6,
    "ó" => 7,
    "8" => 8,
    "p" => 9,
    "y" => 10,
    "z" => 11,
    "4" => 12,
    "m" => 13,
    "ü" => 14,
    "k" => 15,
    "s" => 16,
    "á" => 17,
    "q" => 18,
    "h" => 19,
    "n" => 20,
    "é" => 21,
    "_" => 22,
    "9" => 23,
    "1" => 24,
    "f" => 25,
    "t" => 26,
    " " => 27,
    "x" => 28,
    "d" => 29,
    "í" => 30,
    "b" => 31,
    "3" => 32,
    "j" => 33,
    "g" => 34,
    "l" => 35,
    "2" => 36,
    "i" => 37,
    "u" => 38,
    "e" => 39,
    "ú" => 40,
    "o" => 41,
    "ñ" => 42,
    "r" => 43,
    "6" => 44,
    "<unk>" => 45
  }

  @separator_token 0
  @unk_token 45

  # Everything outside this character class is dropped before tokenizing. The
  # `u` flag is required so the class is matched by codepoint (without it PCRE
  # matches bytes and multibyte accents/symbols survive incorrectly).
  @non_vocab ~r/[^7avc—05ó8pyz4müksáqhné_91ft xdí b3jgl2iueúoñr6]/u

  @doc """
  Tokenizes `text` into `{input_ids, attention_mask}` for the VITS model.

  Every returned id is guaranteed to exist in the vocabulary: characters that
  survive the normalization step are exactly the vocabulary keys.
  """
  def tokenize(text) when is_binary(text) do
    normalized =
      text
      |> String.downcase()
      |> String.replace(@non_vocab, "")
      |> String.trim()

    ids =
      normalized
      |> String.graphemes()
      |> Enum.flat_map(fn char ->
        [@separator_token, Map.get(@vocab, char, @unk_token)]
      end)
      |> Kernel.++([@separator_token])

    {ids, List.duplicate(1, length(ids))}
  end

  @doc "The sampling rate the model synthesizes at."
  def sample_rate, do: @sample_rate
end
