defmodule Soundai.Conversation.SpeechText do
  @moduledoc """
  Turns LLM replies into plain, speakable text.

  Voice assistants read every character out loud, so Markdown decoration must
  go before the text reaches TTS: otherwise the model says "asterisco" for
  `**bold**` or spells out URLs. `clean/1` strips Markdown syntax (emphasis,
  headers, bullets, quotes, code fences, tables, links, rules), removes emoji
  and pictographs, translates unpronounceable unit symbols into Spanish words
  (`°C` → "grados", `%` → "porciento", `km/h` → "kilómetros por hora"),
  normalizes numbers for speech, and collapses whitespace into one flowing
  line.

  ## Pinned rules

  ### Numbers (both locale conventions)

  1. Thousands separators are removed first: a `,` or `.` followed by exactly
     three digits that are not themselves followed by another digit is a
     separator — `"1,234"` → `"1234"`, `"1.234"` → `"1234"`, chained groups
     collapse too (`"1.234.567"` → `"1234567"`).
     Accepted ambiguity: `"12,345"` is read as `12345` (thousands), never as
     a decimal; IP-like sequences (`192.168.0.1`) are mangled in exchange.
  2. Then tight decimal commas are spelled out: `"12,6"` → `"12 coma 6"`.
     List commas keep their space (`"2020, 2021 y 1, 2, 3"`).
  3. Decimal points are left untouched (`"12.6"` stays as written).

  ### Symbol handling

  Meaningful symbols are translated to words *before* the remaining symbol
  blocks are deleted:

  | Input | Output |
  |-------|--------|
  | `→` / `->` | "va a" |
  | `⇒` | "entonces" |
  | `↑` / `⬆` | "sube" |
  | `↓` / `⬇` | "baja" |
  | `①`–`⑳` (U+2460–2473) | "(1)"–"(20)" |
  | `⑴`–`⑳` (U+2474–2487) | "(1)"–"(20)" |
  | keycap sequences (`1️⃣`) | the bare digit |

  Everything else in the assigned emoji/symbol blocks (pictographs, emoticons,
  transport, flags, dingbats, geometric shapes, enclosed characters,
  variation selectors, ZWJ) is deleted — TTS engines either skip those glyphs
  or read their names out loud ("cara sonriendo"). Common punctuation
  (© ® ™ …) and the masculine ordinal indicator (`1º`) are deliberately kept.

  ### Markdown leftovers

  After paired emphasis/inline-code are unwrapped, any surviving `*`, backtick
  or `#` is deleted: those can only be unbalanced markers ("**Hola",
  "se corta*", "#etiqueta") or multiplication signs, none of which TTS should
  pronounce.

  Non-binary input never leaks downstream to TTS: `clean/1` logs a warning
  and returns an empty string.
  """

  require Logger

  @links_and_images ~r/!?\[([^\]]*)\]\([^)]*\)/

  @code_blocks ~r/```[a-zA-Z0-9+#_-]*\s*/u
  @inline_code ~r/`([^`\n]+)`/

  # Paired emphasis is unwrapped first; any marker run that survives (an
  # unbalanced "**Hola" / "se corta*" or a multiplication "3 * 4") is then
  # stripped outright — TTS would read "asterisco".
  @emphasis [
    {~r/\*{1,3}([^*\n]+)\*{1,3}/, "\\1"},
    {~r/(?<!\w)__?([^_\n]+?)__?(?!\w)/, "\\1"},
    {~r/\*+/u, ""}
  ]

  @headers ~r/^[ \t]{0,3}\#{1,6}[ \t]+/m
  @rules ~r/^[ \t]*([-*_])[ \t]*(?:\1[ \t]*){2,}$/m
  @bullets ~r/^[ \t]*[-*+][ \t]+/m
  @numbered ~r/^[ \t]*\d{1,3}[.)][ \t]+/m
  @blockquotes ~r/^[ \t]*>[ \t]?/m
  @table_dividers ~r/^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/m
  @table_separators ~r/\|/

  # Markdown characters that are never speakable once paired syntax is gone:
  # unbalanced fences, inline hashtags, stray emphasis.
  @leftover_markdown ~r/[*`#]/u

  # Unit symbols the TTS model cannot pronounce: spell them out in Spanish.
  # The °C pair runs before the lone degree sign so "30°C" becomes a single
  # "grados". The masculine ordinal ("1º") is intentionally not touched here.
  @degrees ~r/\s*[°º]\s*[Cc]\b/u
  @lone_degree ~r/ ?°/u
  @percent ~r/ ?%/
  @speed ~r/\s*km\s*\/?\s*h\b/ui

  # Arrows carry meaning ("Madrid → Toledo"): translate the common ones to
  # words before the remaining arrow/symbol blocks are deleted.
  @arrow_words [
    {"→", " va a "},
    {"->", " va a "},
    {"⇒", " entonces "},
    {"↑", " sube "},
    {"⬆", " sube "},
    {"↓", " baja "},
    {"⬇", " baja "}
  ]

  @circled_digits ~r/[\x{2460}-\x{2473}]/u
  @parenthesized_digits ~r/[\x{2474}-\x{2487}]/u

  # Assigned emoji/symbol blocks with no speakable content. Arrows and circled
  # digits were translated above; whatever remains in their blocks is dropped
  # here along with pictographs, emoticons, transport, flags, dingbats,
  # geometric shapes, variation selectors, keycap enclosures and ZWJ.
  @symbols ~r/[\x{200D}\x{20E3}\x{FE00}-\x{FE0F}\x{2190}-\x{21FF}\x{231A}-\x{231B}\x{23E9}-\x{23FA}\x{2460}-\x{24FF}\x{25A0}-\x{25FF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{1F000}-\x{1F02F}\x{1F0A0}-\x{1F0FF}\x{1F100}-\x{1F2FF}\x{1F300}-\x{1F5FF}\x{1F600}-\x{1F64F}\x{1F680}-\x{1F6FF}\x{1F780}-\x{1F8FF}\x{1F900}-\x{1F9FF}\x{1FA00}-\x{1FAFF}]/u

  # Thousands separators: digit + separator + exactly three digits not
  # followed by another digit, so both locale conventions work and chained
  # groups collapse. Runs before decimal handling; "12,6" is untouched.
  @thousands_comma ~r/(\d),(?=\d{3}(?!\d))/u
  @thousands_dot ~r/(\d)\.(?=\d{3}(?!\d))/u

  # Decimal commas ("12,6"): the TTS model reads them wrong, so say "coma".
  # Only tight digit,digit matches — list commas ("1, 2 y 3") keep their space.
  @decimal_comma ~r/(\d),(\d)/u

  @doc """
  Returns `text` stripped of Markdown decoration and emoji, with unit symbols
  translated to Spanish words, numbers normalized for speech and extra
  whitespace collapsed — ready to be capped and synthesized.

  Accepts any term but only binaries produce content: anything else logs a
  warning and returns `""` so nothing unusable can reach TTS.
  """
  @spec clean(term()) :: binary()
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
    |> String.replace(@leftover_markdown, "")
    |> String.replace(@degrees, " grados")
    |> String.replace(@lone_degree, " grados")
    |> String.replace(@percent, " porciento")
    |> String.replace(@speed, " kilómetros por hora")
    |> translate_arrows()
    |> translate_enclosed_digits()
    |> String.replace(@symbols, "")
    |> String.replace(@thousands_comma, "\\1")
    |> String.replace(@thousands_dot, "\\1")
    |> String.replace(@decimal_comma, "\\1 coma \\2")
    |> collapse_whitespace()
  end

  def clean(other) do
    Logger.warning("SpeechText.clean/1 expected a binary, got: #{inspect(other)}")
    ""
  end

  defp remove_emphasis(text) do
    Enum.reduce(@emphasis, text, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
  end

  defp translate_arrows(text) do
    Enum.reduce(@arrow_words, text, fn {symbol, word}, acc ->
      String.replace(acc, symbol, word)
    end)
  end

  defp translate_enclosed_digits(text) do
    circled =
      Regex.replace(@circled_digits, text, fn digit ->
        <<codepoint::utf8>> = digit
        "(#{codepoint - 0x2460 + 1})"
      end)

    Regex.replace(@parenthesized_digits, circled, fn digit ->
      <<codepoint::utf8>> = digit
      "(#{codepoint - 0x2473})"
    end)
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
