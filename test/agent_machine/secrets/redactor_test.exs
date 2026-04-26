defmodule AgentMachine.Secrets.RedactorTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Secrets.Redactor

  test "redacts common API keys and tokens" do
    raw = """
    OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456
    Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456
    github_pat_abcdefghijklmnopqrstuvwxyz1234567890
    AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
    """

    result = Redactor.redact_string(raw)

    refute result.value =~ "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
    refute result.value =~ "abcdefghijklmnopqrstuvwxyz123456"
    refute result.value =~ "github_pat_abcdefghijklmnopqrstuvwxyz1234567890"
    refute result.value =~ "AKIAIOSFODNN7EXAMPLE"
    assert result.redacted == true
    assert result.count >= 4
    assert "secret_assignment" in result.reasons
  end

  test "preserves text without sensitive values" do
    text = "normal project notes with no credentials"

    assert %{value: ^text, redacted: false, count: 0, reasons: []} =
             Redactor.redact_string(text)
  end

  test "redacts assignment values that do not match token-specific patterns" do
    result = Redactor.redact_string(~s(database_password="short-secret"))

    refute result.value =~ "short-secret"
    assert result.value == ~s(database_password="[REDACTED:secret_assignment]")
    assert result.count == 1
  end

  test "recursively redacts serializable values and reports metadata" do
    value = %{
      output: "token=sk-proj-abcdefghijklmnopqrstuvwxyz123456",
      nested: [%{header: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"}]
    }

    result = Redactor.redact_output(value)

    refute result.value.output =~ "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
    refute hd(result.value.nested).header =~ "abcdefghijklmnopqrstuvwxyz123456"
    assert result.value.redaction.redacted == true
    assert result.value.redaction.count >= 2
  end
end
