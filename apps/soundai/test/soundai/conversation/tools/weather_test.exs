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
    test "builds the get_weather tool with a location parameter" do
      tool = Weather.tool()

      assert %ReqLLM.Tool{name: "get_weather"} = tool
      assert %{properties: %{location: _}, required: ["location"]} = tool.parameter_schema
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

  defp fetch_params(conn) do
    conn |> Plug.Conn.fetch_query_params() |> Map.fetch!(:params)
  end
end
