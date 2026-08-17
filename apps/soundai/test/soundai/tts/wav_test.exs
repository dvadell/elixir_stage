defmodule Soundai.TTS.WavTest do
  use ExUnit.Case, async: true

  alias Soundai.TTS.Wav

  defp header(binary) do
    <<
      _riff::binary-size(4),
      file_size::little-unsigned-32,
      _wave::binary-size(4),
      _fmt_tag::binary-size(4),
      fmt_size::little-unsigned-32,
      audio_format::little-unsigned-16,
      channels::little-unsigned-16,
      sample_rate::little-unsigned-32,
      byte_rate::little-unsigned-32,
      block_align::little-unsigned-16,
      bits_per_sample::little-unsigned-16,
      _data_tag::binary-size(4),
      data_size::little-unsigned-32,
      data::binary
    >> = binary

    %{
      file_size: file_size,
      fmt_size: fmt_size,
      audio_format: audio_format,
      channels: channels,
      sample_rate: sample_rate,
      byte_rate: byte_rate,
      block_align: block_align,
      bits_per_sample: bits_per_sample,
      data_size: data_size,
      data: data
    }
  end

  test "encodes a flat sample list into a valid 16-bit PCM mono WAV" do
    samples = [0.0, 0.5, -0.5, 1.0, -1.0]
    {wav, n} = Wav.encode(samples)
    h = header(wav)

    assert n == 5
    assert h.file_size == byte_size(wav) - 8
    assert h.fmt_size == 16
    assert h.audio_format == 1
    assert h.channels == 1
    assert h.sample_rate == 16_000
    assert h.byte_rate == 32_000
    assert h.block_align == 2
    assert h.bits_per_sample == 16
    assert h.data_size == byte_size(h.data)

    assert h.data ==
             <<0::signed-little-16, 16_384::signed-little-16, -16_384::signed-little-16,
               32_767::signed-little-16, -32_767::signed-little-16>>
  end

  test "encodes an Nx f32 tensor of shape {1, n}" do
    tensor = Nx.tensor([[0.0, 1.0]])
    {wav, n} = Wav.encode(tensor)

    assert n == 2
    assert <<"RIFF", _::binary>> = wav
  end

  test "clamps out-of-range samples" do
    {wav, _} = Wav.encode([2.0, -2.0])
    assert byte_size(wav) > 0
  end

  test "encode_to_map returns audio metadata" do
    map = Wav.encode_to_map([0.0, 0.5])

    assert map.audio ==
             <<
               "RIFF",
               40::little-unsigned-32,
               "WAVE",
               "fmt ",
               16::little-unsigned-32,
               1::little-unsigned-16,
               1::little-unsigned-16,
               16_000::little-unsigned-32,
               32_000::little-unsigned-32,
               2::little-unsigned-16,
               16::little-unsigned-16,
               "data",
               4::little-unsigned-32,
               0::signed-little-16,
               16_384::signed-little-16
             >>

    assert map.duration_ms == 0
    assert map.sample_rate == 16_000
  end
end
