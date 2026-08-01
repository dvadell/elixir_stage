# credo:disable-for-this-file OeditusCredo.Check.Security.MissingAuthentication
# This endpoint is Soundpanel's Android Web Share Target, which the OS must be
# able to reach without a session. The app has no accounts or authentication;
# sounds live in each device's IndexedDB, so the handler is public by design.
defmodule SoundpanelWeb.ShareController do
  use SoundpanelWeb, :controller

  @ext_mime_types %{
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".m4b" => "audio/mp4",
    ".aac" => "audio/aac",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".oga" => "audio/ogg",
    ".opus" => "audio/ogg",
    ".webm" => "audio/webm",
    ".flac" => "audio/flac",
    ".3gp" => "audio/3gpp",
    ".amr" => "audio/amr",
    ".caf" => "audio/x-caf"
  }

  @doc """
  GET /share — direct visits just land on the soundboard.
  """
  def index(conn, _params) do
    redirect(conn, to: "/soundboard.html")
  end

  @doc """
  POST /share — receives audio files shared from Android's share sheet
  (Web Share Target). Soundboard data lives in the browser's IndexedDB, so
  the files are embedded into a page that saves them client-side and then
  redirects to the board.
  """
  def create(conn, params) do
    case uploads(params) do
      [] ->
        redirect(conn, to: "/soundboard.html")

      files ->
        payload =
          Enum.map(files, fn upload ->
            data = File.read!(upload.path)
            type = audio_type(upload)

            %{
              name: upload.filename || "Shared sound",
              type: type,
              data: "data:" <> type <> ";base64," <> Base.encode64(data)
            }
          end)

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, share_page(payload))
    end
  end

  defp uploads(params) do
    case params["files"] do
      %Plug.Upload{} = upload ->
        [upload]

      files when is_list(files) ->
        Enum.flat_map(files, fn
          %Plug.Upload{} = upload -> [upload]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp audio_type(upload) do
    type = upload.content_type || ""

    if type in ["application/octet-stream", "application/unknown", ""] do
      type_from_extension(upload.filename) || "audio"
    else
      type
    end
  end

  defp type_from_extension(nil), do: nil

  defp type_from_extension(filename) do
    ext = filename |> Path.extname() |> String.downcase()
    Map.get(@ext_mime_types, ext)
  end

  defp share_page(payload) do
    json =
      payload
      |> Jason.encode!()
      |> String.replace(~r{</script}i, "<\\/script")

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="theme-color" content="#0b0e14" />
        <title>Soundpanel</title>
        <style>
          :root { color-scheme: dark; --bg: #0b0e14; --text: #f4f6fb; --text-dim: #96a1b5; }
          @media (prefers-color-scheme: light) {
            :root { color-scheme: light; --bg: #eef1f7; --text: #0f172a; --text-dim: #5b6b82; }
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          html, body { height: 100%; }
          body {
            display: grid;
            place-items: center;
            gap: 1rem;
            padding: 1rem;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background:
              radial-gradient(70rem 32rem at 115% -10%, rgba(124, 92, 255, 0.16), transparent 60%),
              radial-gradient(55rem 30rem at -15% 115%, rgba(34, 211, 238, 0.12), transparent 60%),
              var(--bg);
            color: var(--text);
            -webkit-font-smoothing: antialiased;
            text-align: center;
          }
          .spinner {
            width: 2.6rem;
            height: 2.6rem;
            border-radius: 50%;
            border: 3px solid rgba(124, 92, 255, 0.25);
            border-top-color: #7c5cff;
            animation: spin 0.8s linear infinite;
          }
          @keyframes spin { to { transform: rotate(360deg); } }
          p { font-size: 0.9rem; font-weight: 600; color: var(--text-dim); }
          @media (prefers-reduced-motion: reduce) { .spinner { animation: none; } }
        </style>
      </head>
      <body>
        <div class="spinner" role="status" aria-label="Adding sounds"></div>
        <p>Adding shared sound(s) to your board…</p>
        <script>
          window.__SHARED_SOUNDS = #{json};
          (function () {
            "use strict";
            var DB_NAME = "soundpanel";
            var DB_VERSION = 1;
            var STORE = "sounds";

            function uuid() {
              if (window.crypto && typeof crypto.randomUUID === "function") return crypto.randomUUID();
              return "s-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
            }

            function openDB() {
              return new Promise(function (resolve, reject) {
                var req = indexedDB.open(DB_NAME, DB_VERSION);
                req.onupgradeneeded = function () {
                  var d = req.result;
                  if (!d.objectStoreNames.contains(STORE)) d.createObjectStore(STORE, { keyPath: "id" });
                };
                req.onsuccess = function () { resolve(req.result); };
                req.onerror = function () { reject(req.error); };
              });
            }

            function dataUrlToBlob(dataUrl) {
              var comma = dataUrl.indexOf(",");
              var meta = dataUrl.slice(0, comma);
              var raw = atob(dataUrl.slice(comma + 1));
              var mime = (meta.match(/data:([^;]+)/) || [])[1] || "audio";
              var bytes = new Uint8Array(raw.length);
              for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
              return new Blob([bytes], { type: mime });
            }

            function save(sound) {
              return new Promise(function (resolve, reject) {
                var t = db.transaction(STORE, "readwrite");
                t.objectStore(STORE).put({
                  id: uuid(),
                  name: sound.name,
                  type: sound.type,
                  blob: dataUrlToBlob(sound.data),
                  savedAt: Date.now()
                });
                t.oncomplete = function () { resolve(); };
                t.onerror = function () { reject(t.error); };
              });
            }

            var db;
            var sounds = window.__SHARED_SOUNDS || [];

            openDB().then(function (database) {
              db = database;
              return sounds.reduce(function (chain, sound) {
                return chain.then(function () { return save(sound); });
              }, Promise.resolve());
            }).then(function () {
              location.replace("/soundboard.html" + (sounds.length ? "?shared=" + sounds.length : ""));
            }).catch(function () {
              location.replace("/soundboard.html");
            });
          })();
        </script>
      </body>
    </html>
    """
  end
end
