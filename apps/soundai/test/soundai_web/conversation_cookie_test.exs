defmodule SoundaiWeb.ConversationCookieTest do
  # Overrides the endpoint's application env in some tests.
  use SoundaiWeb.ConnCase, async: false

  alias Soundai.Conversation.LLM.FakeAdapter

  setup do
    previous = Application.get_env(:soundai, Soundai.Conversation)

    Application.put_env(:soundai, Soundai.Conversation,
      adapter: FakeAdapter,
      fake_capture_pid: self()
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:soundai, Soundai.Conversation, previous)
      else
        Application.delete_env(:soundai, Soundai.Conversation)
      end
    end)

    :ok
  end

  defp post_json(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/transcriptions", Jason.encode!(params))
  end

  defp with_endpoint_url(url, fun) do
    original = Application.get_env(:soundai, SoundaiWeb.Endpoint)

    Application.put_env(
      :soundai,
      SoundaiWeb.Endpoint,
      Keyword.put(original || [], :url, url)
    )

    try do
      fun.()
    after
      if original do
        Application.put_env(:soundai, SoundaiWeb.Endpoint, original)
      else
        Application.delete_env(:soundai, SoundaiWeb.Endpoint)
      end
    end
  end

  describe "opts/0" do
    test "hardens the conversation cookie flags" do
      opts = SoundaiWeb.ConversationCookie.opts()

      assert Keyword.fetch!(opts, :http_only) == true
      assert Keyword.fetch!(opts, :same_site) == "Lax"
      assert Keyword.fetch!(opts, :max_age) == 60 * 60 * 24 * 7
      assert Keyword.fetch!(opts, :path) == "/"
    end

    test "secure flag follows the endpoint's configured URL scheme" do
      with_endpoint_url([host: "localhost", scheme: "https"], fn ->
        assert Keyword.fetch!(SoundaiWeb.ConversationCookie.opts(), :secure) == true
      end)

      with_endpoint_url([host: "localhost"], fn ->
        assert Keyword.fetch!(SoundaiWeb.ConversationCookie.opts(), :secure) == false
      end)
    end
  end

  describe "Set-Cookie flags on POST /api/transcriptions" do
    test "cookie is always HttpOnly and never Secure over plain http" do
      conn = post_json(build_conn(), %{"text" => "Hola"})
      assert conn.status == 201

      [set_cookie] = get_resp_header(conn, "set-cookie")
      assert set_cookie =~ "soundai_conversation="
      assert set_cookie =~ "HttpOnly"
      refute set_cookie =~ "; secure"
    end

    test "cookie carries Secure when the deployment serves HTTPS" do
      with_endpoint_url([host: "localhost", scheme: "https"], fn ->
        conn = post_json(build_conn(), %{"text" => "Hola"})
        assert conn.status == 201

        [set_cookie] = get_resp_header(conn, "set-cookie")
        assert set_cookie =~ "soundai_conversation="
        assert set_cookie =~ "HttpOnly"
        assert set_cookie =~ "; secure"
      end)
    end
  end
end
