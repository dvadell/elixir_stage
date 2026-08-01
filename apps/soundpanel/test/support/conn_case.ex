defmodule SoundpanelWeb.ConnCase do
  @moduledoc """
  Sets up test cases that need an HTTP connection.

  Uses `Phoenix.ConnTest` for building connections.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SoundpanelWeb.Endpoint

      use SoundpanelWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SoundpanelWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
