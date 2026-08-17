defmodule Soundai.TTS.VitsTokenizerTest do
  use ExUnit.Case, async: true

  alias Soundai.TTS.VitsTokenizer

  # Reference ids captured from the real @huggingface/transformers
  # VitsTokenizer in Node (T0008_test_tts.mjs machinery).
  @reference %{
    "Hola, ¿cómo estás?" => [
      0,
      19,
      0,
      41,
      0,
      35,
      0,
      1,
      0,
      27,
      0,
      3,
      0,
      7,
      0,
      13,
      0,
      41,
      0,
      27,
      0,
      39,
      0,
      16,
      0,
      26,
      0,
      17,
      0,
      16,
      0
    ],
    "Buenos días, ¿qué tal?" => [
      0,
      31,
      0,
      38,
      0,
      39,
      0,
      20,
      0,
      41,
      0,
      16,
      0,
      27,
      0,
      29,
      0,
      30,
      0,
      1,
      0,
      16,
      0,
      27,
      0,
      18,
      0,
      38,
      0,
      21,
      0,
      27,
      0,
      26,
      0,
      1,
      0,
      35,
      0
    ],
    "Este es un ejemplo de prueba." => [
      0,
      39,
      0,
      16,
      0,
      26,
      0,
      39,
      0,
      27,
      0,
      39,
      0,
      16,
      0,
      27,
      0,
      38,
      0,
      20,
      0,
      27,
      0,
      39,
      0,
      33,
      0,
      39,
      0,
      13,
      0,
      9,
      0,
      35,
      0,
      41,
      0,
      27,
      0,
      29,
      0,
      39,
      0,
      27,
      0,
      9,
      0,
      43,
      0,
      38,
      0,
      39,
      0,
      31,
      0,
      1,
      0
    ]
  }

  test "produces the same ids as the transformers.js reference" do
    for {text, expected} <- @reference do
      {ids, _mask} = VitsTokenizer.tokenize(text)
      assert ids == expected, "tokenization mismatch for #{inspect(text)}"
    end
  end

  test "lowercases and trims the input" do
    {ids, _mask} = VitsTokenizer.tokenize("  HOLA  ")
    assert ids == [0, 19, 0, 41, 0, 35, 0, 1, 0]
  end

  test "drops characters outside the vocabulary" do
    {ids, _mask} = VitsTokenizer.tokenize("Hola, ¿qué? ¡Adiós!")

    assert ids == [
             0,
             19,
             0,
             41,
             0,
             35,
             0,
             1,
             0,
             27,
             0,
             18,
             0,
             38,
             0,
             21,
             0,
             27,
             0,
             1,
             0,
             29,
             0,
             37,
             0,
             7,
             0,
             16,
             0
           ]
  end

  test "empty input yields only the separator token" do
    {ids, _mask} = VitsTokenizer.tokenize("¿?¿?")
    assert ids == [0]
  end

  test "attention mask is all ones and matches the id length" do
    {ids, mask} = VitsTokenizer.tokenize("Hola")
    assert length(ids) == length(mask)
    assert Enum.all?(mask, &(&1 == 1))
  end

  test "sample_rate is 16 kHz" do
    assert VitsTokenizer.sample_rate() == 16_000
  end
end
