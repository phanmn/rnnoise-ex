# Rnnoise

Elixir bindings for [xiph/rnnoise](https://github.com/xiph/rnnoise) — a
recurrent-neural-network noise suppressor for speech, wrapped as a NIF.

The upstream C library is vendored in-tree (`c_src/rnnoise/`) and wrapped as a
NIF. **Precompiled NIFs** are published for common targets (macOS x86_64/arm64,
Linux x86_64/arm64), so most users need no C compiler. On other targets it
compiles from source via [`elixir_make`](https://hex.pm/packages/elixir_make)
(a C compiler + `make` required). The Linux artifacts require only `glibc` 2.17+
(x86_64 needs just 2.14), so they load on all current distributions — both the
x86_64 and aarch64 NIFs are verified loading and denoising on `ubuntu-jammy`.

The 14 MB trained model is **not** vendored. By default it is downloaded from
this project's GitHub release on first use and cached on disk (or you can point
at your own URL/file, or generate it locally), keeping the package and your repo
small. See [The model weights](#the-model-weights).

## Audio format

RNNoise only works on **mono, 48 kHz, signed 16-bit little-endian PCM**, in
frames of 480 samples (10 ms). Resample/downmix anything else to 48 kHz mono
first. All functions take and return PCM in that format.

## Installation

Install from GitHub, pinning a released tag (precompiled NIFs and the model are
attached to that tag's release):

```elixir
def deps do
  [
    {:rnnoise, github: "phanmn/rnnoise-ex", tag: "v0.1.0"}
  ]
end
```

> Pin a **tag**, not a branch: precompiled NIFs require the `checksum.exs` that
> is folded into each release tag, and the model is published per-version. A
> branch ref has no `checksum.exs`, so it would compile the NIF from source.

On a supported target the precompiled NIF is downloaded automatically — no
compiler needed. On other targets, a C compiler (`cc`/`clang`/`gcc`) and `make`
must be available at build time.

The model is fetched automatically on first use from this project's GitHub
release, so nothing else is required to get started. See below to customize it.

## The model weights

The neural-network weights are a 14 MB binary blob that is fetched and cached at
runtime by `Rnnoise.Model`, never committed or shipped in the package. By
default it is downloaded from this project's GitHub release for the installed
version and verified against a built-in sha256. You can override this:

**Download from a URL** (cached in the OS cache dir, sha256-verified):

```elixir
config :rnnoise,
  model_url: "https://example.com/weights_blob.bin",
  model_sha256: "1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91"
```

**Point at a local file:**

```elixir
config :rnnoise, model_path: "/path/to/weights_blob.bin"
# or: RNNOISE_MODEL_PATH=/path/to/weights_blob.bin
```

**Generate it locally from the official xiph model** (no hosting needed). This
downloads the official source tarball, builds the blob, and prints its sha256:

```sh
mix rnnoise.gen_blob                       # -> OS cache dir (auto-discovered)
mix rnnoise.gen_blob --output priv/weights_blob.bin
```

The blob for the pinned model version has sha256
`1b99898350e75656c77d068162fea402afe51eff15dc751989b1e9f53b98bf91`.

You can also pick a model per stream: `Rnnoise.new(model: "https://.../blob.bin", sha256: "...")`
or `Rnnoise.new(model: {:path, "/path/blob.bin"})`.

## Usage

One-shot, whole clip in memory:

```elixir
pcm = File.read!("noisy_48k_mono_s16le.raw")
clean = Rnnoise.denoise(pcm)
File.write!("clean.raw", clean)
```

WAV files (must already be 48 kHz mono 16-bit):

```elixir
:ok = Rnnoise.denoise_file("noisy.wav", "clean.wav")
```

Streaming, one frame at a time, keeping the network's context across frames:

```elixir
state = Rnnoise.new()

# `frame` is exactly Rnnoise.frame_byte_size() (960) bytes
{vad, clean_frame} = Rnnoise.process_frame(state, frame)
# vad is the voice-activity probability (0.0..1.0) for that frame
```

`Rnnoise.denoise/2` does the same over a whole buffer while reusing a state:

```elixir
state = Rnnoise.new()
clean_chunk_1 = Rnnoise.denoise(state, chunk_1)
clean_chunk_2 = Rnnoise.denoise(state, chunk_2)  # continues the same stream
```

### Converting other formats with ffmpeg

```sh
# any input -> 48 kHz mono s16le WAV
ffmpeg -i input.mp3 -ar 48000 -ac 1 -c:a pcm_s16le noisy.wav
```

## Concurrency

A denoiser state is mutated in place on every call. Use one state per audio
stream and don't call a single state from multiple processes concurrently. The
underlying model is loaded once and shared read-only across all states.

## How it's built

`mix compile` runs the `Makefile`, which compiles `c_src/rnnoise_nif.c` together
with the vendored rnnoise sources (with `-DUSE_WEIGHTS_FILE`, so the weights are
loaded at runtime from the cached blob rather than baked into the binary) into
`priv/rnnoise_nif.so`. The weights blob itself is fetched separately at runtime
(see [The model weights](#the-model-weights)).

To build against your CPU's SIMD for extra speed:

```sh
OPTIMIZE="-O3 -march=native" mix compile
```

## Updating the vendored rnnoise

The vendored sources track a pinned upstream commit and model version
(`@default_hash` in `mix rnnoise.gen_blob`, currently `0a8755f8…`). To update:

1. Re-copy `src/*.{c,h}`, `src/x86/*.h`, `include/rnnoise.h` and
   `src/write_weights.c` from upstream.
2. The upstream `src/rnnoise_data.c` is ~78 MB (it embeds the weights). We build
   with `-DUSE_WEIGHTS_FILE` and load weights at runtime, so the embedded arrays
   are never compiled — strip them to keep `init_rnnoise()` only:

   ```sh
   # removes every `#ifndef USE_WEIGHTS_FILE … #endif /* USE_WEIGHTS_FILE */` block
   unifdef -DUSE_WEIGHTS_FILE -o c_src/rnnoise/src/rnnoise_data.c rnnoise_data.c || true
   ```

   (`unifdef` exits 1 when it makes changes — that's expected. The committed
   `rnnoise_data.c` is ~3 KB.)
3. Bump the hash in `lib/mix/tasks/rnnoise.gen_blob.ex`, regenerate the blob with
   `mix rnnoise.gen_blob`, and publish the new sha256 (set it as
   `@default_model_sha256` in `lib/rnnoise/model.ex`).

## Releasing (maintainers)

Distribution is via GitHub releases only — no Hex publish required. Everything
is automated by the `release` workflow on a pushed tag:

1. Bump `@version` in `mix.exs`, commit, push.
2. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`.

The workflow then:

- builds precompiled NIFs (macOS x86_64/arm64, Linux x86_64/arm64) and uploads
  them to the `v0.1.0` release;
- generates `weights_blob.bin` and uploads it to the same release;
- generates `checksum.exs` from the uploaded NIFs and **moves the `v0.1.0` tag**
  onto a commit that includes it, so git installs verify and use the precompiled
  NIFs (no compiler needed).

Keep `@version` in `mix.exs` equal to the tag (minus the `v`): the precompiled
NIF URL and the default model URL both resolve to `releases/download/v<version>/…`.

If you later want to publish to Hex too, run `mix elixir_make.checksum --all
--ignore-unavailable` (after the release artifacts exist) then `mix hex.publish`;
`checksum.exs` is already in the package `files`.

### Testing a precompiled Linux artifact locally

You can build and load-test the Linux NIFs in Docker, including from an Apple
Silicon host. The catch on Apple Silicon: the emulated x86_64 BEAM crashes under
QEMU unless you pass `ERL_FLAGS="+JPperf true"` (it changes how the JIT maps its
code so QEMU handles it):

```sh
# build the x86_64 artifact (Debian image has a compiler)
docker run --rm --platform linux/amd64 -e ERL_FLAGS="+JPperf true" \
  -v "$PWD":/src:ro elixir:1.18.4-otp-28 \
  bash -lc 'cp -r /src /b && cd /b && rm -rf _build deps cache && \
    mix deps.get && ELIXIR_MAKE_CACHE_DIR=/b/cache MIX_ENV=prod \
    mix elixir_make.precompile --ignore-unavailable && ls cache'
```

Loading the result in the minimal `hexpm/elixir:...-ubuntu-jammy` image (no
compiler) confirms the precompiled NIF works on the deploy target. Use
`--platform linux/arm64` for the aarch64 artifact (runs natively on Apple
Silicon, no `+JPperf` needed).

## License

BSD-3-Clause. The vendored rnnoise C code and model weights are © their
respective authors (Xiph.Org, Jean-Marc Valin, Mozilla, Amazon, Mark
Borgerding). See [LICENSE](LICENSE).
