defmodule Rnnoise.DownloadTest do
  # Exercises the real download -> sha256 verify -> cache -> load path against a
  # local HTTP server. Not async: it temporarily overrides :rnnoise app env.
  use ExUnit.Case, async: false

  @moduletag :needs_model

  setup do
    blob_path = Application.get_env(:rnnoise, :model_path)
    blob = File.read!(blob_path)
    sha = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)

    # Serve the blob from a temp document root over localhost.
    doc_root = Path.join(System.tmp_dir!(), "rnnoise_doc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(doc_root)
    File.write!(Path.join(doc_root, "weights_blob.bin"), blob)

    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, httpd} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"rnnoise-test",
        server_root: String.to_charlist(doc_root),
        document_root: String.to_charlist(doc_root),
        bind_address: {127, 0, 0, 1},
        modules: [:mod_alias, :mod_get, :mod_head, :mod_dir]
      )

    port = :httpd.info(httpd)[:port]

    cache = Path.join(System.tmp_dir!(), "rnnoise_cache_#{System.unique_integer([:positive])}")
    prev_cache = Application.get_env(:rnnoise, :cache_dir)
    Application.put_env(:rnnoise, :cache_dir, cache)

    on_exit(fn ->
      :inets.stop(:httpd, httpd)
      Application.put_env(:rnnoise, :cache_dir, prev_cache)
      File.rm_rf(doc_root)
      File.rm_rf(cache)
      Rnnoise.Model.clear()
    end)

    %{url: "http://127.0.0.1:#{port}/weights_blob.bin", sha: sha, cache: cache}
  end

  test "downloads, sha-verifies, caches and loads a model over http", %{
    url: url,
    sha: sha,
    cache: cache
  } do
    assert {:ok, ref} = Rnnoise.Model.get({:url, url, sha})
    assert is_reference(ref)

    # The blob landed in the (content-addressed) cache.
    assert File.exists?(Path.join(cache, "rnnoise-#{sha}.bin"))

    # And the downloaded model actually denoises.
    state = Rnnoise.Nif.create(ref)
    frame = :binary.copy(<<0::16-little-signed>>, Rnnoise.frame_size())
    {vad, out} = Rnnoise.process_frame(state, frame)
    assert is_float(vad)
    assert byte_size(out) == Rnnoise.frame_byte_size()
  end

  test "a wrong sha256 is rejected", %{url: url} do
    bad = String.duplicate("00", 32)
    assert {:error, {:checksum_mismatch, ^bad, _got}} = Rnnoise.Model.get({:url, url, bad})
  end

  test "second get/1 reuses the cached file (server can be down)", %{
    url: url,
    sha: sha
  } do
    assert {:ok, _ref} = Rnnoise.Model.get({:url, url, sha})
    # Clear the loaded-model memo but keep the on-disk cache; resolve again.
    Rnnoise.Model.clear()
    assert {:ok, path} = Rnnoise.Model.ensure_blob({:url, url, sha})
    assert File.exists?(path)
  end
end
