defmodule SoundaiWeb.HomeLive do
  use SoundaiWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, :voice, %{
       # The model is preloaded before the microphone button is shown.
       state: :loading,
       transcript: nil,
       error: nil,
       device: nil,
       progress: nil
     })}
  end

  @impl true
  def handle_event("voice_state", params, socket) do
    if authorized?(:voice, :update) do
      {:noreply, assign(socket, :voice, apply_state(socket.assigns.voice, params))}
    else
      {:noreply, socket}
    end
  end

  # Authorization policy for the voice assistant.
  #
  # This page is public and stateless: there is no logged-in user, so every
  # visitor is authorized to drive voice interaction. Kept as an explicit
  # authorization guard so that adding real authentication later is a single
  # change and no event is processed without going through it.
  @voice_policy %{voice: %{update: :allow}}

  defp authorized?(resource, action) do
    voice = Map.get(@voice_policy, resource, %{})
    Map.get(voice, action, :deny) == :allow
  end

  defp apply_state(voice, %{"state" => "loading"} = params) do
    %{voice | state: :loading, error: nil, progress: progress(params, voice.progress)}
  end

  defp apply_state(voice, %{"state" => "listening"} = params) do
    %{voice | state: :listening, error: nil, progress: progress(params, voice.progress)}
  end

  defp apply_state(voice, %{"state" => "transcribing"} = params) do
    %{voice | state: :transcribing, error: nil, progress: progress(params, voice.progress)}
  end

  defp apply_state(voice, %{"state" => "result"} = params) do
    %{
      voice
      | state: :result,
        transcript: param(params, "transcript", voice.transcript),
        error: nil,
        progress: nil,
        device: param(params, "device", voice.device)
    }
  end

  defp apply_state(voice, %{"state" => "error"} = params) do
    %{
      voice
      | state: :error,
        error: param(params, "error", gettext("Something went wrong.")),
        progress: nil,
        device: param(params, "device", voice.device)
    }
  end

  defp apply_state(voice, %{"state" => "idle"}) do
    %{voice | state: :idle, progress: nil}
  end

  defp apply_state(voice, _params), do: voice

  defp param(params, key, default) do
    case params do
      %{^key => value} when not is_nil(value) -> value
      _ -> default
    end
  end

  defp progress(params, current) do
    case params["progress"] do
      value when is_number(value) -> value
      _ -> current
    end
  end

  defp voice_label(%{state: :idle}), do: gettext("Hold to talk")
  defp voice_label(%{state: :listening}), do: gettext("Listening…")
  defp voice_label(%{state: :transcribing}), do: gettext("Transcribing…")
  defp voice_label(%{state: :result}), do: gettext("Tap to talk again")
  defp voice_label(%{state: :error}), do: gettext("Tap to retry")

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="voice-assistant"
      phx-hook="VoiceAssistant"
      class="relative z-0 h-dvh w-full touch-none select-none overflow-hidden"
    >
      <div class="absolute right-4 top-4 z-30">
        <.link
          navigate={~p"/settings"}
          aria-label={gettext("Speech-to-text settings")}
          class="flex items-center gap-2 rounded-full border border-base-300/60 bg-base-100/80 p-2.5 text-base-content/70 backdrop-blur transition hover:text-base-content"
        >
          <.icon name="hero-cog-6-tooth" class="size-5" />
        </.link>
      </div>

      <%= if @voice.state == :loading do %>
        <div
          id="model-loading"
          class="flex h-full flex-col items-center justify-center gap-6 px-6 text-center"
        >
          <span class="relative flex size-16 items-center justify-center">
            <span class="absolute inline-flex size-16 animate-ping rounded-full bg-primary/30"></span>
            <.icon name="hero-cpu-chip" class="relative size-8 text-primary" />
          </span>
          <p class="flex items-center gap-3 text-sm font-semibold uppercase tracking-[0.25em]">
            <span class="inline-block size-2.5 animate-pulse rounded-full bg-primary"></span>
            {gettext("Loading speech model…")}
          </p>
          <p
            :if={loading_progress?(@voice)}
            id="model-loading-progress"
            class="text-xs font-medium tracking-wider text-base-content/50"
          >
            {gettext("Downloading: %{progress}%", progress: @voice.progress)}
          </p>
        </div>
      <% else %>
        <button
          id="record-button"
          type="button"
          class={[
            "flex h-full w-full cursor-pointer items-center justify-center transition-colors duration-200 focus:outline-none",
            @voice.state == :listening && "bg-primary text-primary-content",
            @voice.state != :listening && "bg-base-100 text-base-content"
          ]}
          aria-label={gettext("Hold to record")}
        >
          <span class="pointer-events-none relative z-10 flex flex-col items-center gap-8 px-6">
            <span class="relative flex items-center justify-center">
              <span
                :if={@voice.state == :listening}
                class="absolute inline-flex size-56 animate-ping rounded-full bg-primary/40 sm:size-72"
              ></span>
              <.icon
                name="hero-microphone"
                class={[
                  "relative size-24 transition-transform duration-200 sm:size-32 md:size-48 lg:size-64",
                  @voice.state == :listening && "scale-110"
                ]}
              />
            </span>
            <span class="flex flex-col items-center gap-2">
              <span class="flex items-center gap-2 text-sm font-semibold uppercase tracking-[0.25em]">
                <span
                  :if={@voice.state == :listening}
                  class="inline-block size-2.5 animate-pulse rounded-full bg-red-500"
                ></span>
                {voice_label(@voice)}
              </span>
              <span
                :if={preparing?(@voice)}
                class="text-xs font-medium tracking-wider text-base-content/50"
              >
                {gettext("Preparing Whisper…")} {@voice.progress}%
              </span>
            </span>
          </span>
        </button>
      <% end %>

      <div
        :if={@voice.transcript || @voice.error}
        class="pointer-events-none absolute inset-x-0 bottom-6 z-20 flex justify-center px-6"
        aria-live="polite"
      >
        <div class={[
          "w-full max-w-2xl rounded-box border bg-base-100/90 px-6 py-5 text-center shadow-lg backdrop-blur",
          @voice.error && "border-error/40",
          !@voice.error && "border-base-300"
        ]}>
          <p :if={@voice.error} class="font-medium text-error">{@voice.error}</p>
          <p
            :if={@voice.transcript && !@voice.error}
            class="text-lg font-medium leading-relaxed"
            id="voice-transcript"
          >
            {@voice.transcript}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp preparing?(%{state: state, progress: progress})
       when state in [:listening, :transcribing] and is_number(progress) do
    progress > 0 and progress < 100
  end

  defp preparing?(_voice), do: false

  defp loading_progress?(%{state: :loading, progress: progress}) when is_number(progress) do
    progress > 0 and progress < 100
  end

  defp loading_progress?(_voice), do: false
end
