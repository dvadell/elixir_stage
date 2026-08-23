defmodule Soundai.Conversation.Tools.WeatherTest do
  use ExUnit.Case, async: false

  alias Soundai.Conversation.Tools.Weather

  @geocoding %{
    "results" => [
      %{
        "name" => "Madrid",
        "country" => "España",
        "latitude" => 40.4168,
        "longitude" => -3.7038
      }
    ]
  }

  @forecast_current %{
    "time" => "2026-08-22T12:00",
    "temperature_2m" => 21.3,
    "apparent_temperature" => 20.1,
    "relative_humidity_2m" => 40,
    "weather_code" => 0,
    "wind_speed_10m" => 8.2
  }

  setup do
    previous = Application.get_env(:soundai, Weather)

    Application.put_env(:soundai, Weather,
      req_options: [plug: {Req.Test, __MODULE__}],
      timeout_ms: 100
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:soundai, Weather, previous)
      else
        Application.delete_env(:soundai, Weather)
      end
    end)

    :ok
  end

  describe "tool/0" do
    test "builds the get_weather tool with optional place or coordinates parameters" do
      tool = Weather.tool()

      assert %ReqLLM.Tool{name: "get_weather"} = tool

      assert %{
               properties: %{location: _, latitude: _, longitude: _, date: _},
               required: []
             } = tool.parameter_schema
    end

    test "executes end-to-end through ReqLLM.Tool.execute/2" do
      expect_geocode()
      expect_forecast()

      assert {:ok, summary} = ReqLLM.Tool.execute(Weather.tool(), %{"location" => "Madrid"})
      assert summary =~ "Madrid, España"
      assert summary =~ "21.3 grados"
      assert summary =~ "cielo despejado"
      assert summary =~ "Sensación térmica 20.1 grados"
      assert summary =~ "humedad 40 porciento"
      assert summary =~ "viento 8.2 kilómetros por hora"
    end

    test "rejects input missing the location parameter" do
      assert {:error, "invalid arguments"} = ReqLLM.Tool.execute(Weather.tool(), %{})
    end
  end

  describe "current/1" do
    test "returns a Spanish, voice-friendly summary" do
      expect_geocode()
      expect_forecast()

      assert {:ok, summary} = Weather.current(%{"location" => "Madrid"})

      assert summary ==
               "Madrid, España: 21.3 grados, cielo despejado. " <>
                 "Sensación térmica 20.1 grados, humedad 40 porciento, " <>
                 "viento 8.2 kilómetros por hora."
    end

    test "maps unknown weather codes to a safe fallback description" do
      expect_geocode()
      expect_forecast(weather_code: 1234)

      assert {:ok, summary} = Weather.current(%{"location" => "Madrid"})
      assert summary =~ "condición desconocida"
    end

    test "errors when the place cannot be geocoded" do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:error, "no results for \"Nowhere\""} =
               Weather.current(%{"location" => " Nowhere "})
    end

    test "errors when the geocoder fails" do
      Req.Test.expect(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, "HTTP 500"} = Weather.current(%{"location" => "Madrid"})
    end

    test "errors when the forecast request fails" do
      expect_geocode()

      Req.Test.expect(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end)

      assert {:error, "HTTP 503"} = Weather.current(%{"location" => "Madrid"})
    end

    test "errors on transport failure" do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Weather.current(%{"location" => "Madrid"})
    end

    test "rejects blank locations without an HTTP call" do
      assert Weather.current(%{"location" => "   "}) == {:error, "empty location"}
      refute_received _
    end

    test "rejects invalid arguments" do
      assert Weather.current(%{}) == {:error, "invalid arguments"}
      assert Weather.current(%{"location" => 42}) == {:error, "invalid arguments"}
      refute_received _
    end
  end

  describe "current/1 with user coordinates" do
    test "skips geocoding and forecasts the coordinates directly" do
      expect_forecast()

      assert {:ok, summary} =
               Weather.current(%{"latitude" => 40.4168, "longitude" => -3.7038})

      assert String.starts_with?(summary, "En tu zona: 21.3 grados")
      assert summary =~ "cielo despejado"
    end

    test "executes coordinates through ReqLLM.Tool.execute/2" do
      expect_forecast()

      assert {:ok, summary} =
               ReqLLM.Tool.execute(Weather.tool(), %{
                 "latitude" => 40.4168,
                 "longitude" => -3.7038
               })

      assert summary =~ "En tu zona"
    end

    test "a non-blank place name wins over coordinates" do
      expect_geocode()
      expect_forecast()

      assert {:ok, summary} =
               Weather.current(%{
                 "location" => "Madrid",
                 "latitude" => 40.4168,
                 "longitude" => -3.7038
               })

      assert summary =~ "Madrid, España"
    end

    test "a blank place name falls back to coordinates" do
      expect_forecast()

      assert {:ok, summary} =
               Weather.current(%{
                 "location" => "  ",
                 "latitude" => 40.4168,
                 "longitude" => -3.7038
               })

      assert summary =~ "En tu zona"
    end

    test "rejects out-of-range coordinates" do
      assert Weather.current(%{"latitude" => 120.0, "longitude" => -3.0}) ==
               {:error, "invalid arguments"}

      assert Weather.current(%{"latitude" => 40.0, "longitude" => "west"}) ==
               {:error, "invalid arguments"}

      refute_received _
    end

    test "errors when only a blank location and no coordinates are given" do
      assert Weather.current(%{"location" => ""}) == {:error, "empty location"}
      refute_received _
    end
  end

  describe "weather/1 with a date" do
    test "returns the daily forecast for a future day" do
      date = Date.add(Date.utc_today(), 2)
      iso = Date.to_iso8601(date)
      expect_geocode()
      expect_daily_forecast(iso)

      assert {:ok, summary} = Weather.weather(%{"location" => "Madrid", "date" => iso})

      assert summary ==
               "El #{day_name(date)} #{date.day} de #{month_name(date)} en Madrid, España: " <>
                 "chubascos ligeros. Máxima 26 grados, mínima 18 grados. " <>
                 "Sensación térmica entre 18 y 25 grados. Humedad media 49 porciento. " <>
                 "Viento hasta 23 kilómetros por hora. " <>
                 "Probabilidad de lluvia 55 porciento, con 1,1 milímetros previstos."
    end

    test "labels today's forecast as hoy" do
      iso = Date.to_iso8601(Date.utc_today())
      expect_geocode()
      expect_daily_forecast(iso)

      assert {:ok, summary} = Weather.weather(%{"location" => "Madrid", "date" => iso})
      assert String.starts_with?(summary, "Hoy en Madrid, España:")
    end

    test "labels tomorrow's forecast as mañana" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))
      expect_geocode()
      expect_daily_forecast(iso)

      assert {:ok, summary} = Weather.weather(%{"location" => "Madrid", "date" => iso})
      assert String.starts_with?(summary, "Mañana en Madrid, España:")
    end

    test "accepts the last day of the forecast range without coordinates lookup" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), 15))
      expect_daily_forecast(iso)

      assert {:ok, summary} =
               Weather.weather(%{
                 "latitude" => 40.4168,
                 "longitude" => -3.7038,
                 "date" => iso
               })

      assert summary =~ "En tu zona"
    end

    test "executes a dated query through ReqLLM.Tool.execute/2" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), 3))
      expect_geocode()
      expect_daily_forecast(iso)

      assert {:ok, summary} =
               ReqLLM.Tool.execute(Weather.tool(), %{"location" => "Madrid", "date" => iso})

      assert summary =~ "Máxima 26 grados"
    end

    test "a blank date falls back to current conditions" do
      expect_geocode()
      expect_forecast()

      assert {:ok, summary} = Weather.weather(%{"location" => "Madrid", "date" => "   "})
      assert summary =~ "21.3 grados"
    end

    test "rejects malformed dates without an HTTP call" do
      assert {:error, reason} = Weather.weather(%{"location" => "Madrid", "date" => "23/08/2026"})
      assert reason == "invalid date '23/08/2026', expected format YYYY-MM-DD"

      assert {:error, _reason} = Weather.weather(%{"location" => "Madrid", "date" => "mañana"})
      assert {:error, _reason} = Weather.weather(%{"location" => "Madrid", "date" => 42})

      refute_received _
    end

    test "rejects past dates without an HTTP call" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), -2))

      assert Weather.weather(%{"location" => "Madrid", "date" => iso}) ==
               {:error, "date in the past"}

      refute_received _
    end

    test "rejects dates beyond the forecast range without an HTTP call" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), 16))

      assert Weather.weather(%{"location" => "Madrid", "date" => iso}) ==
               {:error, "date beyond the forecast range"}

      refute_received _
    end

    test "errors on an unexpected daily payload" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))
      expect_geocode()

      Req.Test.expect(__MODULE__, fn conn ->
        assert %{"start_date" => ^iso, "end_date" => ^iso} = fetch_params(conn)
        Req.Test.json(conn, %{"daily" => %{"time" => [iso]}})
      end)

      assert Weather.weather(%{"location" => "Madrid", "date" => iso}) ==
               {:error, "unexpected daily forecast response"}
    end

    test "errors when the daily forecast request fails" do
      iso = Date.to_iso8601(Date.add(Date.utc_today(), 1))
      expect_geocode()

      Req.Test.expect(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, "HTTP 500"} = Weather.weather(%{"location" => "Madrid", "date" => iso})
    end
  end

  defp expect_geocode do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/search"
      assert %{"name" => "Madrid", "count" => "1"} = fetch_params(conn)
      Req.Test.json(conn, @geocoding)
    end)
  end

  defp expect_forecast(opts \\ []) do
    current = Map.put(@forecast_current, "weather_code", Keyword.get(opts, :weather_code, 0))

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/forecast"

      assert %{
               "latitude" => "40.4168",
               "longitude" => "-3.7038",
               "current" => current_param,
               "timezone" => "auto"
             } = fetch_params(conn)

      assert String.contains?(current_param, "temperature_2m")
      Req.Test.json(conn, %{"current" => current})
    end)
  end

  @daily_variables ~W(
    temperature_2m_max temperature_2m_min apparent_temperature_max apparent_temperature_min
    relative_humidity_2m_mean precipitation_sum precipitation_probability_max weather_code
    wind_speed_10m_max
  )

  defp expect_daily_forecast(iso) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/forecast"

      assert %{
               "latitude" => "40.4168",
               "longitude" => "-3.7038",
               "daily" => daily_param,
               "start_date" => ^iso,
               "end_date" => ^iso,
               "timezone" => "auto"
             } = fetch_params(conn)

      Enum.each(@daily_variables, fn variable ->
        assert String.contains?(daily_param, variable)
      end)

      Req.Test.json(conn, %{
        "daily" => %{
          "time" => [iso],
          "temperature_2m_max" => [26.4],
          "temperature_2m_min" => [17.9],
          "apparent_temperature_max" => [25.1],
          "apparent_temperature_min" => [18.2],
          "relative_humidity_2m_mean" => [49],
          "precipitation_sum" => [1.1],
          "precipitation_probability_max" => [55],
          "weather_code" => [80],
          "wind_speed_10m_max" => [22.9]
        }
      })
    end)
  end

  defp day_name(date),
    do:
      Enum.at(
        ~W(lunes martes miércoles jueves viernes sábado domingo),
        Date.day_of_week(date) - 1
      )

  defp month_name(date),
    do:
      Enum.at(
        ~W(enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre),
        date.month - 1
      )

  defp fetch_params(conn) do
    conn |> Plug.Conn.fetch_query_params() |> Map.fetch!(:params)
  end
end
