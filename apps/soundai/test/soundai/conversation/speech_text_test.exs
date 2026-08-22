defmodule Soundai.Conversation.SpeechTextTest do
  use ExUnit.Case, async: true

  alias Soundai.Conversation.SpeechText

  describe "clean/1" do
    test "strips bold and italic markers" do
      assert SpeechText.clean("**Hola** y *buenos* días") == "Hola y buenos días"
      assert SpeechText.clean("__Hola__ y _buenos_ días") == "Hola y buenos días"
      assert SpeechText.clean("***Muy importante***") == "Muy importante"
    end

    test "keeps snake_case identifiers intact while stripping emphasis underscores" do
      assert SpeechText.clean("el campo _temperatura_ es temperature_2m") ==
               "el campo temperatura es temperature_2m"
    end

    test "removes headers" do
      assert SpeechText.clean("## El tiempo\nEstá soleado") == "El tiempo Está soleado"
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

    test "removes code fences and inline backticks" do
      assert SpeechText.clean("```elixir\n1 + 1\n```\nListo") == "1 + 1 Listo"
      assert SpeechText.clean("usa `mix test` para probar") == "usa mix test para probar"
    end

    test "removes blockquotes and horizontal rules" do
      assert SpeechText.clean("> cita\n---\nTexto") == "cita Texto"
    end

    test "flattens tables by dropping pipes" do
      assert SpeechText.clean("| a | b |\n|---|---|\n| 1 | 2 |") == "a b 1 2"
    end

    test "removes emoji and symbols that TTS reads out loud" do
      assert SpeechText.clean("Buenos días \u{1F600} ¡vamos!") == "Buenos días ¡vamos!"
      assert SpeechText.clean("\u{2192} la respuesta \u{2713}") == "la respuesta"
    end

    test "collapses whitespace into one flowing line" do
      assert SpeechText.clean("Hola\n\n   mundo   \n\tancho") == "Hola mundo ancho"
    end

    test "translates unpronounceable unit symbols into Spanish words" do
      assert SpeechText.clean("Buenos Aires hace 12.6 °C, humedad 36%") ==
               "Buenos Aires hace 12.6 grados, humedad 36 porciento"

      assert SpeechText.clean("Máximo de 30°C y 80 % de humedad") ==
               "Máximo de 30 grados y 80 porciento de humedad"

      assert SpeechText.clean("viento a 11.8 km/h") == "viento a 11.8 kilómetros por hora"
      assert SpeechText.clean("corrió a 14 kmh") == "corrió a 14 kilómetros por hora"
    end

    test "spells decimal commas out loud" do
      assert SpeechText.clean("Buenos Aires hace 12,6 grados") ==
               "Buenos Aires hace 12 coma 6 grados"

      assert SpeechText.clean("12,6 °C y 36,5% de humedad") ==
               "12 coma 6 grados y 36 coma 5 porciento de humedad"
    end

    test "keeps list commas (digit, space) untouched" do
      assert SpeechText.clean("los años 2020, 2021 y 1, 2, 3") ==
               "los años 2020, 2021 y 1, 2, 3"
    end

    test "leaves plain Spanish text and accented words untouched" do
      text = "Hoy hace un día hermoso en Madrid. ¿Qué más?"
      assert SpeechText.clean(text) == text
    end

    test "trims the result" do
      assert SpeechText.clean("  **hola**  ") == "hola"
    end

    test "passes non-binary values through" do
      assert SpeechText.clean(nil) == nil
      assert SpeechText.clean(%{a: 1}) == %{a: 1}
    end
  end
end
