defmodule Soundai.Conversation.SpeechTextTest do
  use ExUnit.Case, async: true

  alias Soundai.Conversation.SpeechText

  describe "clean/1 markdown" do
    test "strips bold and italic markers" do
      assert SpeechText.clean("**Hola** y *buenos* días") == "Hola y buenos días"
      assert SpeechText.clean("__Hola__ y _buenos_ días") == "Hola y buenos días"
      assert SpeechText.clean("***Muy importante***") == "Muy importante"
    end

    test "keeps snake_case identifiers intact while stripping emphasis underscores" do
      assert SpeechText.clean("el campo _temperatura_ es temperature_2m") ==
               "el campo temperatura es temperature_2m"
    end

    test "strips unbalanced emphasis markers" do
      assert SpeechText.clean("**Hola") == "Hola"
      assert SpeechText.clean("se corta*") == "se corta"
      assert SpeechText.clean("3 * 4") == "3 4"
    end

    test "unwraps nested emphasis" do
      assert SpeechText.clean("**negrita *con* anidada**") == "negrita con anidada"
    end

    test "removes headers and stray hashes" do
      assert SpeechText.clean("## El tiempo\nEstá soleado") == "El tiempo Está soleado"
      assert SpeechText.clean("#etiqueta sin espacio") == "etiqueta sin espacio"
    end

    test "removes bullet and numbered list markers" do
      assert SpeechText.clean("- lluvia\n- sol\n+ viento") == "lluvia sol viento"
      assert SpeechText.clean("1. Madrid\n2. Barcelona") == "Madrid Barcelona"
    end

    test "replaces links with their text and keeps image alt text" do
      assert SpeechText.clean("Mira [el pronóstico](https://ejemplo.com/x) aquí") ==
               "Mira el pronóstico aquí"

      assert SpeechText.clean("![foto](https://ejemplo.com/f.png) listo") == "foto listo"
    end

    test "removes code fences, inline backticks and stray backticks" do
      assert SpeechText.clean("```elixir\n1 + 1\n```\nListo") == "1 + 1 Listo"
      assert SpeechText.clean("usa `mix test` para probar") == "usa mix test para probar"
      assert SpeechText.clean("esto `falla") == "esto falla"
    end

    test "removes blockquotes and horizontal rules" do
      assert SpeechText.clean("> cita\n---\nTexto") == "cita Texto"
    end

    test "flattens tables by dropping pipes" do
      assert SpeechText.clean("| a | b |\n|---|---|\n| 1 | 2 |") == "a b 1 2"
    end

    test "collapses whitespace into one flowing line" do
      assert SpeechText.clean("Hola\n\n   mundo   \n\tancho") == "Hola mundo ancho"
    end

    test "trims the result" do
      assert SpeechText.clean("  **hola**  ") == "hola"
    end
  end

  describe "clean/1 numbers" do
    test "removes comma thousands separators (English convention)" do
      assert SpeechText.clean("hay 1,234 casas") == "hay 1234 casas"
      assert SpeechText.clean("1,234,567 personas") == "1234567 personas"
      assert SpeechText.clean("1,234.56 dólares") == "1234.56 dólares"
    end

    test "removes dot thousands separators (Spanish convention)" do
      assert SpeechText.clean("1.234 habitantes") == "1234 habitantes"
      assert SpeechText.clean("1.234.567 habitantes") == "1234567 habitantes"
      assert SpeechText.clean("cuesta 1.234,56 euros") == "cuesta 1234 coma 56 euros"
    end

    test "still spells tight decimal commas out loud" do
      assert SpeechText.clean("Buenos Aires hace 12,6 grados") ==
               "Buenos Aires hace 12 coma 6 grados"

      assert SpeechText.clean("12,6 °C y 36,5% de humedad") ==
               "12 coma 6 grados y 36 coma 5 porciento de humedad"

      assert SpeechText.clean("pi vale 3,1416") == "pi vale 3 coma 1416"
    end

    test "leaves short numeric groups that are not thousands untouched" do
      assert SpeechText.clean("los años 2020, 2021 y 1, 2, 3") ==
               "los años 2020, 2021 y 1, 2, 3"

      assert SpeechText.clean("versión 1.2 salió") == "versión 1.2 salió"

      assert SpeechText.clean("Buenos Aires hace 12.6 grados") ==
               "Buenos Aires hace 12.6 grados"
    end
  end

  describe "clean/1 symbols" do
    test "removes emoji that TTS reads out loud" do
      assert SpeechText.clean("Buenos días \u{1F600} ¡vamos!") == "Buenos días ¡vamos!"
      assert SpeechText.clean("Hace sol \u{2600} hoy") == "Hace sol hoy"
      assert SpeechText.clean("\u{1F1EA}\u{1F1F8} España") == "España"
    end

    test "translates meaningful arrows into words" do
      assert SpeechText.clean("Madrid → Toledo") == "Madrid va a Toledo"
      assert SpeechText.clean("siguiente -> paso") == "siguiente va a paso"
      assert SpeechText.clean("la temperatura ↑") == "la temperatura sube"
      assert SpeechText.clean("la temperatura ↓") == "la temperatura baja"
      assert SpeechText.clean("luego ⇒ fin") == "luego entonces fin"
    end

    test "translates circled and parenthesized digits" do
      assert SpeechText.clean("\u{2460} primero") == "(1) primero"
      assert SpeechText.clean("\u{2462} tercero") == "(3) tercero"
      assert SpeechText.clean("\u{246B} duodécimo") == "(12) duodécimo"
      assert SpeechText.clean("\u{2474} con paréntesis") == "(1) con paréntesis"
    end

    test "reduces keycap sequences to their digit" do
      assert SpeechText.clean("pulsa 1\u{FE0F}\u{20E3} para continuar") ==
               "pulsa 1 para continuar"
    end

    test "deletes decorative symbols that remain unmapped" do
      assert SpeechText.clean("\u{2713} hecho \u{2B50}") == "hecho"
      assert SpeechText.clean("\u{2192} la respuesta \u{2713}") == "va a la respuesta"
    end
  end

  describe "clean/1 unit symbols" do
    test "translates unpronounceable unit symbols into Spanish words" do
      assert SpeechText.clean("Buenos Aires hace 12.6 °C, humedad 36%") ==
               "Buenos Aires hace 12.6 grados, humedad 36 porciento"

      assert SpeechText.clean("Máximo de 30°C y 80 % de humedad") ==
               "Máximo de 30 grados y 80 porciento de humedad"

      assert SpeechText.clean("viento a 11.8 km/h") == "viento a 11.8 kilómetros por hora"
      assert SpeechText.clean("corrió a 14 kmh") == "corrió a 14 kilómetros por hora"
    end

    test "handles unit symbol case variants" do
      assert SpeechText.clean("viento a 40 KM/H") == "viento a 40 kilómetros por hora"
      assert SpeechText.clean("corrió a 14 Kmh") == "corrió a 14 kilómetros por hora"
      assert SpeechText.clean("hace 30°c") == "hace 30 grados"
      assert SpeechText.clean("hace 30°C") == "hace 30 grados"
    end

    test "spells out a lone degree sign" do
      assert SpeechText.clean("gira 45° a la derecha") == "gira 45 grados a la derecha"
    end

    test "keeps the masculine ordinal indicator" do
      assert SpeechText.clean("quedó 1º del grupo") == "quedó 1º del grupo"
    end

    test "translates a stray percent sign not attached to a number" do
      assert SpeechText.clean("el % de votos") == "el porciento de votos"
    end
  end

  describe "clean/1 input handling" do
    test "leaves plain Spanish text and accented words untouched" do
      text = "Hoy hace un día hermoso en Madrid. ¿Qué más?"
      assert SpeechText.clean(text) == text
    end

    test "returns an empty string for non-binary input" do
      assert SpeechText.clean(nil) == ""
      assert SpeechText.clean(:error) == ""
      assert SpeechText.clean(%{a: 1}) == ""
      assert SpeechText.clean(42) == ""
    end
  end

  describe "clean/1 speakability guarantees" do
    test "cleaned output never contains unspeakable markup or symbols" do
      dirty = "**Hola** *mundo* `code` #tag 50% 30°C 1.234 → \u{1F600} 45° fin"
      result = SpeechText.clean(dirty)

      refute result =~ "*"
      refute result =~ "`"
      refute result =~ "#"
      refute result =~ "%"
      refute result =~ "°"
    end
  end
end
