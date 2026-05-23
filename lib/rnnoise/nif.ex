defmodule Rnnoise.Nif do
  @moduledoc """
  Thin wrapper around the rnnoise C NIF.

  You normally use `Rnnoise` (and, indirectly, `Rnnoise.Model`) instead of this
  module. The model weights are *not* loaded when the NIF loads — call
  `load_model/1` with the path to a `weights_blob.bin` to get a model reference,
  then `create/1` to make denoiser states from it.

  A denoiser state returned by `create/1` is a mutable reference. It must not be
  shared across processes that call it concurrently — `rnnoise_process_frame`
  mutates the state in place.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    nif_path = :filename.join(:code.priv_dir(:rnnoise), ~c"rnnoise_nif")
    :erlang.load_nif(nif_path, 0)
  end

  @doc """
  Load a weights blob from `path` into a model reference.

  Returns `{:ok, model}` or `{:error, :open_failed | :load_failed}`.
  """
  @spec load_model(binary()) :: {:ok, reference()} | {:error, atom()}
  def load_model(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Allocate a new denoiser state from a loaded `model` reference."
  @spec create(reference()) :: reference()
  def create(_model), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Number of samples (480) processed per frame."
  @spec frame_size() :: pos_integer()
  def frame_size, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Denoise exactly one frame of 16-bit PCM (480 samples / 960 bytes).

  Returns `{vad_probability, denoised_pcm}` where `vad_probability` is the
  voice-activity estimate in `0.0..1.0` for that frame.
  """
  @spec process_frame(reference(), binary()) :: {float(), binary()}
  def process_frame(_state, _pcm), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Denoise a whole buffer of 16-bit PCM whose length is a multiple of 960 bytes.

  Runs on a dirty CPU scheduler. Returns the denoised PCM of the same length.
  """
  @spec process_buffer(reference(), binary()) :: binary()
  def process_buffer(_state, _pcm), do: :erlang.nif_error(:nif_not_loaded)
end
