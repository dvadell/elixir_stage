defmodule SoundaiWeb.HomeLive do
  use SoundaiWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="h-dvh w-full">
      <button
        id="record-button"
        type="button"
        phx-hook=".RecordButton"
        class="flex h-full w-full cursor-pointer touch-none select-none items-center justify-center bg-base-100 transition-colors duration-150 active:bg-primary active:text-primary-content focus:outline-none"
        aria-label={gettext("Hold to record")}
      >
        <.icon
          name="hero-microphone"
          class="size-24 text-base-content/80 sm:size-32 md:size-48 lg:size-64"
        />
      </button>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RecordButton">
      export default {
        mounted() {
          this.stream = null
          this.mediaRecorder = null
          this.recognition = null
          this.transcript = ""
          this.recording = false

          this.startRecording = async () => {
            try {
              if (!this.stream) {
                this.stream = await navigator.mediaDevices.getUserMedia({audio: true})
              }

              if (!this.mediaRecorder) {
                this.mediaRecorder = new MediaRecorder(this.stream)
                this.mediaRecorder.addEventListener("stop", () => {
                  console.log("[soundai] recording stopped")
                })
                this.mediaRecorder.start()
              }

              const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition
              if (!SpeechRecognition) {
                console.log("[soundai] speech-to-text API not supported in this browser")
                return
              }

              if (!this.recognition) {
                this.transcript = ""
                this.recognition = new SpeechRecognition()
                this.recognition.continuous = true
                this.recognition.interimResults = true
                this.recognition.lang = "en-US"

                this.recognition.addEventListener("result", (event) => {
                  let text = ""
                  for (let i = 0; i < event.results.length; i++) {
                    if (event.results[i].isFinal) {
                      text += event.results[i][0].transcript
                    }
                  }
                  if (text) this.transcript += text
                })

                this.recognition.addEventListener("end", () => {
                  if (this.transcript) {
                    console.log("[soundai] transcript:", this.transcript)
                  }
                  this.recognition = null
                })

                this.recognition.start()
              }
            } catch (error) {
              console.error("[soundai] failed to start recording:", error)
            }
          }

          this.stopRecording = () => {
            if (this.recognition) {
              this.recognition.stop()
            }
            if (this.mediaRecorder && this.mediaRecorder.state !== "inactive") {
              this.mediaRecorder.stop()
            }
          }

          this.onPointerDown = (event) => {
            event.preventDefault()
            if (this.recording) return
            this.recording = true
            if (this.el.setPointerCapture) {
              this.el.setPointerCapture(event.pointerId)
            }
            this.startRecording()
          }

          this.onPointerUp = (event) => {
            event.preventDefault()
            if (!this.recording) return
            this.recording = false
            this.stopRecording()
          }

          this.el.addEventListener("pointerdown", this.onPointerDown)
          this.el.addEventListener("pointerup", this.onPointerUp)
          this.el.addEventListener("pointercancel", this.onPointerUp)
        },

        destroyed() {
          this.el.removeEventListener("pointerdown", this.onPointerDown)
          this.el.removeEventListener("pointerup", this.onPointerUp)
          this.el.removeEventListener("pointercancel", this.onPointerUp)

          if (this.recognition) {
            this.recognition.abort()
          }
          if (this.stream) {
            this.stream.getTracks().forEach((track) => track.stop())
          }
          this.recognition = null
          this.mediaRecorder = null
          this.stream = null
        }
      }
    </script>
    """
  end
end
