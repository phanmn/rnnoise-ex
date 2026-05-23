defmodule Rnnoise do
  @moduledoc """
  Elixir bindings for [xiph/rnnoise](https://github.com/xiph/rnnoise), a
  recurrent-neural-network noise suppressor for speech.

  ## Audio format

  RNNoise operates on **mono, 48 kHz, signed 16-bit little-endian PCM**, in
  frames of #{480} samples (10 ms). All functions in this module take and
  return PCM in that format. If your audio is a different sample rate or has
  multiple channels, resample/downmix it to 48 kHz mono first.

  ## Two ways to use it

  Stateless one-shot, for a whole clip in memory:

      pcm = File.read!("noisy_48k_mono_s16le.raw")
      clean = Rnnoise.denoise(pcm)

  Streaming, keeping a denoiser state across frames (e.g. live audio). Feed it
  one frame (`frame_byte_size/0` bytes) at a time:

      state = Rnnoise.new()

      {vad, clean_frame} = Rnnoise.process_frame(state, frame)

  `vad` is the voice-activity probability (`0.0..1.0`) the network assigned to
  that frame.

  ## The model weights

  The 14 MB neural-network weights are **not** vendored. They are downloaded
  from a configurable URL on first use and cached on disk (see `Rnnoise.Model`):

      config :rnnoise,
        model_url: "https://.../weights_blob.bin",
        model_sha256: "<sha256>"

  Or point at a local blob with `config :rnnoise, model_path: "..."`, the
  `RNNOISE_MODEL_PATH` env var, or generate one with `mix rnnoise.gen_blob`.
  A specific model can also be chosen per stream with `new/1`.

  ## Concurrency

  A denoiser state is mutated in place on every call. Use one state per audio
  stream, and don't call a single state from multiple processes at once.
  """

  alias Rnnoise.Nif

  @sample_rate 48_000
  @frame_size 480
  @bytes_per_sample 2
  @frame_byte_size @frame_size * @bytes_per_sample

  @typedoc "Opaque, mutable denoiser state. One per audio stream."
  @type state :: reference()

  @doc "Sample rate RNNoise expects, in Hz (48000)."
  @spec sample_rate() :: pos_integer()
  def sample_rate, do: @sample_rate

  @doc "Samples per frame (480, i.e. 10 ms at 48 kHz)."
  @spec frame_size() :: pos_integer()
  def frame_size, do: @frame_size

  @doc "Bytes per frame of 16-bit PCM (960)."
  @spec frame_byte_size() :: pos_integer()
  def frame_byte_size, do: @frame_byte_size

  @doc """
  Create a new denoiser state.

  Allocate one per audio stream and reuse it across `process_frame/2` /
  `denoise/2` calls so the network keeps its temporal context.

  ## Options

    * `:model` — which model to use. Defaults to `:default` (resolved from
      config). May be a local blob path, a URL string, `{:url, url}`,
      `{:url, url, sha256}` or `{:path, path}`. See `Rnnoise.Model`.
    * `:sha256` — sha256 to verify when `:model` is a URL string.

  Raises `Rnnoise.Error` if the model can't be resolved/downloaded/loaded.
  """
  @spec new(keyword()) :: state()
  def new(opts \\ []) do
    source =
      case {Keyword.get(opts, :model, :default), Keyword.get(opts, :sha256)} do
        {model, sha} when is_binary(model) and is_binary(sha) -> {:url, model, sha}
        {model, _} -> model
      end

    Nif.create(Rnnoise.Model.get!(source))
  end

  @doc """
  Denoise a single frame of PCM.

  `pcm` must be exactly `frame_byte_size/0` bytes (480 samples). Returns
  `{vad_probability, denoised_pcm}`.
  """
  @spec process_frame(state(), binary()) :: {float(), binary()}
  def process_frame(state, pcm)
      when is_reference(state) and is_binary(pcm) and
             byte_size(pcm) == @frame_byte_size do
    Nif.process_frame(state, pcm)
  end

  @doc """
  Denoise a whole PCM buffer using a freshly created state.

  The buffer may be any length; a trailing partial frame is zero-padded for
  processing and the result is trimmed back to the original length.
  """
  @spec denoise(binary()) :: binary()
  def denoise(pcm) when is_binary(pcm), do: denoise(new(), pcm)

  @doc """
  Denoise a whole PCM buffer using the given state.

  Use this to denoise successive chunks of one stream while preserving context
  across calls. As with `denoise/1`, arbitrary lengths are accepted.
  """
  @spec denoise(state(), binary()) :: binary()
  def denoise(state, pcm) when is_reference(state) and is_binary(pcm) do
    original_size = byte_size(pcm)
    padded = pad_to_frame(pcm)
    out = Nif.process_buffer(state, padded)
    binary_part(out, 0, original_size)
  end

  @doc """
  Denoise a 48 kHz mono 16-bit WAV file and write the cleaned result to another
  WAV file.

  Returns `:ok`, or `{:error, reason}` if the input is not a 48 kHz mono 16-bit
  PCM WAV file. See `Rnnoise.Wav` for the underlying reader/writer.
  """
  @spec denoise_file(Path.t(), Path.t()) :: :ok | {:error, term()}
  def denoise_file(input_path, output_path) do
    with {:ok, %Rnnoise.Wav{} = wav} <- Rnnoise.Wav.read(input_path),
         :ok <- validate_wav(wav) do
      clean = denoise(wav.data)
      Rnnoise.Wav.write(output_path, %{wav | data: clean})
    end
  end

  defp validate_wav(%Rnnoise.Wav{channels: 1, sample_rate: @sample_rate, bits_per_sample: 16}),
    do: :ok

  defp validate_wav(%Rnnoise.Wav{} = wav) do
    {:error,
     {:unsupported_format,
      "expected mono/48000 Hz/16-bit, got #{wav.channels} ch / #{wav.sample_rate} Hz / #{wav.bits_per_sample}-bit"}}
  end

  defp pad_to_frame(pcm) do
    case rem(byte_size(pcm), @frame_byte_size) do
      0 -> pcm
      r -> pcm <> <<0::size((@frame_byte_size - r) * 8)>>
    end
  end
end
