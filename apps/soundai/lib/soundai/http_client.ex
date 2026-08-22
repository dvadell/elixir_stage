# credo:disable-for-this-file Credo.Check.Extra.NoDirectThirdPartyCalls
defmodule Soundai.HttpClient do
  @moduledoc """
  Thin wrapper around `Req` so business modules do not call a third-party HTTP
  client directly (mirrors `BranchedLLM.HttpClient`). Every request is wrapped
  in a telemetry span for observability. Tests keep mocking at the transport
  level via `Req.Test` plugs injected through request options.
  """

  def new(opts \\ []) do
    Req.new(opts)
  end

  def get(request, opts) do
    url = Keyword.get(opts, :url)

    :telemetry.span([:soundai, :http, :request], %{method: :get, url: url}, fn ->
      case Req.get(request, opts) do
        {:ok, response} -> {{:ok, response}, %{status: response.status}}
        {:error, reason} -> {{:error, reason}, %{}}
      end
    end)
  end
end
