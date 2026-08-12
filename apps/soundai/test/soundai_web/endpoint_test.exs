defmodule SoundaiWeb.EndpointTest do
  use SoundaiWeb.ConnCase, async: true

  test "serves cross-origin isolation headers so WASM Whisper can use threads", %{conn: conn} do
    conn = get(conn, "/")

    assert conn.status == 200
    assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(conn, "cross-origin-embedder-policy") == ["credentialless"]
  end
end
