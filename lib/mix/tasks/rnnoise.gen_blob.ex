defmodule Mix.Tasks.Rnnoise.GenBlob do
  @shortdoc "Generate the rnnoise weights_blob.bin from the official xiph model"
  @moduledoc """
  Build the binary weights blob that `Rnnoise.Model` loads, from the official
  xiph model tarball — no third-party hosting required.

  The model that ships with rnnoise is distributed as a `.tar.gz` of C *source*
  weights, not the runtime binary blob. This task downloads that tarball
  (verifying its sha256), compiles the bundled `write_weights.c` tool against the
  downloaded weights, and runs it to produce `weights_blob.bin`. It prints the
  blob's sha256 so you can set `:model_sha256` and/or upload the blob somewhere
  to serve via `:model_url`.

  ## Usage

      mix rnnoise.gen_blob
      mix rnnoise.gen_blob --output priv/weights_blob.bin
      mix rnnoise.gen_blob --hash <model_version_hash>

  ## Options

    * `--output PATH`  Where to write the blob. Defaults to the `Rnnoise.Model`
                       cache dir (so the runtime finds it without configuration).
    * `--hash HASH`    Model version hash (and tarball sha256). Defaults to the
                       version pinned by this library.
    * `--cc CC`        C compiler to use. Defaults to `$CC` or `cc`.

  Run this from the rnnoise-ex repository (or a project that has it as a dep) so
  the vendored C headers under `c_src/rnnoise` are reachable.
  """
  use Mix.Task

  # Pinned model version (this string is also the tarball's sha256).
  @default_hash "0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37"
  @base_url "https://media.xiph.org/rnnoise/models"

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [output: :string, hash: :string, cc: :string])

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    hash = opts[:hash] || @default_hash
    cc = opts[:cc] || System.get_env("CC") || "cc"
    csrc = locate_csrc!()

    output =
      opts[:output] ||
        Path.join(to_string(:filename.basedir(:user_cache, "rnnoise")), "rnnoise-#{hash}.bin")

    tmp = Path.join(System.tmp_dir!(), "rnnoise-gen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      tarball = download_tarball!(hash, tmp)
      verify_sha!(tarball, hash)
      :ok = extract!(tarball, tmp)
      data_dir = Path.join(tmp, "src")
      ensure_files!(data_dir, ["rnnoise_data.c", "rnnoise_data.h"])

      exe = compile!(cc, csrc, data_dir, tmp)
      blob = run_writer!(exe, tmp)

      File.mkdir_p!(Path.dirname(output))
      File.cp!(blob, output)
      blob_sha = sha256_hex(File.read!(output))

      Mix.shell().info("""

      Wrote weights blob:
        path:   #{output}
        size:   #{div(byte_size(File.read!(output)), 1024)} KiB
        sha256: #{blob_sha}

      To use it, either it is already in the cache dir (no config needed), or:

          config :rnnoise, model_path: #{inspect(output)}

      To serve it from a URL, upload the file and set:

          config :rnnoise,
            model_url: "https://.../weights_blob.bin",
            model_sha256: "#{blob_sha}"
      """)
    after
      File.rm_rf(tmp)
    end
  end

  defp locate_csrc! do
    candidates = [
      Path.join(File.cwd!(), "c_src/rnnoise"),
      Path.join(File.cwd!(), "deps/rnnoise/c_src/rnnoise")
    ]

    case Enum.find(candidates, &File.dir?/1) do
      nil ->
        Mix.raise(
          "could not find vendored rnnoise sources. Run this from the rnnoise-ex " <>
            "repo or a project with rnnoise as a dependency. Looked in:\n  " <>
            Enum.join(candidates, "\n  ")
        )

      dir ->
        dir
    end
  end

  defp download_tarball!(hash, tmp) do
    name = "rnnoise_data-#{hash}.tar.gz"
    url = "#{@base_url}/#{name}"
    dest = Path.join(tmp, name)
    Mix.shell().info("Downloading #{url} ...")

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [autoredirect: true, timeout: 120_000, connect_timeout: 30_000] ++ ssl_opt(url),
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _h, body}} -> File.write!(dest, body)
      {:ok, {{_, status, _}, _h, _b}} -> Mix.raise("download failed: HTTP #{status}")
      {:error, reason} -> Mix.raise("download failed: #{inspect(reason)}")
    end

    dest
  end

  defp extract!(tarball, tmp) do
    :erl_tar.extract(String.to_charlist(tarball), [:compressed, {:cwd, String.to_charlist(tmp)}])
  end

  defp ensure_files!(dir, names) do
    Enum.each(names, fn name ->
      path = Path.join(dir, name)

      unless File.exists?(path),
        do: Mix.raise("expected #{path} in the tarball but it is missing")
    end)
  end

  # write_weights.c does `#include "rnnoise_data.c"`. A quoted include resolves
  # against the including file's own directory first, so we compile a *copy* of
  # write_weights.c placed in the downloaded data dir — next to the full
  # rnnoise_data.c — rather than the vendored one (whose sibling rnnoise_data.c
  # is stripped of weights). Vendored headers (nnet.h, etc.) come via -I.
  defp compile!(cc, csrc, data_dir, tmp) do
    exe = Path.join(tmp, "dump_weights_blob")
    writer = Path.join(data_dir, "write_weights.c")
    File.cp!(Path.join(csrc, "src/write_weights.c"), writer)

    args = [
      "-O2",
      "-DDUMP_BINARY_WEIGHTS",
      "-I#{data_dir}",
      "-I#{Path.join(csrc, "src")}",
      "-I#{Path.join(csrc, "include")}",
      writer,
      "-lm",
      "-o",
      exe
    ]

    Mix.shell().info("Compiling weights writer with #{cc} ...")

    case System.cmd(cc, args, stderr_to_stdout: true) do
      {_out, 0} -> exe
      {out, code} -> Mix.raise("compile failed (#{code}):\n#{out}")
    end
  end

  defp run_writer!(exe, tmp) do
    # write_weights writes ./weights_blob.bin in its working directory.
    case System.cmd(exe, [], cd: tmp, stderr_to_stdout: true) do
      {_out, 0} ->
        blob = Path.join(tmp, "weights_blob.bin")
        unless File.exists?(blob), do: Mix.raise("writer ran but produced no weights_blob.bin")
        blob

      {out, code} ->
        Mix.raise("weights writer failed (#{code}):\n#{out}")
    end
  end

  defp verify_sha!(file, expected) do
    got = sha256_hex(File.read!(file))

    unless got == String.downcase(expected) do
      Mix.raise("tarball sha256 mismatch: expected #{expected}, got #{got}")
    end
  end

  defp sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp ssl_opt("https://" <> _ = url) do
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

  defp ssl_opt(_), do: []
end
