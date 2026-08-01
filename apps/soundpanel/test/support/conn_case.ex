defmodule SoundpanelWeb.ConnCase do
  @moduledoc """
  Sets up test cases that need an HTTP connection.

  Uses `Phoenix.ConnTest` for building connections and queries the data layer.
  Enables the SQL sandbox so changes are reverted at the end of every test.
  For PostgreSQL, you can run database tests asynchronously by setting
  `use SoundpanelWeb.ConnCase, async: true`.
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

  setup tags do
    Soundpanel.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
