import Config

# Tests use a local blob so they stay offline. Point RNNOISE_MODEL_PATH at a
# weights_blob.bin, or place one at priv/weights_blob.bin (gitignored — fetch it
# at runtime once or run `mix rnnoise.gen_blob`). Tests that need the model are
# tagged :needs_model and skipped automatically when it is absent.
config :rnnoise,
  model_path:
    System.get_env("RNNOISE_MODEL_PATH") ||
      Path.expand("../priv/weights_blob.bin", __DIR__)
