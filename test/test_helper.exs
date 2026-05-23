ExUnit.start()

# Tests tagged :needs_model require a local weights blob. Skip them (rather than
# fail) when it's absent, so the suite still runs on a fresh checkout.
model_path = Application.get_env(:rnnoise, :model_path)

if is_binary(model_path) and File.regular?(model_path) do
  ExUnit.configure(exclude: [])
else
  IO.puts(:stderr, """
  [rnnoise tests] weights blob not found at #{inspect(model_path)}.
  Skipping :needs_model tests. To run them, set RNNOISE_MODEL_PATH or run:
      mix rnnoise.gen_blob --output priv/weights_blob.bin
  """)

  ExUnit.configure(exclude: [needs_model: true])
end
