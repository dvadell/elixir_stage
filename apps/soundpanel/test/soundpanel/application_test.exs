defmodule Soundpanel.ApplicationTest do
  use ExUnit.Case, async: true

  alias Soundpanel.Application

  test "config_change reloads the endpoint configuration" do
    assert :ok = Application.config_change([], [], [])
  end

  test "config_change with changes reloads the endpoint" do
    assert :ok = Application.config_change([SoundpanelWeb.Endpoint], [], [])
  end
end
