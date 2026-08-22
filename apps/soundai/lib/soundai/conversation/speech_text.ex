defmodule Soundai.Conversation.SpeechText do
  @moduledoc """
  Turns LLM replies into plain, speakable text.

  Voice assistants read every character out loud, so Markdown decoration must
  go before the text reaches TTS: otherwise the model says "asterisco" for
  `**bold**` or spells out URLs. `clean/1` strips Markdown syntax (emphasis,
  headers, bullets, quotes, code fences, tables, links, rules), removes emoji
  and pictographs, translates unpronounceable unit symbols into Spanish words
  (`°C` → "grados", `%` → "porciento", `km/h` → "kilómetros por hora"),
  spells decimal commas out loud (`12,6` → "12 coma 6"), and collapses
  whitespace into one flowing line.
  """

  @links_and_images ~r/!?\[([^\]]*)\]\([^)]*\)/

  @code_blocks ~r/```[a-zA-Z0-9+#_-]*\s*/u
  @inline_code ~r/`([^`\n]+)`/

  @emphasis [
    {~r/\*{1,3}([^*\n]+)\*{1,3}/, "\\1"},
    {~r/(?<!\w)__?([^_\n]+?)__?(?!\w)/, "\\1"}
  ]

  @headers ~r/^[ \t]{0,3}\#{1,6}[ \t]+/m
  @bullets ~r/^[ \t]*[-*+][ \t]+/m
  @numbered ~r/^[ \t]*\d{1,3}[.)][ \t]+/m
  @blockquotes ~r/^[ \t]*>[ \t]?/m
  @table_dividers ~r/^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/m
  @table_separators ~r/\|/
  @rules ~r/^[ \t]*([-*_])[ \t]*(?:\1[ \t]*){2,}$/m

  # Emoji, pictographs, dingbats, arrows and variation selectors: TTS engines
  # either skip these or read their names out loud ("cara sonriendo").
  @symbols ~r/[\x{1F000}-\x{1FAFF}\x{2190}-\x{21FF}\x{2300}-\x{23FF}\x{2460}-\x{24FF}\x{25A0}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE00}-\x{FE0F}\x{200D}]/u

  # Unit symbols the TTS model cannot pronounce: spell them out in Spanish.
  @degrees ~r/\s*[°º]\s*[Cc]\b/u
  @percent ~r/ ?%/
  @speed ~r/\s*km\s*\/?\s*h\b/ui

  # Decimal commas ("12,6"): the TTS model reads them wrong, so say "coma".
  # Only tight digit,digit matches — list commas ("1, 2 y 3") keep their space.
  @decimal_comma ~r/(\d),(\d)/u

  @doc """
  Returns `text` stripped of Markdown decoration and emoji, with unit symbols
  translated to Spanish words and extra whitespace collapsed — ready to be
  capped and synthesized.
  """
  @spec clean(term()) :: term()
  def clean(text) when is_binary(text) do
    text
    |> String.replace(@links_and_images, "\\1")
    |> String.replace(@code_blocks, "")
    |> String.replace(@inline_code, "\\1")
    |> remove_emphasis()
    |> String.replace(@headers, "")
    |> String.replace(@rules, "")
    |> String.replace(@blockquotes, "")
    |> String.replace(@bullets, "")
    |> String.replace(@numbered, "")
    |> String.replace(@table_dividers, "")
    |> String.replace(@table_separators, " ")
    |> String.replace(@degrees, " grados")
    |> String.replace(@percent, " porciento")
    |> String.replace(@speed, " kilómetros por hora")
    |> String.replace(@decimal_comma, "\\1 coma \\2")
    |> String.replace(@symbols, "")
    |> collapse_whitespace()
  end

  def clean(other), do: other

  defp remove_emphasis(text) do
    Enum.reduce(@emphasis, text, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
