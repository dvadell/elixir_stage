defmodule Soundai.TTS.OrtexServer do
  @moduledoc """
  A `GenServer` that owns a loaded `Ortex` ONNX session for the VITS TTS model.

  ONNX Runtime sessions are not safe for concurrent runs, so all synthesis is
  serialized through this process (a FIFO queue by construction — matching the
  concurrency model documented for the Node TTS pod). The model is loaded lazily
  on the first request and cached in state for reuse.
  """

  use GenServer

  require Logger

  alias Soundai.TTS.VitsTokenizer
  alias Soundai.TTS.Wav

  @name __MODULE__

  # The server is supervised (conditionally) from Soundai.Application; this
  # start_link is only invoked through that supervisor's child spec.
  def start_link(opts) do
    # credo:disable-for-next-line Credo.Check.Extra.NoUnsupervisedProcesses
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Synthesizes `text`, returning `{:ok, wav_map}` or `{:error, reason}`."
  def synthesize(text) when is_binary(text) do
    case Process.whereis(@name) do
      nil -> {:error, :not_ready}
      pid -> GenServer.call(pid, {:synthesize, text}, :infinity)
    end
  end

  @doc "Returns `true` when the model is loaded and ready to synthesize."
  def ready? do
    GenServer.call(@name, :ready?, 5_000)
  end

  @impl true
  def init(opts) do
    model_path = Keyword.fetch!(opts, :model_path)
    {:ok, %{model_path: model_path, model: nil}}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, is_struct(state.model, Ortex.Model), state}
  end

  def handle_call({:synthesize, text}, _from, state) do
    result =
      with {:ok, state} <- ensure_model(state),
           {:ok, ids, mask} <- tokenize(text),
           {:ok, waveform} <- run_model(state.model, ids, mask) do
        {:ok, Wav.encode_to_map(waveform)}
      end

    {:reply, result, state}
  end

  defp ensure_model(%{model: nil, model_path: path} = state) do
    if File.exists?(path) do
      case load_model(path) do
        {:ok, model} ->
          Logger.info("TTS: loaded model from #{path}")
          {:ok, %{state | model: model}}

        {:error, reason} ->
          Logger.error("TTS: failed to load model: #{inspect(reason)}")
          {:error, :not_ready}
      end
    else
      Logger.error("TTS: model file not found at #{path}")
      {:error, :not_ready}
    end
  end

  defp load_model(path) do
    {:ok, Ortex.load(path, [:cpu], 3)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp ensure_model(state), do: {:ok, state}

  defp tokenize(text) do
    {ids, mask} = VitsTokenizer.tokenize(text)
    {:ok, ids, mask}
  end

  defp run_model(model, ids, mask) do
    {waveform, _spectrogram} =
      Ortex.run(model, {
        ids |> Nx.tensor(type: {:s, 64}) |> Nx.reshape({1, :auto}),
        mask |> Nx.tensor(type: {:s, 64}) |> Nx.reshape({1, :auto})
      })

    {:ok, waveform}
  rescue
    e -> {:error, {:inference_failed, Exception.message(e)}}
  end
end
