defmodule AgentMachine.ModelOutputJSON do
  @moduledoc false

  def decode_object!(binary, label) when is_binary(binary) and is_binary(label) do
    decode_object!(binary, label, "invalid #{label}")
  end

  def decode_object!(value, label) when is_binary(label) do
    raise ArgumentError, "#{label} input must be a binary, got: #{inspect(value)}"
  end

  def decode_object!(_value, label) do
    raise ArgumentError, "model output JSON label must be a binary, got: #{inspect(label)}"
  end

  def decode_object!(binary, label, invalid_label)
      when is_binary(binary) and is_binary(label) and is_binary(invalid_label) do
    text = String.trim(binary)

    case Jason.decode(text) do
      {:ok, %{} = decoded} ->
        decoded

      {:ok, decoded} ->
        raise ArgumentError, "#{label} must be a JSON object, got: #{inspect(decoded)}"

      {:error, strict_error} ->
        decode_embedded_object!(text, label, invalid_label, strict_error)
    end
  end

  defp decode_embedded_object!(text, label, invalid_label, strict_error) do
    case first_embedded_object(text) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = decoded} ->
            decoded

          {:ok, decoded} ->
            raise ArgumentError, "#{label} must be a JSON object, got: #{inspect(decoded)}"

          {:error, error} ->
            raise ArgumentError, "#{invalid_label}: #{Exception.message(error)}"
        end

      :error ->
        raise ArgumentError, "#{invalid_label}: #{Exception.message(strict_error)}"
    end
  end

  defp first_embedded_object(<<"{", _rest::binary>> = candidate) do
    case take_balanced_object(candidate) do
      {:ok, json} ->
        {:ok, json}

      :error ->
        <<_byte, rest::binary>> = candidate
        first_embedded_object(rest)
    end
  end

  defp first_embedded_object(<<_byte, rest::binary>>), do: first_embedded_object(rest)

  defp first_embedded_object(<<>>), do: :error

  defp take_balanced_object(candidate), do: take_balanced_object(candidate, "", 0, false, false)

  defp take_balanced_object(<<>>, _acc, _depth, _in_string?, _escaped?), do: :error

  defp take_balanced_object(<<byte, rest::binary>>, acc, depth, true, true) do
    take_balanced_object(rest, acc <> <<byte>>, depth, true, false)
  end

  defp take_balanced_object(<<"\\", rest::binary>>, acc, depth, true, false) do
    take_balanced_object(rest, acc <> "\\", depth, true, true)
  end

  defp take_balanced_object(<<"\"", rest::binary>>, acc, depth, true, false) do
    take_balanced_object(rest, acc <> "\"", depth, false, false)
  end

  defp take_balanced_object(<<byte, rest::binary>>, acc, depth, true, false) do
    take_balanced_object(rest, acc <> <<byte>>, depth, true, false)
  end

  defp take_balanced_object(<<"\"", rest::binary>>, acc, depth, false, false) do
    take_balanced_object(rest, acc <> "\"", depth, true, false)
  end

  defp take_balanced_object(<<"{", rest::binary>>, acc, depth, false, false) do
    take_balanced_object(rest, acc <> "{", depth + 1, false, false)
  end

  defp take_balanced_object(<<"}", _rest::binary>>, acc, 1, false, false), do: {:ok, acc <> "}"}

  defp take_balanced_object(<<"}", rest::binary>>, acc, depth, false, false) when depth > 1 do
    take_balanced_object(rest, acc <> "}", depth - 1, false, false)
  end

  defp take_balanced_object(<<byte, rest::binary>>, acc, depth, false, false) do
    take_balanced_object(rest, acc <> <<byte>>, depth, false, false)
  end
end
