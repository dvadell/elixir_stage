defmodule SoundpanelWeb.ShareControllerTest do
  use SoundpanelWeb.ConnCase

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("share-test-" <> Integer.to_string(System.unique_integer([:positive])))

    File.write!(tmp, <<0x1A, 0x45, 0xDF, 0xA3>>)
    on_exit(fn -> File.rm(tmp) end)
    %{tmp: tmp}
  end

  test "GET /share redirects to the soundboard", %{conn: conn} do
    conn = get(conn, ~p"/share")
    assert redirected_to(conn) == "/soundboard.html"
  end

  test "POST /share without files redirects to the soundboard", %{conn: conn} do
    conn = post(conn, ~p"/share", %{})
    assert redirected_to(conn) == "/soundboard.html"
  end

  test "POST /share with an audio file embeds it for the client", %{conn: conn, tmp: tmp} do
    conn =
      post(conn, ~p"/share",
        files: %Plug.Upload{path: tmp, filename: "hello.mp3", content_type: "audio/mpeg"}
      )

    body = html_response(conn, 200)
    assert body =~ "hello.mp3"
    assert body =~ "audio/mpeg"
    assert body =~ "GkXfow=="
  end

  test "POST /share infers a mime type when shared as octet-stream", %{conn: conn, tmp: tmp} do
    conn =
      post(conn, ~p"/share",
        files: %Plug.Upload{
          path: tmp,
          filename: "voice.wav",
          content_type: "application/octet-stream"
        }
      )

    assert html_response(conn, 200) =~ "audio/wav"
  end

  test "POST /share supports multiple files", %{conn: conn, tmp: tmp} do
    conn =
      post(conn, ~p"/share",
        files: [
          %Plug.Upload{path: tmp, filename: "one.mp3", content_type: "audio/mpeg"},
          %Plug.Upload{path: tmp, filename: "two.mp3", content_type: "audio/mpeg"}
        ]
      )

    body = html_response(conn, 200)
    assert body =~ "one.mp3"
    assert body =~ "two.mp3"
  end
end
