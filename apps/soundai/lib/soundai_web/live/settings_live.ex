defmodule SoundaiWeb.SettingsLive do
  use SoundaiWeb, :live_view

  # Multilingual Whisper exports from the onnx-community org, all with
  # transformers.js support and Spanish capability. Extend freely; the voice
  # assistant reads the selection from localStorage and falls back to the
  # committed WHISPER_CONFIG defaults when nothing has been chosen.
  @models [
    {
      "onnx-community/whisper-tiny",
      gettext("Whisper Tiny — fastest"),
      gettext(
        "Fastest and lightest, lowest accuracy. Best for very short utterances or slow devices."
      )
    },
    {
      "onnx-community/whisper-base",
      gettext("Whisper Base — balanced"),
      gettext("Good accuracy and speed. The default; works well on most devices.")
    },
    {
      "onnx-community/whisper-small",
      gettext("Whisper Small — best Spanish"),
      gettext("Best accuracy, noticeably better Spanish, but slower and a larger download.")
    }
  ]

  @model_ids Enum.map(@models, &elem(&1, 0))

  # The settings page is public and stateless: every visitor may choose their
  # own STT model preference. Kept as an explicit authorization guard so that
  # adding real authentication later is a single change and no event is
  # processed without going through it.
  @settings_policy %{settings: %{read: :allow, write: :allow}}

  defp authorized?(resource, action) do
    settings = Map.get(@settings_policy, resource, %{})
    Map.get(settings, action, :deny) == :allow
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, models: @models, selected_desc: nil, saved_model: nil)}
  end

  @impl true
  def handle_event("model_loaded", %{"model" => model}, socket) do
    if authorized?(:settings, :read) do
      {:noreply, select_desc(socket, model)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("model_saved", %{"model" => model}, socket) do
    if authorized?(:settings, :write) do
      if model in @model_ids do
        {:noreply, select_desc(socket, model) |> assign(:saved_model, model)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp select_desc(socket, model) do
    if model in @model_ids do
      assign(socket, :selected_desc, desc_for(model))
    else
      socket
    end
  end

  defp desc_for(model) do
    Enum.find_value(@models, fn {id, _label, desc} ->
      if id == model, do: desc
    end)
  end

  defp model_label(model) do
    Enum.find_value(@models, model, fn {id, label, _desc} ->
      if id == model, do: label
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} show_header={false}>
      <div>
        <h1 class="text-2xl font-bold tracking-tight">{gettext("Speech-to-text settings")}</h1>
        <p class="mt-2 max-w-xl text-base-content/70">
          {gettext(
            "Choose the Whisper model the voice assistant uses to transcribe speech locally in your browser."
          )}
        </p>

        <div class="mt-8 rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
          <label for="stt-model" class="mb-2 block text-sm font-semibold">
            {gettext("STT model")}
          </label>
          <select
            id="stt-model"
            phx-hook=".STTSettings"
            class="w-full cursor-pointer rounded-lg border border-base-300 bg-base-100 px-4 py-2.5 text-sm font-medium transition focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/30"
          >
            <option :for={{id, label, _desc} <- @models} value={id}>{label}</option>
          </select>

          <p :if={@selected_desc} id="stt-model-desc" class="mt-3 text-sm text-base-content/60">
            {@selected_desc}
          </p>

          <p class="mt-3 text-sm text-base-content/60">
            {gettext(
              "Applies the next time you open the voice assistant; the model is downloaded on first use."
            )}
          </p>

          <div
            :if={@saved_model}
            id="stt-saved"
            class="mt-4 flex items-center gap-2 rounded-lg bg-success/10 px-4 py-3 text-sm font-medium text-success"
          >
            <.icon name="hero-check-circle" class="size-4 shrink-0" />
            <span>
              {gettext(
                "Saved: %{model} will be used next time the voice assistant loads.",
                model: model_label(@saved_model)
              )}
            </span>
          </div>
        </div>

        <div class="mt-6 text-sm text-base-content/60">
          <.link
            navigate={~p"/"}
            class="inline-flex items-center gap-2 rounded-lg px-3 py-2 font-medium transition hover:bg-base-300/60 hover:text-base-content"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {gettext("Back to the voice assistant")}
          </.link>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".STTSettings">
        const STORAGE_KEY = "soundai_model"

        function readCookie(name) {
          const prefix = `${name}=`
          for (const cookie of document.cookie.split("; ")) {
            if (cookie.startsWith(prefix)) return decodeURIComponent(cookie.slice(prefix.length))
          }
          return null
        }

        function writeCookie(name, value) {
          document.cookie = `${name}=${encodeURIComponent(value)}; path=/; max-age=31536000; SameSite=Lax`
        }

        export default {
          mounted() {
            const stored = readCookie(STORAGE_KEY)
            if (stored && [...this.el.options].some((opt) => opt.value === stored)) {
              this.el.value = stored
            }
            this.pushEvent("model_loaded", { model: this.el.value })

            this.el.addEventListener("change", (event) => {
              writeCookie(STORAGE_KEY, event.target.value)
              this.pushEvent("model_saved", { model: event.target.value })
            })
          },
        }
      </script>
    </Layouts.app>
    """
  end
end
