defmodule Soundai.Conversation.Tools.Weather do
  @max_forecast_days 16

  @moduledoc """
  LLM tool: current weather and daily forecasts for a place, powered by
  [Open-Meteo](https://open-meteo.com) (free, no API key).

  `tool/0` builds the `ReqLLM.Tool` handed to the LLM; given a place name, the
  callback geocodes it through Open-Meteo's geocoding API; given numeric
  `latitude`/`longitude` (typically the user's geolocation relayed in the
  system prompt), it uses them directly. Without a `date`, the current
  conditions are fetched from Open-Meteo's forecast API. With a `date`
  (`YYYY-MM-DD`, today or up to #{@max_forecast_days} days ahead) the tool
  returns that day's daily forecast instead, so questions like "¿qué tiempo
  hará mañana?" or "¿cómo va a estar la humedad el domingo próximo?" work.
  The result is a short Spanish, voice-friendly summary that the assistant can
  speak as-is.

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

  @daily_variables ~W(
    temperature_2m_max
    temperature_2m_min
    apparent_temperature_max
    apparent_temperature_min
    relative_humidity_2m_mean
    precipitation_sum
    precipitation_probability_max
    weather_code
    wind_speed_10m_max
  )

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

  @days ~W(lunes martes miércoles jueves viernes sábado domingo)
  @months ~W(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre)

  @doc """
  Builds the `get_weather` tool for the LLM.
  """
  @spec tool() :: ReqLLM.Tool.t()
  def tool do
    ReqLLM.Tool.new!(
      name: "get_weather",
      description:
        "Obtiene el tiempo actual o la previsión diaria de una ciudad o lugar, o de la " <>
          "ubicación del usuario. Úsala cuando el usuario pregunte por el clima, la " <>
          "temperatura o la humedad. Para el tiempo de ahora mismo llama sin fecha. " <>
          "Para hoy en general o para otro día futuro (mañana, el domingo próximo...), " <>
          "pasa su fecha concreta calculada con la fecha actual incluida en el contexto " <>
          "del mensaje. Si el usuario pregunta por el tiempo en su propia ubicación, " <>
          "llama a la herramienta con las coordenadas de su sistema sin pedirle nada.",
      parameter_schema: %{
        type: "object",
        properties: %{
          location: %{
            type: "string",
            description: "Nombre del lugar, por ejemplo: Madrid"
          },
          latitude: %{
            type: "number",
            description: "Latitud del lugar; úsala (con longitude) para la ubicación del usuario"
          },
          longitude: %{
            type: "number",
            description: "Longitud del lugar; úsala (con latitude) para la ubicación del usuario"
          },
          date: %{
            type: "string",
            description:
              "Fecha opcional en formato AAAA-MM-DD para pedir la previsión de un día " <>
                "entero (hoy inclusive, hasta #{@max_forecast_days} días vista). Convierte " <>
                "fechas relativas como mañana o el domingo próximo usando la fecha actual " <>
                "del contexto. Omítela para el tiempo de ahora mismo."
          }
        },
        required: []
      },
      callback: &weather/1
    )
  end

  @doc """
  Tool callback: returns `{:ok, summary}` with either the current conditions
  (no usable `date`) or the requested day's daily forecast, or `{:error,
  reason}` when the place is unknown, the date is unusable or the service
  fails.

  Accepts either a place `location` name (geocoded first) or numeric
  `latitude`/`longitude` coordinates (used as-is); an explicit non-blank place
  name wins over coordinates. A blank `date` is treated as absent.
  """
  def weather(args) do
    case requested_date(args["date"]) do
      :current ->
        current(args)

      {:ok, date} ->
        args |> resolve_place() |> fetch_daily(date)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Current-conditions path of `weather/1`: returns `{:ok, summary}` with the
  conditions right now or `{:error, reason}` when the place is unknown or the
  service fails.

  Accepts either a place `location` name (geocoded first) or numeric
  `latitude`/`longitude` coordinates (used as-is); an explicit non-blank place
  name wins over coordinates.
  """
  def current(%{"location" => location} = args) when is_binary(location) do
    case String.trim(location) do
      "" ->
        # A blank name may accompany user coordinates; only complain about the
        # empty location when there is nothing else to go on.
        if valid_coordinates?(args) do
          current(Map.delete(args, "location"))
        else
          {:error, "empty location"}
        end

      place ->
        place |> geocode() |> fetch_forecast()
    end
  end

  def current(%{"latitude" => lat, "longitude" => lon} = args)
      when is_number(lat) and is_number(lon) do
    if valid_coordinates?(args) do
      place = %{label: "En tu zona", latitude: lat, longitude: lon}
      fetch_forecast({:ok, place})
    else
      {:error, "invalid arguments"}
    end
  end

  def current(_args), do: {:error, "invalid arguments"}

  # ------------------------------------------------------------------- dates

  defp requested_date(nil), do: :current

  defp requested_date(date) when is_binary(date) do
    trimmed = String.trim(date)

    if trimmed == "" do
      :current
    else
      case Date.from_iso8601(trimmed) do
        {:ok, day} -> validate_date(day)
        {:error, _} -> {:error, "invalid date '#{trimmed}', expected format YYYY-MM-DD"}
      end
    end
  end

  defp requested_date(_other), do: {:error, "invalid date"}

  # The server clock is UTC while users may sit hours away from it, so one day
  # of grace is allowed on each side of the supported range.
  defp validate_date(day) do
    diff = Date.diff(day, Date.utc_today())

    cond do
      diff < -1 -> {:error, "date in the past"}
      diff > @max_forecast_days - 1 -> {:error, "date beyond the forecast range"}
      true -> {:ok, day}
    end
  end

  # ------------------------------------------------------------- places / api

  defp resolve_place(%{"location" => location} = args) when is_binary(location) do
    case String.trim(location) do
      "" ->
        if valid_coordinates?(args),
          do: resolve_place(Map.delete(args, "location")),
          else: {:error, "empty location"}

      place ->
        geocode(place)
    end
  end

  defp resolve_place(%{"latitude" => lat, "longitude" => lon})
       when is_number(lat) and is_number(lon) do
    if valid_coordinates?(%{"latitude" => lat, "longitude" => lon}) do
      {:ok, %{label: "En tu zona", latitude: lat, longitude: lon}}
    else
      {:error, "invalid arguments"}
    end
  end

  defp resolve_place(_args), do: {:error, "invalid arguments"}

  defp valid_coordinates?(%{"latitude" => lat, "longitude" => lon})
       when is_number(lat) and is_number(lon),
       do: lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180

  defp valid_coordinates?(_args), do: false

  defp geocode(place) do
    case request(@geocoding_url, name: place, count: 1, language: "es", format: "json") do
      {:ok, %{"results" => [first | _]}} ->
        {:ok,
         %{
           label: "#{first["name"]}, #{first["country"]}",
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

  defp fetch_daily({:error, reason}, _date), do: {:error, reason}

  defp fetch_daily({:ok, place}, date) do
    iso = Date.to_iso8601(date)

    params =
      [
        latitude: place.latitude,
        longitude: place.longitude,
        daily: Enum.join(@daily_variables, ","),
        start_date: iso,
        end_date: iso,
        timezone: "auto"
      ]

    case request(@forecast_url, params) do
      {:ok, %{"daily" => daily}} ->
        summarize_day(place, date, daily)

      {:ok, body} ->
        {:error, "unexpected forecast response: #{inspect(keys(body))}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------- summaries

  defp summarize(place, current) do
    temperature = current["temperature_2m"]
    feels_like = current["apparent_temperature"]
    humidity = current["relative_humidity_2m"]
    wind = current["wind_speed_10m"]

    conditions =
      Map.get(@weather_codes, current["weather_code"], "condición desconocida")

    "#{place.label}: #{temperature} grados, #{conditions}. " <>
      "Sensación térmica #{feels_like} grados, humedad #{humidity} porciento, " <>
      "viento #{wind} kilómetros por hora."
  end

  # "Hoy en Madrid, España: nublado. Máxima 33 grados, mínima 20 grados. ..."
  defp summarize_day(place, date, daily) do
    max_temp = value(daily, "temperature_2m_max")
    min_temp = value(daily, "temperature_2m_min")

    if is_number(max_temp) and is_number(min_temp) do
      conditions =
        Map.get(@weather_codes, value(daily, "weather_code"), "condición desconocida")

      details =
        Enum.reject(
          [
            feels_like_text(
              value(daily, "apparent_temperature_min"),
              value(daily, "apparent_temperature_max")
            ),
            humidity_text(value(daily, "relative_humidity_2m_mean")),
            wind_text(value(daily, "wind_speed_10m_max")),
            rain_text(
              value(daily, "precipitation_sum"),
              value(daily, "precipitation_probability_max")
            )
          ],
          &is_nil/1
        )

      summary =
        Enum.join(
          [
            "#{day_label(date)} en #{place.label}: #{conditions}. Máxima #{num(max_temp)} " <>
              "grados, mínima #{num(min_temp)} grados."
            | details
          ],
          " "
        )

      {:ok, summary}
    else
      {:error, "unexpected daily forecast response"}
    end
  end

  defp feels_like_text(min, max) when is_number(min) and is_number(max),
    do: "Sensación térmica entre #{num(min)} y #{num(max)} grados."

  defp feels_like_text(_min, _max), do: nil

  defp humidity_text(humidity) when is_number(humidity),
    do: "Humedad media #{num(humidity)} porciento."

  defp humidity_text(_humidity), do: nil

  defp wind_text(wind) when is_number(wind),
    do: "Viento hasta #{num(wind)} kilómetros por hora."

  defp wind_text(_wind), do: nil

  defp rain_text(precipitation, probability) do
    rainy? = is_number(precipitation) and precipitation > 0
    likely? = is_number(probability) and probability > 0

    cond do
      rainy? and likely? ->
        "Probabilidad de lluvia #{num(probability)} porciento, " <>
          "con #{mm(precipitation)} milímetros previstos."

      likely? ->
        "Probabilidad de lluvia #{num(probability)} porciento."

      rainy? ->
        "Se esperan #{mm(precipitation)} milímetros de precipitación."

      true ->
        "Sin lluvia prevista."
    end
  end

  # "Hoy", "Mañana", or "El domingo 30 de agosto".
  defp day_label(date) do
    today = Date.utc_today()

    cond do
      Date.compare(date, today) == :eq -> "Hoy"
      Date.compare(date, Date.add(today, 1)) == :eq -> "Mañana"
      true -> "El #{day_name(Date.day_of_week(date))} #{date.day} de #{month_name(date.month)}"
    end
  end

  # Whole degrees read best through TTS.
  defp num(value) when is_integer(value), do: Integer.to_string(value)

  defp num(value) when is_float(value),
    do: value |> Float.round() |> trunc() |> Integer.to_string()

  # One decimal, comma-separated so SpeechText.clean spells it out loud ("1 coma 1").
  defp mm(value) when is_number(value) do
    rounded = Float.round(value * 1.0, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      rounded
      |> :erlang.float_to_binary(decimals: 1)
      |> String.replace(".", ",")
    end
  end

  defp value(map, key), do: map |> Map.get(key) |> List.wrap() |> Enum.at(0)

  defp day_name(index) when index in 1..7, do: Enum.at(@days, index - 1)
  defp month_name(index) when index in 1..12, do: Enum.at(@months, index - 1)

  # ------------------------------------------------------------------ request

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
