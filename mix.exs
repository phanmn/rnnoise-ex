defmodule Rnnoise.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/phanmn/rnnoise-ex"

  def project do
    [
      app: :rnnoise,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      # Precompiled NIFs: users without a C toolchain download a prebuilt
      # rnnoise_nif from the GitHub release; otherwise it builds from source.
      make_precompiler: {:nif, CCPrecompiler},
      make_precompiler_url: "#{@source_url}/releases/download/v#{@version}/@{artefact_filename}",
      make_precompiler_filename: "rnnoise_nif",
      # Only the NIF goes in the precompiled tarball — never the 14 MB model blob.
      make_precompiler_priv_paths: ["rnnoise_nif.so", "rnnoise_nif.dll"],
      # Built on NIF 2.17 (OTP 26/27/28). Older runtimes (OTP 25, NIF 2.16)
      # fall back to building from source.
      make_precompiler_nif_versions: [versions: ["2.17"]],
      cc_precompiler: cc_precompiler(),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Rnnoise",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto, :public_key],
      mod: {Rnnoise.Application, []}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:cc_precompiler, "~> 0.1", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Precompilation targets. macOS arches are built natively (one runner each);
  # Linux builds x86_64 natively plus aarch64 via a cross compiler.
  defp cc_precompiler do
    [
      cleanup: "clean",
      compilers: %{
        {:unix, :linux} => %{
          :include_default_ones => true,
          "aarch64-linux-gnu" => {"aarch64-linux-gnu-gcc", "aarch64-linux-gnu-g++"}
        },
        {:unix, :darwin} => %{include_default_ones: true}
      }
    ]
  end

  defp description do
    "Elixir bindings (NIF) for xiph/rnnoise: recurrent-neural-network noise " <>
      "suppression for 48 kHz mono speech."
  end

  defp package do
    [
      licenses: ["BSD-3-Clause"],
      links: %{
        "GitHub" => @source_url,
        "rnnoise (xiph)" => "https://github.com/xiph/rnnoise"
      },
      # Ship sources, the Makefile and the precompiled-artifact checksums. The
      # 14 MB model blob is downloaded/cached at runtime (see Rnnoise.Model),
      # never vendored or packaged.
      files: ~w(lib c_src Makefile mix.exs README.md LICENSE .formatter.exs checksum.exs),
      exclude_patterns: ["priv/rnnoise_nif.so", "priv/rnnoise_nif.dll", "priv/weights_blob.bin"]
    ]
  end

  defp docs do
    [
      main: "Rnnoise",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
