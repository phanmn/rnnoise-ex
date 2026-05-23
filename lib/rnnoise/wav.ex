defmodule Rnnoise.Wav do
  @moduledoc """
  Minimal reader/writer for uncompressed PCM `.wav` files.

  Supports canonical RIFF/WAVE integer-PCM files (audio format 1). Unknown
  chunks are skipped on read; on write a canonical 44-byte header is emitted.
  This exists to make `Rnnoise.denoise_file/2` convenient — it is not a general
  audio library.
  """

  defstruct channels: 1, sample_rate: 48_000, bits_per_sample: 16, data: <<>>

  @type t :: %__MODULE__{
          channels: pos_integer(),
          sample_rate: pos_integer(),
          bits_per_sample: pos_integer(),
          data: binary()
        }

  @pcm_format 1

  @doc "Read a PCM WAV file into a `%Rnnoise.Wav{}` struct."
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, bin} <- File.read(path) do
      decode(bin)
    end
  end

  @doc "Decode a WAV binary into a `%Rnnoise.Wav{}` struct (inverse of `encode/1`)."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(<<"RIFF", _riff_size::32-little, "WAVE", rest::binary>>) do
    scan_chunks(rest, %__MODULE__{})
  end

  def decode(_), do: {:error, :not_a_wav_file}

  @doc "Write a `%Rnnoise.Wav{}` struct to a canonical PCM WAV file."
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(path, %__MODULE__{} = wav) do
    File.write(path, encode(wav))
  end

  @doc "Encode a `%Rnnoise.Wav{}` struct to WAV binary."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = wav) do
    block_align = div(wav.channels * wav.bits_per_sample, 8)
    byte_rate = wav.sample_rate * block_align
    data_size = byte_size(wav.data)

    fmt =
      <<@pcm_format::16-little, wav.channels::16-little, wav.sample_rate::32-little,
        byte_rate::32-little, block_align::16-little, wav.bits_per_sample::16-little>>

    body =
      "WAVE" <>
        "fmt " <>
        <<byte_size(fmt)::32-little>> <>
        fmt <>
        "data" <> <<data_size::32-little>> <> wav.data

    "RIFF" <> <<byte_size(body)::32-little>> <> body
  end

  # fmt chunk: pull out the fields we care about.
  defp scan_chunks(
         <<"fmt ", size::32-little, fmt::binary-size(size), rest::binary>>,
         acc
       ) do
    <<format::16-little, channels::16-little, sample_rate::32-little, _byte_rate::32-little,
      _block_align::16-little, bits::16-little, _extra::binary>> = fmt

    if format == @pcm_format do
      acc = %{acc | channels: channels, sample_rate: sample_rate, bits_per_sample: bits}
      scan_chunks(skip_pad(rest, size), acc)
    else
      {:error, {:unsupported_audio_format, format}}
    end
  end

  defp scan_chunks(<<"data", size::32-little, data::binary-size(size), rest::binary>>, acc) do
    scan_chunks(skip_pad(rest, size), %{acc | data: data})
  end

  # Any other chunk: skip its (padded) payload and continue.
  defp scan_chunks(<<_id::binary-size(4), size::32-little, rest::binary>>, acc)
       when byte_size(rest) >= size do
    scan_chunks(skip_pad(rest, size), acc)
  end

  defp scan_chunks(_leftover, %__MODULE__{data: <<>>}), do: {:error, :no_data_chunk}
  defp scan_chunks(_leftover, acc), do: {:ok, acc}

  # RIFF chunks are padded to an even number of bytes.
  defp skip_pad(bin, size) when rem(size, 2) == 1 do
    case bin do
      <<_pad::8, rest::binary>> -> rest
      _ -> bin
    end
  end

  defp skip_pad(bin, _size), do: bin
end
