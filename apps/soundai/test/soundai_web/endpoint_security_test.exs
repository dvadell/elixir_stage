defmodule SoundaiWeb.EndpointSecurityTest do
  # Mutates nothing, but the beam introspection below assumes the test-env
  # compilation (no code reloading); keep it serialized for clarity.
  use SoundaiWeb.ConnCase, async: false

  @request_logger :"Elixir.Phoenix.LiveDashboard.RequestLogger"

  describe "session signing salt" do
    test "comes exclusively from configuration and signs real sessions" do
      # The :browser pipeline runs fetch_session through Plug.Session, which
      # resolves the signing salt from application env at runtime.
      conn = get(build_conn(), "/")
      assert conn.status == 200

      salt =
        :soundai
        |> Application.fetch_env!(SoundaiWeb.Endpoint)
        |> Keyword.fetch!(:signing_salt)

      # A usable salt is at least 8 characters (Phoenix generator convention).
      assert byte_size(salt) >= 8
    end
  end

  describe "RequestLogger" do
    test "is compiled out of the pipeline when code reloading is disabled" do
      config = Application.get_env(:soundai, SoundaiWeb.Endpoint) || []
      refute Keyword.get(config, :code_reloader, false)

      refute @request_logger in endpoint_atoms(),
             "Phoenix.LiveDashboard.RequestLogger must only be plugged behind code_reloading?"
    end
  end

  defp endpoint_atoms do
    # Resolve the compiled beam explicitly: `:code.which/1` lies when the
    # module is cover-compiled (`mix test --cover`), pointing at a
    # non-existent "cover_compiled.beam", while the build's ebin always has
    # the real one.
    beam =
      [Application.app_dir(:soundai), "ebin", "Elixir.SoundaiWeb.Endpoint.beam"]
      |> Path.join()
      |> String.to_charlist()

    case :beam_lib.chunks(beam, [:atoms]) do
      {:ok, {_module, chunks}} ->
        chunks |> List.keyfind(:atoms, 0) |> elem(1)

      {:error, reason} ->
        flunk("could not read endpoint beam atoms: #{inspect(reason)}")
    end
  end
end
