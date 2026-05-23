defmodule Rnnoise.Model do
  @moduledoc """
  Resolves, downloads, caches and loads the rnnoise weights blob.

  The 14 MB binary weights blob is **not** vendored. It is fetched at runtime
  from a configurable URL and cached on disk, then loaded once into a model
  reference that every denoiser state shares.

  ## Configuration

      config :rnnoise,
        # Direct path to a weights blob — skips downloading entirely.
        model_path: nil,
        # URL serving the binary weights blob (e.g. a GitHub release asset).
        model_url: nil,
        # Lowercase hex sha256 of the blob; strongly recommended for downloads.
        model_sha256: nil,
        # Where downloaded blobs are cached. Defaults to the OS user cache dir.
        cache_dir: nil,
        # Max time to spend resolving/loading a model (download included).
        load_timeout: :timer.minutes(5)

  The env vars `RNNOISE_MODEL_PATH` and `RNNOISE_MODEL_URL` override
  `:model_path` / `:model_url` respectively.

  ## Resolution order for the default model

  1. `RNNOISE_MODEL_PATH` env var or `:model_path` config — used as-is.
  2. `RNNOISE_MODEL_URL` env var or `:model_url` config — downloaded & cached.
  3. Otherwise the model is downloaded from this library's GitHub release for the
     installed version (verified against a built-in sha256). This is the default,
     so the library works out of the box without configuration.

  A specific source can also be requested per call (see `get/1` and
  `Rnnoise.new/1`): a local path, a URL string, `{:url, url}`, `{:url, url, sha}`
  or `{:path, path}`.
  """

  use GenServer
  require Logger

  # Default model: the weights blob is published as a GitHub release asset on the
  # release matching the installed library version. sha256 of the pinned model.
  @default_model_repo "https://github.com/phanmn/rnnoise-ex"
  @default_model_sha256 "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91"

  @type source ::
          :default
          | binary()
          | {:path, binary()}
          | {:url, binary()}
          | {:url, binary(), binary()}

  # --- Public API -----------------------------------------------------------

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Return a loaded model reference for `source`, downloading/caching as needed.

  Loading is serialized and memoized: the same resolved blob path yields the same
  model reference for the lifetime of the VM.
  """
  @spec get(source()) :: {:ok, reference()} | {:error, term()}
  def get(source \\ :default) do
    GenServer.call(__MODULE__, {:get, source}, load_timeout())
  end

  @doc "Like `get/1` but raises on error."
  @spec get!(source()) :: reference()
  def get!(source \\ :default) do
    case get(source) do
      {:ok, ref} -> ref
      {:error, reason} -> raise Rnnoise.Error, message: explain(reason), reason: reason
    end
  end

  @doc "Resolve `source` to a local blob path (download/cache as needed) without loading it."
  @spec ensure_blob(source()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_blob(source \\ :default), do: resolve_to_path(source, config())

  @doc "Forget all loaded model references (next `get/1` reloads). Mainly for tests."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "The directory where downloaded blobs are cached."
  @spec cache_dir() :: Path.t()
  def cache_dir, do: cache_dir(config())

  # --- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{loaded: %{}}}

  @impl true
  def handle_call({:get, source}, _from, state) do
    with {:ok, path} <- resolve_to_path(source, config()) do
      case Map.fetch(state.loaded, path) do
        {:ok, ref} ->
          {:reply, {:ok, ref}, state}

        :error ->
          case Rnnoise.Nif.load_model(path) do
            {:ok, ref} -> {:reply, {:ok, ref}, put_in(state.loaded[path], ref)}
            {:error, reason} -> {:reply, {:error, {:nif_load_failed, reason, path}}, state}
          end
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | loaded: %{}}}

  # --- Resolution -----------------------------------------------------------

  defp resolve_to_path(:default, c) do
    cond do
      p = env("RNNOISE_MODEL_PATH") || c.model_path -> existing(p)
      u = env("RNNOISE_MODEL_URL") || c.model_url -> ensure_url(u, c.model_sha256, c)
      true -> ensure_url(default_model_url(), @default_model_sha256, c)
    end
  end

  defp resolve_to_path({:path, p}, _c), do: existing(p)
  defp resolve_to_path({:url, url}, c), do: ensure_url(url, nil, c)
  defp resolve_to_path({:url, url, sha}, c), do: ensure_url(url, sha, c)

  defp resolve_to_path(str, c) when is_binary(str) do
    if url?(str), do: ensure_url(str, nil, c), else: existing(str)
  end

  defp resolve_to_path(other, _c), do: {:error, {:bad_model_source, other}}

  defp default_model_url do
    vsn = to_string(Application.spec(:rnnoise, :vsn) || "0.1.0")
    "#{@default_model_repo}/releases/download/v#{vsn}/weights_blob.bin"
  end

  defp existing(path) do
    path = to_string(path)
    if File.regular?(path), do: {:ok, path}, else: {:error, {:model_file_missing, path}}
  end

  defp url?(s), do: String.starts_with?(s, ["http://", "https://"])

  # --- Download + cache -----------------------------------------------------

  defp ensure_url(url, sha, c) do
    dir = cache_dir(c)

    with :ok <- File.mkdir_p(dir) do
      file = cache_file(dir, url, sha)

      if File.regular?(file) and checksum_ok?(file, sha) do
        {:ok, file}
      else
        download_to(url, sha, file)
      end
    end
  end

  defp download_to(url, sha, file) do
    if is_nil(sha) do
      Logger.warning(
        "[rnnoise] downloading model without a sha256 checksum (#{url}); " <>
          "set config :rnnoise, model_sha256: to verify integrity"
      )
    end

    with {:ok, body} <- http_get(url),
         :ok <- verify_sha(body, sha) do
      tmp = file <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.write(tmp, body),
           :ok <- File.rename(tmp, file) do
        {:ok, file}
      else
        err ->
          _ = File.rm(tmp)
          err
      end
    end
  end

  defp cache_file(dir, url, sha) do
    name =
      case sha do
        nil -> "rnnoise-url-#{sha256_hex(url)}.bin"
        sha -> "rnnoise-#{sha}.bin"
      end

    Path.join(dir, name)
  end

  defp cache_dir(%{cache_dir: dir}) when is_binary(dir), do: dir
  defp cache_dir(_), do: to_string(:filename.basedir(:user_cache, "rnnoise"))

  defp checksum_ok?(_file, nil), do: true

  defp checksum_ok?(file, sha) do
    case File.read(file) do
      {:ok, body} -> sha256_hex(body) == String.downcase(sha)
      _ -> false
    end
  end

  defp verify_sha(_body, nil), do: :ok

  defp verify_sha(body, sha) do
    got = sha256_hex(body)
    want = String.downcase(sha)
    if got == want, do: :ok, else: {:error, {:checksum_mismatch, want, got}}
  end

  defp sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp http_get(url) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), [{~c"user-agent", ~c"rnnoise-ex"}]}

    http_opts =
      [timeout: 60_000, connect_timeout: 30_000, autoredirect: true] ++ ssl_http_opt(url)

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _headers, body}} -> {:ok, body}
      {:ok, {{_v, status, _r}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  # Verify the server certificate for https; plain http needs no ssl opts.
  defp ssl_http_opt("https://" <> _ = url) do
    host = URI.parse(url).host

    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl_http_opt(_), do: []

  # --- misc -----------------------------------------------------------------

  defp config do
    %{
      model_url: Application.get_env(:rnnoise, :model_url),
      model_sha256: Application.get_env(:rnnoise, :model_sha256),
      model_path: Application.get_env(:rnnoise, :model_path),
      cache_dir: Application.get_env(:rnnoise, :cache_dir)
    }
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      v -> v
    end
  end

  defp load_timeout, do: Application.get_env(:rnnoise, :load_timeout, :timer.minutes(5))

  @doc false
  def explain(:no_model_configured) do
    """
    No rnnoise model configured. Provide one of:

      * config :rnnoise, model_path: "/path/to/weights_blob.bin"
      * config :rnnoise, model_url: "https://.../weights_blob.bin",
                         model_sha256: "<sha256>"
      * the RNNOISE_MODEL_PATH or RNNOISE_MODEL_URL environment variable
      * generate a blob locally with: mix rnnoise.gen_blob
    """
  end

  def explain({:model_file_missing, path}), do: "rnnoise model file not found: #{path}"

  def explain({:checksum_mismatch, want, got}),
    do: "model sha256 mismatch: expected #{want}, got #{got}"

  def explain(other), do: "could not load rnnoise model: #{inspect(other)}"
end
