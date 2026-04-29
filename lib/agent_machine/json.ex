defmodule AgentMachine.JSON do
  @moduledoc false

  def encode!(value) do
    IO.iodata_to_binary(encode_value(value))
  end

  def decode!(binary) when is_binary(binary) do
    {value, rest} = parse_value(skip_ws(binary))

    case skip_ws(rest) do
      "" -> value
      extra -> raise ArgumentError, "invalid JSON trailing data: #{inspect(extra)}"
    end
  end

  defp encode_value(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, val} ->
        [encode_string(to_json_key!(key)), ?:, encode_value(val)]
      end)
      |> Enum.intersperse(?,)

    [?{, entries, ?}]
  end

  defp encode_value(value) when is_list(value) do
    [?[, value |> Enum.map(&encode_value/1) |> Enum.intersperse(?,), ?]]
  end

  defp encode_value(value) when is_binary(value), do: encode_string(value)
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"

  defp encode_value(value) do
    raise ArgumentError, "unsupported JSON value: #{inspect(value)}"
  end

  defp to_json_key!(key) when is_binary(key), do: key
  defp to_json_key!(key) when is_atom(key), do: Atom.to_string(key)

  defp to_json_key!(key) do
    raise ArgumentError, "JSON object keys must be atoms or binaries, got: #{inspect(key)}"
  end

  defp encode_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
      |> String.replace("\b", "\\b")
      |> String.replace("\f", "\\f")

    [?", escaped, ?"]
  end

  defp parse_value(<<"{", rest::binary>>), do: parse_object(skip_ws(rest), %{})
  defp parse_value(<<"[", rest::binary>>), do: parse_array(skip_ws(rest), [])
  defp parse_value(<<"\"", rest::binary>>), do: parse_string(rest, [])
  defp parse_value(<<"true", rest::binary>>), do: {true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {false, rest}
  defp parse_value(<<"null", rest::binary>>), do: {nil, rest}

  defp parse_value(binary) do
    parse_number(binary)
  end

  defp parse_object(<<"}", rest::binary>>, acc), do: {acc, rest}

  defp parse_object(binary, acc) do
    {key, after_key} = parse_value(binary)

    unless is_binary(key) do
      raise ArgumentError, "JSON object key must be a string, got: #{inspect(key)}"
    end

    after_colon =
      case skip_ws(after_key) do
        <<":", rest::binary>> -> skip_ws(rest)
        other -> raise ArgumentError, "expected JSON object colon, got: #{inspect(other)}"
      end

    {value, after_value} = parse_value(after_colon)
    next = skip_ws(after_value)
    acc = Map.put(acc, key, value)

    case next do
      <<",", rest::binary>> -> parse_object(skip_ws(rest), acc)
      <<"}", rest::binary>> -> {acc, rest}
      other -> raise ArgumentError, "expected JSON object comma or end, got: #{inspect(other)}"
    end
  end

  defp parse_array(<<"]", rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp parse_array(binary, acc) do
    {value, after_value} = parse_value(binary)
    next = skip_ws(after_value)

    case next do
      <<",", rest::binary>> -> parse_array(skip_ws(rest), [value | acc])
      <<"]", rest::binary>> -> {Enum.reverse([value | acc]), rest}
      other -> raise ArgumentError, "expected JSON array comma or end, got: #{inspect(other)}"
    end
  end

  defp parse_string(<<"\"", rest::binary>>, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp parse_string(<<"\\\"", rest::binary>>, acc), do: parse_string(rest, [?\" | acc])
  defp parse_string(<<"\\\\", rest::binary>>, acc), do: parse_string(rest, [?\\ | acc])
  defp parse_string(<<"\\/", rest::binary>>, acc), do: parse_string(rest, [?/ | acc])
  defp parse_string(<<"\\b", rest::binary>>, acc), do: parse_string(rest, [?\b | acc])
  defp parse_string(<<"\\f", rest::binary>>, acc), do: parse_string(rest, [?\f | acc])
  defp parse_string(<<"\\n", rest::binary>>, acc), do: parse_string(rest, [?\n | acc])
  defp parse_string(<<"\\r", rest::binary>>, acc), do: parse_string(rest, [?\r | acc])
  defp parse_string(<<"\\t", rest::binary>>, acc), do: parse_string(rest, [?\t | acc])

  defp parse_string(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    codepoint = parse_hex4!(hex)
    parse_unicode_escape(codepoint, rest, acc)
  end

  defp parse_string(<<char::utf8, rest::binary>>, acc) do
    parse_string(rest, [<<char::utf8>> | acc])
  end

  defp parse_string("", _acc) do
    raise ArgumentError, "unterminated JSON string"
  end

  defp parse_unicode_escape(high, <<"\\u", low_hex::binary-size(4), rest::binary>>, acc)
       when high in 0xD800..0xDBFF do
    low = parse_hex4!(low_hex)

    if low in 0xDC00..0xDFFF do
      codepoint = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
      parse_string(rest, [<<codepoint::utf8>> | acc])
    else
      raise ArgumentError,
            "invalid JSON unicode escape: high surrogate must be followed by low surrogate"
    end
  end

  defp parse_unicode_escape(high, _rest, _acc) when high in 0xD800..0xDBFF do
    raise ArgumentError,
          "invalid JSON unicode escape: high surrogate must be followed by low surrogate"
  end

  defp parse_unicode_escape(low, _rest, _acc) when low in 0xDC00..0xDFFF do
    raise ArgumentError, "invalid JSON unicode escape: lone low surrogate"
  end

  defp parse_unicode_escape(codepoint, rest, acc) do
    parse_string(rest, [<<codepoint::utf8>> | acc])
  end

  defp parse_hex4!(hex) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} ->
        codepoint

      _other ->
        raise ArgumentError, "invalid JSON unicode escape: \\u#{hex}"
    end
  end

  defp parse_number(binary) do
    case Regex.run(~r/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/, binary) do
      [number] ->
        rest = binary_part(binary, byte_size(number), byte_size(binary) - byte_size(number))

        value =
          cond do
            String.contains?(number, ".") ->
              String.to_float(number)

            String.contains?(number, ["e", "E"]) ->
              number |> exponent_number_to_float_string() |> String.to_float()

            true ->
              String.to_integer(number)
          end

        {value, rest}

      _ ->
        raise ArgumentError, "invalid JSON value: #{inspect(binary)}"
    end
  end

  defp exponent_number_to_float_string(number) do
    case Regex.run(~r/^(-?(?:0|[1-9]\d*))([eE][+-]?\d+)$/, number) do
      [_, coefficient, exponent] -> coefficient <> ".0" <> exponent
      _other -> number
    end
  end

  defp skip_ws(<<char, rest::binary>>) when char in [?\s, ?\n, ?\r, ?\t], do: skip_ws(rest)
  defp skip_ws(binary), do: binary
end
