import Config

# rnnoise downloads its 14 MB weights blob at runtime and caches it on disk.
# Set a model_url (+ model_sha256) to enable downloading, or a model_path / the
# RNNOISE_MODEL_PATH env var to point at a local blob. See Rnnoise.Model.
config :rnnoise,
  model_url: nil,
  model_sha256: nil,
  model_path: nil,
  cache_dir: nil

# When developing this library itself, always build the NIF from source instead
# of attempting to download precompiled artifacts (which only exist for tagged
# releases). This setting has no effect on projects that depend on rnnoise.
config :elixir_make, force_build: [rnnoise: true]

env_config = Path.join(__DIR__, "#{config_env()}.exs")
if File.exists?(env_config), do: import_config(env_config)
