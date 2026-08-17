defmodule Soundai.TTS.Wav do
  @moduledoc """
  Encodes a `Float32` waveform from the VITS model into a standard WAV file.

  Produces a 44-byte header 16-bit PCM, 16 kHz, mono WAV that any browser can
  decode with `AudioContext.decodeAudioData/1`.
  """

  @sample_rate 16_000
  @channels 1
  @bits_per_sample 16

  @doc """
  Encodes an `f32` tensor of shape `{1, n}` (or a flat list of floats) into WAV
  bytes. Samples are clamped to `[-1.0, 1.0]` and quantized to signed 16-bit.
  """
  def encode(%Nx.Tensor{shape: {1, n}} = waveform) do
    encode_samples(Nx.to_flat_list(waveform), n)
  end

  def encode(%Nx.Tensor{} = waveform) do
    waveform = Nx.reshape(waveform, {1, :auto})
    encode(waveform)
  end

  def encode(samples) when is_list(samples) do
    encode_samples(samples, length(samples))
  end

  defp encode_samples(samples, n) do
    pcm =
      for sample <- samples, into: <<>> do
        clamped = max(-1.0, min(1.0, sample))
        <<round(clamped * 32_767)::signed-little-16>>
      end

    byte_rate = @sample_rate * @channels * div(@bits_per_sample, 8)

    header = <<
      "RIFF",
      byte_size(pcm) + 36::unsigned-little-32,
      "WAVE",
      "fmt ",
      16::unsigned-little-32,
      1::unsigned-little-16,
      @channels::unsigned-little-16,
      @sample_rate::unsigned-little-32,
      byte_rate::unsigned-little-32,
      @channels * div(@bits_per_sample, 8)::unsigned-little-16,
      @bits_per_sample::unsigned-little-16,
      "data",
      byte_size(pcm)::unsigned-little-32
    >>

    {header <> pcm, n}
  end

  @doc """
  Encodes samples and returns `%{audio: binary, duration_ms: integer, sample_rate: 16000}`.
  """
  def encode_to_map(samples) do
    {audio, n} = encode(samples)
    %{audio: audio, duration_ms: round(n * 1000 / @sample_rate), sample_rate: @sample_rate}
  end
end
