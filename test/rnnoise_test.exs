defmodule RnnoiseTest do
  use ExUnit.Case, async: true
  doctest Rnnoise

  @frame_bytes Rnnoise.frame_byte_size()

  # One second of a 440 Hz tone plus white noise, as 48 kHz mono s16le PCM.
  defp noisy_pcm(seconds \\ 1.0) do
    n = round(Rnnoise.sample_rate() * seconds)
    :rand.seed(:exsss, {1, 2, 3})

    for i <- 0..(n - 1), into: <<>> do
      t = i / Rnnoise.sample_rate()
      tone = 0.3 * :math.sin(2 * :math.pi() * 440 * t)
      noise = 0.25 * (:rand.uniform() * 2 - 1)
      sample = round(max(-1.0, min(1.0, tone + noise)) * 30_000)
      <<sample::16-little-signed>>
    end
  end

  defp rms(pcm) do
    samples = for <<s::16-little-signed <- pcm>>, do: s
    :math.sqrt(Enum.sum(Enum.map(samples, &(&1 * &1))) / max(length(samples), 1))
  end

  test "frame size constants (no model needed)" do
    assert Rnnoise.frame_size() == 480
    assert Rnnoise.frame_byte_size() == 960
    assert Rnnoise.sample_rate() == 48_000
    assert Rnnoise.Nif.frame_size() == 480
  end

  @tag :needs_model
  test "process_frame returns a vad probability and a same-size frame" do
    state = Rnnoise.new()
    frame = binary_part(noisy_pcm(), 0, @frame_bytes)
    {vad, out} = Rnnoise.process_frame(state, frame)

    assert is_float(vad)
    assert vad >= 0.0 and vad <= 1.0
    assert byte_size(out) == @frame_bytes
  end

  @tag :needs_model
  test "process_frame rejects wrong frame size" do
    state = Rnnoise.new()
    assert_raise FunctionClauseError, fn -> Rnnoise.process_frame(state, <<0, 1, 2>>) end
  end

  @tag :needs_model
  test "denoise/1 returns output of the same length for whole frames" do
    pcm = noisy_pcm()
    whole = binary_part(pcm, 0, div(byte_size(pcm), @frame_bytes) * @frame_bytes)
    out = Rnnoise.denoise(whole)
    assert byte_size(out) == byte_size(whole)
  end

  @tag :needs_model
  test "denoise/1 handles arbitrary (non-frame-aligned) lengths" do
    pcm = noisy_pcm() <> <<1, 2, 3, 4, 5>>
    out = Rnnoise.denoise(pcm)
    assert byte_size(out) == byte_size(pcm)
  end

  @tag :needs_model
  test "denoise suppresses a non-speech signal (VAD gates it down)" do
    pcm = noisy_pcm()
    out = Rnnoise.denoise(pcm)
    assert rms(out) < rms(pcm) / 10
  end

  @tag :needs_model
  test "an empty buffer denoises to empty" do
    assert Rnnoise.denoise(<<>>) == <<>>
  end

  @tag :needs_model
  test "streaming and bulk paths produce identical output" do
    pcm = binary_part(noisy_pcm(), 0, 30 * @frame_bytes)
    bulk = Rnnoise.denoise(Rnnoise.new(), pcm)

    state = Rnnoise.new()

    streamed =
      for <<frame::binary-size(@frame_bytes) <- pcm>>, into: <<>> do
        {_vad, out} = Rnnoise.process_frame(state, frame)
        out
      end

    assert bulk == streamed
  end

  describe "WAV round-trip (no model needed)" do
    test "encode then decode preserves format and data" do
      wav = %Rnnoise.Wav{
        channels: 1,
        sample_rate: 48_000,
        bits_per_sample: 16,
        data: noisy_pcm(0.1)
      }

      {:ok, parsed} = wav |> Rnnoise.Wav.encode() |> Rnnoise.Wav.decode()

      assert parsed.channels == 1
      assert parsed.sample_rate == 48_000
      assert parsed.bits_per_sample == 16
      assert parsed.data == wav.data
    end
  end

  @tag :needs_model
  test "denoise_file round-trips a WAV through the denoiser" do
    dir = System.tmp_dir!()
    in_path = Path.join(dir, "rnnoise_in_#{System.unique_integer([:positive])}.wav")
    out_path = Path.join(dir, "rnnoise_out_#{System.unique_integer([:positive])}.wav")

    on_exit(fn ->
      File.rm(in_path)
      File.rm(out_path)
    end)

    wav = %Rnnoise.Wav{
      channels: 1,
      sample_rate: 48_000,
      bits_per_sample: 16,
      data: noisy_pcm(0.5)
    }

    :ok = Rnnoise.Wav.write(in_path, wav)

    assert :ok = Rnnoise.denoise_file(in_path, out_path)
    {:ok, cleaned} = Rnnoise.Wav.read(out_path)
    assert cleaned.sample_rate == 48_000
    assert rms(cleaned.data) < rms(wav.data)
  end

  test "denoise_file rejects non-48k/mono input (no model needed)" do
    dir = System.tmp_dir!()
    in_path = Path.join(dir, "rnnoise_bad_#{System.unique_integer([:positive])}.wav")
    out_path = Path.join(dir, "rnnoise_bad_out.wav")

    on_exit(fn ->
      File.rm(in_path)
      File.rm(out_path)
    end)

    wav = %Rnnoise.Wav{channels: 2, sample_rate: 44_100, bits_per_sample: 16, data: <<0::3200>>}
    :ok = Rnnoise.Wav.write(in_path, wav)

    assert {:error, {:unsupported_format, _}} = Rnnoise.denoise_file(in_path, out_path)
  end
end
