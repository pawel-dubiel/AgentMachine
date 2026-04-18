package main

import "testing"

func TestBuildRunArgsIncludesExplicitRuntimeOptions(t *testing.T) {
	args := buildRunArgs("review this project")

	expected := []string{
		"agent_machine.run",
		"--provider", "echo",
		"--timeout-ms", "5000",
		"--max-steps", "2",
		"--max-attempts", "1",
		"--json",
		"review this project",
	}

	if len(args) != len(expected) {
		t.Fatalf("expected %d args, got %d: %#v", len(expected), len(args), args)
	}

	for i := range expected {
		if args[i] != expected[i] {
			t.Fatalf("arg %d mismatch: expected %q, got %q", i, expected[i], args[i])
		}
	}
}

func TestParseSummary(t *testing.T) {
	parsed, err := parseSummary(`Compiling 10 files (.ex)
Generated agent_machine app
{"run_id":"run-1","status":"completed","final_output":"done","usage":{"agents":2,"input_tokens":3,"output_tokens":4,"total_tokens":7,"cost_usd":0},"events":[{"type":"run_started"},{"type":"run_completed"}]}`)
	if err != nil {
		t.Fatalf("expected parse to succeed, got %v", err)
	}

	if parsed.RunID != "run-1" {
		t.Fatalf("unexpected run id: %q", parsed.RunID)
	}

	if parsed.Usage.TotalTokens != 7 {
		t.Fatalf("unexpected total tokens: %d", parsed.Usage.TotalTokens)
	}

	if len(parsed.Events) != 2 {
		t.Fatalf("unexpected event count: %d", len(parsed.Events))
	}
}

func TestParseSummaryRequiresJSONLine(t *testing.T) {
	_, err := parseSummary("Compiling files\nGenerated app")
	if err == nil {
		t.Fatal("expected parse error")
	}
}
