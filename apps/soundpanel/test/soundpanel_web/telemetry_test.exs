defmodule SoundpanelWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias SoundpanelWeb.Telemetry

  describe "metrics/0" do
    test "defines phoenix endpoint metrics" do
      names = Enum.map(Telemetry.metrics(), & &1.name)

      assert [:phoenix, :endpoint, :stop, :duration] in names
      assert [:phoenix, :endpoint, :start, :system_time] in names
    end

    test "defines router dispatch metrics" do
      names = Enum.map(Telemetry.metrics(), & &1.name)

      assert [:phoenix, :router_dispatch, :stop, :duration] in names
      assert [:phoenix, :router_dispatch, :exception, :duration] in names
    end

    test "defines vm metrics" do
      names = Enum.map(Telemetry.metrics(), & &1.name)

      assert [:vm, :memory, :total] in names
      assert [:vm, :total_run_queue_lengths, :total] in names
    end
  end
end
