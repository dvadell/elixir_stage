defmodule SoundaiWeb.ConnCase do
  @moduledoc """
  Defines the test case for tests requiring a connection.

  Uses `Phoenix.ConnTest` and imports helpers for building connections
  and querying the data layer. Database interactions are wrapped in an
  SQL sandbox that reverts changes after each test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SoundaiWeb.Endpoint

      use SoundaiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SoundaiWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
