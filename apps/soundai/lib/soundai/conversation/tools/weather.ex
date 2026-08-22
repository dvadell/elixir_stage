defmodule Soundai.Conversation.Tools.Weather do
  @moduledoc """
  First LLM tool: current weather for a place, powered by
  [Open-Meteo](https://open-meteo.com) (free, no API key).

  `tool/0` builds the `ReqLLM.Tool` handed to the LLM; the callback geocodes
  the requested location through Open-Meteo's geocoding API and then fetches
  the current conditions from its forecast API. The result is a short Spanish,
  voice-friendly summary that the assistant can speak as-is.

  Failures return `{:error, reason}` so `branched_llm` injects the error into
  the conversation context and the LLM can tell the user in plain words.
  HTTP calls are bounded by `config :soundai, Soundai.Conversation.Tools.Weather`
  (`:timeout_ms`, default 5 s) to protect the overall 30 s reply budget; tests
  can inject a plug via `:req_options` (`plug: {Req.Test, MyMock}`).
  """

  require Logger

  alias Soundai.HttpClient

  @geocoding_url "https://geocoding-api.open-meteo.com/v1/search"
  @forecast_url "https://api.open-meteo.com/v1/forecast"

  @weather_codes %{
    0 => "cielo despejado",
    1 => "mayormente despejado",
    2 => "parcialmente nublado",
    3 => "nublado",
    45 => "niebla",
    48 => "niebla con escarcha",
    51 => "llovizna ligera",
    53 => "llovizna",
    55 => "llovizna intensa",
    56 => "llovizna helada",
    57 => "llovizna helada intensa",
    61 => "lluvia ligera",
    63 => "lluvia",
    65 => "lluvia intensa",
    66 => "lluvia helada",
    67 => "lluvia helada intensa",
    71 => "nevada ligera",
    73 => "nevada",
    75 => "nevada intensa",
    77 => "granos de nieve",
    80 => "chubascos ligeros",
    81 => "chubascos",
    82 => "chubascos violentos",
    85 => "chubascos de nieve",
    86 => "chubascos de nieve intensos",
    95 => "tormenta",
    96 => "tormenta con granizo",
    99 => "tormenta con granizo fuerte"
  }

  @doc """
  Builds the `get_weather` tool for the LLM.
  """
  @spec tool() :: ReqLLM.Tool.t()
  def tool do
    ReqLLM.Tool.new!(
      name: "get_weather",
      description:
        "Obtiene el tiempo actual de una ciudad o lugar. Úsala cuando el usuario " <>
          "pregunte por el clima o la temperatura.",
      parameter_schema: %{
        type: "object",
        properties: %{
          location: %{type: "string", description: "Nombre del lugar, por ejemplo: Madrid"}
        },
        required: ["location"]
      },
      callback: &current/1
    )
  end

  @doc """
  Tool callback: returns `{:ok, summary}` with the current conditions or
  `{:error, reason}` when the place is unknown or the service fails.
  """
  def current(%{"location" => location}) when is_binary(location) do
    case String.trim(location) do
      "" -> {:error, "empty location"}
      place -> place |> geocode() |> fetch_forecast()
    end
  end

  def current(_args), do: {:error, "invalid arguments"}

  defp geocode(place) do
    case request(@geocoding_url, name: place, count: 1, language: "es", format: "json") do
      {:ok, %{"results" => [first | _]}} ->
        {:ok,
         %{
           name: first["name"],
           country: first["country"],
           latitude: first["latitude"],
           longitude: first["longitude"]
         }}

      {:ok, _body} ->
        {:error, "no results for #{inspect(place)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_forecast({:error, reason}), do: {:error, reason}

  defp fetch_forecast({:ok, place}) do
    case request(
           @forecast_url,
           latitude: place.latitude,
           longitude: place.longitude,
           current:
             Enum.join(
               ~W(temperature_2m apparent_temperature relative_humidity_2m weather_code wind_speed_10m),
               ","
             ),
           timezone: "auto"
         ) do
      {:ok, %{"current" => current}} ->
        {:ok, summarize(place, current)}

      {:ok, body} ->
        {:error, "unexpected forecast response: #{inspect(keys(body))}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize(place, current) do
    temperature = current["temperature_2m"]
    feels_like = current["apparent_temperature"]
    humidity = current["relative_humidity_2m"]
    wind = current["wind_speed_10m"]

    conditions =
      Map.get(@weather_codes, current["weather_code"], "condición desconocida")

    "#{place.name}, #{place.country}: #{temperature} grados, #{conditions}. " <>
      "Sensación térmica #{feels_like} grados, humedad #{humidity} porciento, " <>
      "viento #{wind} kilómetros por hora."
  end

  defp request(url, params) do
    case HttpClient.get(req(), url: url, params: params, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, exception} -> {:error, exception}
    end
  rescue
    exception ->
      Logger.warning("Weather request failed: #{Exception.message(exception)}")
      {:error, "request failed"}
  end

  defp req do
    default = [
      receive_timeout: timeout_ms(),
      connect_options: [timeout: timeout_ms()]
    ]

    Keyword.merge(default, config(:req_options) || [])
    |> HttpClient.new()
  end

  defp timeout_ms, do: config(:timeout_ms) || 5_000

  defp keys(map) when is_map(map), do: Map.keys(map)
  defp keys(other), do: other

  defp config(key), do: Keyword.get(Application.get_env(:soundai, __MODULE__, []), key)
end
