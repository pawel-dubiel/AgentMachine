defmodule AgentMachine.RouterModelInstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.AgentMachine.RouterModel.Install

  test "router model installer pins an immutable revision and file hashes" do
    assert Install.model_revision() ==
             "08e97d4626c80790e50f75da74ed1fecfda644af"

    assert Install.file_specs() == [
             %{
               path: "tokenizer.json",
               sha256: "e23095eb61ba944c7be3a5d3e8ec19e37ce7ced0daa03550bde03e83c21b3f8a"
             },
             %{
               path: "config.json",
               sha256: "bc7b85f164a17c1b007d87fb99d3676f4a4d2e6511d2288dd3f5334dc0f34e6b"
             },
             %{
               path: "onnx/model_quantized.onnx",
               sha256: "18307c3bcb5d896a624c077af061b259d341829f3d13c8b3d49a044e28d4fe6a"
             }
           ]
  end

  test "router model installer rejects hash mismatches and unsafe download URLs" do
    assert_raise Mix.Error, ~r/SHA-256 mismatch/, fn ->
      Install.verify_download_body!("config.json", "{}")
    end

    assert_raise Mix.Error, ~r/unsafe router model download URL/, fn ->
      Install.validate_download_url!("http://huggingface.co/model")
    end

    assert_raise Mix.Error, ~r/unsafe router model download URL/, fn ->
      Install.validate_download_url!("https://example.com/model")
    end

    assert Install.validate_download_url!("https://huggingface.co/model") ==
             "https://huggingface.co/model"

    assert Install.validate_download_url!("https://cas-bridge.xethub.hf.co/model") ==
             "https://cas-bridge.xethub.hf.co/model"
  end
end
