# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :watchtower,
  health_port: 4003,
  # bump to 1+ if you want readiness to depend on peers
  min_cluster_size: 0

config :soundai,
  generators: [timestamp_type: :utc_datetime]

# In-process TTS via Ortex/ONNX Runtime. The server only starts (and the
# /api/tts endpoint only serves audio) when the model file actually exists at
# the configured path. Override with e.g. SOUNDAI_TTS_MODEL_PATH in runtime.exs.
config :soundai, Soundai.TTS,
  model_path: "tts/model.onnx",
  max_text_length: 1000

# LLM conversation manager (branched_llm). req_llm has no :nvidia provider, so
# the NVIDIA OpenAI-compatible endpoint is reached through the :openai provider
# with a custom base_url; the API key is read from NVIDIA_API_KEY at runtime.
# Overrides: LLM_MODEL, LLM_BASE_URL, NVIDIA_API_KEY in runtime.exs.
config :branched_llm,
  ai_model: System.get_env("LLM_MODEL") || "openai:openai/gpt-oss-20b",
  default_provider: :openai,
  base_url: System.get_env("LLM_BASE_URL") || "https://integrate.api.nvidia.com/v1",
  max_tokens: 128_000

config :branched_llm, :providers,
  openai: [
    base_url: "https://integrate.api.nvidia.com/v1",
    api_key: {:system, "NVIDIA_API_KEY"}
  ]

# LLM conversation relay: per-conversation context store + adapter options.
config :soundai, Soundai.Conversation,
  system_prompt:
    "Eres un asistente de voz amable y directo. Respondes en español, de forma breve y natural, como en una conversación hablada, sin listas ni encabezados.",
  llm_timeout_ms: 30_000,
  max_response_chars: 500,
  store_ttl_ms: 30 * 60 * 1000

# Configure the endpoint
config :soundai, SoundaiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SoundaiWeb.ErrorHTML, json: SoundaiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Soundai.PubSub,
  live_view: [signing_salt: "7k3tDNoc"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :soundai, Soundai.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  soundai: [
    args:
      ~w(js/app.js js/whisper_worker.js js/tts_worker.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/soundai/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  soundai: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/soundai", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure the endpoint
config :soundpanel, SoundpanelWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SoundpanelWeb.ErrorHTML, json: SoundpanelWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Soundpanel.PubSub,
  live_view: [signing_salt: "UcgOrooD"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  soundpanel: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/soundpanel/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  soundpanel: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/soundpanel", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
