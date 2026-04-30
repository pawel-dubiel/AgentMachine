package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

func TestBuildRunArgsIncludesExplicitRuntimeOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "review this project",
		Workflow: workflowBasic,
		Provider: providerEcho,
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "basic",
		"--provider", "echo",
		"--timeout-ms", defaultRunTimeoutMS,
		"--max-steps", "2",
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
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

func TestBuildRunArgsIncludesOpenRouterOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:        "review this project",
		Workflow:    workflowAgentic,
		Provider:    providerOpenRouter,
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.60",
		HTTPTimeout: "120000",
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "agentic",
		"--provider", "openrouter",
		"--timeout-ms", defaultAgenticRunTimeoutMS,
		"--max-steps", defaultAgenticSteps,
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
		"--model", "openai/gpt-4o-mini",
		"--http-timeout-ms", "120000",
		"--input-price-per-million", "0.15",
		"--output-price-per-million", "0.60",
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

func TestBuildRunArgsUsesExplicitRunTimeoutWhenProvided(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:       "review this project",
		Workflow:   workflowAuto,
		Provider:   providerEcho,
		RunTimeout: "240000",
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "auto",
		"--provider", "echo",
		"--timeout-ms", "240000",
		"--max-steps", defaultAgenticSteps,
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
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

func TestBuildRunArgsIncludesLocalRouterOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:             "review this project",
		Workflow:         workflowAuto,
		Provider:         providerEcho,
		RouterMode:       "local",
		RouterModelDir:   "/tmp/agent-machine-router-model",
		RouterTimeout:    "5000",
		RouterConfidence: "0.55",
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "auto",
		"--provider", "echo",
		"--timeout-ms", defaultAgenticRunTimeoutMS,
		"--max-steps", defaultAgenticSteps,
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
		"--router-mode", "local",
		"--router-model-dir", "/tmp/agent-machine-router-model",
		"--router-timeout-ms", "5000",
		"--router-confidence-threshold", "0.55",
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

func TestBuildRunArgsIncludesSessionEventLog(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:           "review this project",
		Workflow:       workflowAuto,
		Provider:       providerEcho,
		EventLogFile:   "/tmp/agent-machine-session.jsonl",
		EventSessionID: "session-1",
	})

	assertContainsSequence(t, args, []string{"--event-log-file", "/tmp/agent-machine-session.jsonl"})
	assertContainsSequence(t, args, []string{"--event-session-id", "session-1"})
}

func TestBuildRunArgsIncludesContextOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:              "review this project",
		Workflow:          workflowAgentic,
		Provider:          providerEcho,
		ContextWindow:     "128000",
		ContextWarning:    "80",
		RunContextCompact: "on",
		ContextCompactPct: "90",
		MaxContextCompact: "2",
	})

	assertContainsSequence(t, args, []string{"--context-window-tokens", "128000"})
	assertContainsSequence(t, args, []string{"--context-warning-percent", "80"})
	assertContainsSequence(t, args, []string{"--run-context-compaction", "on"})
	assertContainsSequence(t, args, []string{"--run-context-compact-percent", "90"})
	assertContainsSequence(t, args, []string{"--max-context-compactions", "2"})
}

func TestBuildRunArgsUsesLongerTimeoutForAutoRuns(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "fix the existing app",
		Workflow: workflowAuto,
		Provider: providerEcho,
	})

	assertContainsSequence(t, args, []string{"--timeout-ms", defaultAgenticRunTimeoutMS})
}

func TestBuildRunArgsIncludesLocalFileToolHarness(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "create hello",
		Workflow:      workflowBasic,
		Provider:      providerOpenRouter,
		Model:         "qwen/qwen3.5-flash-02-23",
		InputPrice:    "0.01",
		OutputPrice:   "0.01",
		HTTPTimeout:   "120000",
		ToolHarness:   "local-files",
		ToolRoot:      "/tmp/agent-machine-wiki",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "auto-approved-safe",
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "basic",
		"--provider", "openrouter",
		"--timeout-ms", defaultRunTimeoutMS,
		"--max-steps", defaultBasicSteps,
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
		"--model", "qwen/qwen3.5-flash-02-23",
		"--http-timeout-ms", "120000",
		"--input-price-per-million", "0.01",
		"--output-price-per-million", "0.01",
		"--tool-harness", "local-files",
		"--tool-timeout-ms", "1000",
		"--tool-max-rounds", "2",
		"--tool-approval-mode", "auto-approved-safe",
		"--tool-root", "/tmp/agent-machine-wiki",
		"create hello",
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

func TestBuildRunArgsIncludesRunLogFile(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "review this project",
		Workflow: workflowBasic,
		Provider: providerEcho,
		LogFile:  "/tmp/agent-machine-run.jsonl",
	})

	if !containsArgPair(args, "--log-file", "/tmp/agent-machine-run.jsonl") {
		t.Fatalf("expected --log-file args, got %#v", args)
	}
}

func TestBuildRunArgsIncludesRepeatedTestCommands(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "verify changes",
		Workflow:      workflowBasic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "full-access",
		TestCommands:  []string{"mix test", "go test ./..."},
	})

	if !containsArgPair(args, "--test-command", "mix test") {
		t.Fatalf("expected mix test command arg, got %#v", args)
	}
	if !containsArgPair(args, "--test-command", "go test ./...") {
		t.Fatalf("expected go test command arg, got %#v", args)
	}
}

func TestBuildRunArgsIncludesAutoSkills(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:       "write docs",
		Workflow:   workflowAgentic,
		Provider:   providerEcho,
		SkillsMode: "auto",
		SkillsDir:  "/tmp/agent-machine-skills",
	})

	assertContainsSequence(t, args, []string{"--skills", "auto", "--skills-dir", "/tmp/agent-machine-skills"})
}

func TestBuildRunArgsIncludesExplicitSkills(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:       "write docs",
		Workflow:   workflowAgentic,
		Provider:   providerEcho,
		SkillsDir:  "/tmp/agent-machine-skills",
		SkillNames: []string{"docs-helper", "review-helper"},
	})

	assertContainsSequence(t, args, []string{"--skills-dir", "/tmp/agent-machine-skills", "--skill", "docs-helper", "--skill", "review-helper"})
}

func TestBuildRunArgsIncludesMCPConfigAsRepeatedHarness(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "search docs",
		Workflow:      workflowBasic,
		Provider:      providerEcho,
		ToolHarness:   "local-files",
		ToolRoot:      "/tmp/project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "read-only",
		MCPConfig:     "/tmp/agent-machine.mcp.json",
	})

	assertContainsSequence(t, args, []string{"--tool-harness", "local-files"})
	assertContainsSequence(t, args, []string{"--tool-harness", "mcp", "--mcp-config", "/tmp/agent-machine.mcp.json"})
}

func TestPrepareRunLogCreatesPrivateDirectory(t *testing.T) {
	logFile := filepath.Join(t.TempDir(), "agent-machine", "logs", "run.jsonl")

	if err := prepareRunLog(runConfig{LogFile: logFile}); err != nil {
		t.Fatalf("expected log directory preparation to succeed, got %v", err)
	}

	info, err := os.Stat(filepath.Dir(logFile))
	if err != nil {
		t.Fatalf("expected log directory to exist, got %v", err)
	}
	if !info.IsDir() {
		t.Fatalf("expected log parent to be a directory")
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("expected log directory permissions 0700, got %o", got)
	}
}

func TestRunningStatusIncludesToolState(t *testing.T) {
	withoutTools := runningStatus(runConfig{
		Workflow: workflowAuto,
		Provider: providerOpenRouter,
		Model:    "qwen/qwen3.5-flash-02-23",
	})

	if !strings.Contains(withoutTools, "tools off") {
		t.Fatalf("expected tools off in running status, got %q", withoutTools)
	}
	if !strings.Contains(withoutTools, "mode progressive-auto") {
		t.Fatalf("expected progressive auto mode in running status, got %q", withoutTools)
	}
	if !strings.Contains(withoutTools, "router deterministic") {
		t.Fatalf("expected deterministic router in running status, got %q", withoutTools)
	}
	if !strings.Contains(withoutTools, "idle_timeout_ms="+defaultAgenticRunTimeoutMS+" hard_cap_ms=720000") {
		t.Fatalf("expected auto idle lease and hard cap in running status, got %q", withoutTools)
	}

	withTools := runningStatus(runConfig{
		Workflow:    workflowAuto,
		Provider:    providerOpenRouter,
		Model:       "qwen/qwen3.5-flash-02-23",
		ToolHarness: "local-files",
		ToolRoot:    "/tmp/agent-machine-home",
	})

	if !strings.Contains(withTools, "tools local-files root=/tmp/agent-machine-home") {
		t.Fatalf("expected tool root in running status, got %q", withTools)
	}

	withLocalRouter := runningStatus(runConfig{
		Workflow:         workflowAuto,
		Provider:         providerOpenRouter,
		Model:            "qwen/qwen3.5-flash-02-23",
		RouterMode:       "local",
		RouterModelDir:   "/tmp/agent-machine-router-model",
		RouterTimeout:    "5000",
		RouterConfidence: "0.55",
	})

	if !strings.Contains(withLocalRouter, "router local dir=/tmp/agent-machine-router-model timeout_ms=5000 confidence=0.55") {
		t.Fatalf("expected local router in running status, got %q", withLocalRouter)
	}
}

func TestBuildRunArgsIncludesCodeEditToolHarness(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "edit code",
		Workflow:      workflowBasic,
		Provider:      providerOpenRouter,
		Model:         "qwen/qwen3.5-flash-02-23",
		InputPrice:    "0.01",
		OutputPrice:   "0.01",
		HTTPTimeout:   "120000",
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "full-access",
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "basic",
		"--provider", "openrouter",
		"--timeout-ms", defaultRunTimeoutMS,
		"--max-steps", defaultBasicSteps,
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
		"--model", "qwen/qwen3.5-flash-02-23",
		"--http-timeout-ms", "120000",
		"--input-price-per-million", "0.01",
		"--output-price-per-million", "0.01",
		"--tool-harness", "code-edit",
		"--tool-timeout-ms", "1000",
		"--tool-max-rounds", "2",
		"--tool-approval-mode", "full-access",
		"--tool-root", "/tmp/agent-machine-project",
		"edit code",
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

func TestBuildRunArgsIncludesTimeToolHarness(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "what time is it?",
		Workflow:      workflowAuto,
		Provider:      providerEcho,
		ToolHarness:   "time",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "read-only",
	})

	expected := []string{
		"agent_machine.run",
		"--workflow", "auto",
		"--provider", "echo",
		"--timeout-ms", defaultAgenticRunTimeoutMS,
		"--max-steps", defaultAgenticSteps,
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
		"--tool-harness", "time",
		"--tool-timeout-ms", "1000",
		"--tool-max-rounds", "2",
		"--tool-approval-mode", "read-only",
		"what time is it?",
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

func TestValidateConfigRequiresOpenRouterKey(t *testing.T) {
	err := validateConfig(runConfig{
		Task:        "review this project",
		Workflow:    workflowBasic,
		Provider:    providerOpenRouter,
		APIKey:      "",
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.60",
		HTTPTimeout: "120000",
	})

	if err == nil {
		t.Fatal("expected missing key error")
	}
}

func TestPaidOpenRouterModelUsesDefaultWhenUnset(t *testing.T) {
	t.Setenv("AGENT_MACHINE_PAID_OPENROUTER_MODEL", "")
	os.Unsetenv("AGENT_MACHINE_PAID_OPENROUTER_MODEL")

	if model := paidOpenRouterModel(t); model != defaultPaidOpenRouterModel {
		t.Fatalf("expected default paid OpenRouter model %q, got %q", defaultPaidOpenRouterModel, model)
	}
}

func TestPaidOpenRouterModelUsesExplicitEnvironmentValue(t *testing.T) {
	t.Setenv("AGENT_MACHINE_PAID_OPENROUTER_MODEL", " openai/gpt-4o-mini ")

	if model := paidOpenRouterModel(t); model != "openai/gpt-4o-mini" {
		t.Fatalf("expected explicit paid OpenRouter model, got %q", model)
	}
}

func TestValidateConfigAcceptsExplicitOpenRouterConfig(t *testing.T) {
	err := validateConfig(runConfig{
		Task:        "review this project",
		Workflow:    workflowBasic,
		Provider:    providerOpenRouter,
		APIKey:      "test-key",
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.60",
		HTTPTimeout: "120000",
	})

	if err != nil {
		t.Fatalf("expected valid config, got %v", err)
	}
}

func TestValidateConfigAcceptsLocalRouterConfig(t *testing.T) {
	err := validateConfig(runConfig{
		Task:             "review this project",
		Workflow:         workflowAuto,
		Provider:         providerEcho,
		RouterMode:       "local",
		RouterModelDir:   "/tmp/agent-machine-router-model",
		RouterTimeout:    "5000",
		RouterConfidence: "0.55",
	})

	if err != nil {
		t.Fatalf("expected valid local router config, got %v", err)
	}
}

func TestValidateConfigRejectsInvalidLocalRouterConfig(t *testing.T) {
	err := validateConfig(runConfig{
		Task:             "review this project",
		Workflow:         workflowAuto,
		Provider:         providerEcho,
		RouterMode:       "local",
		RouterTimeout:    "5000",
		RouterConfidence: "0.55",
	})

	if err == nil || !strings.Contains(err.Error(), "router model dir") {
		t.Fatalf("expected router model dir error, got %v", err)
	}

	err = validateConfig(runConfig{
		Task:             "review this project",
		Workflow:         workflowAuto,
		Provider:         providerEcho,
		RouterMode:       "local",
		RouterModelDir:   "/tmp/agent-machine-router-model",
		RouterTimeout:    "0",
		RouterConfidence: "0.55",
	})

	if err == nil || !strings.Contains(err.Error(), "router timeout ms") {
		t.Fatalf("expected router timeout error, got %v", err)
	}

	err = validateConfig(runConfig{
		Task:             "review this project",
		Workflow:         workflowAuto,
		Provider:         providerEcho,
		RouterMode:       "local",
		RouterModelDir:   "/tmp/agent-machine-router-model",
		RouterTimeout:    "5000",
		RouterConfidence: "1.5",
	})

	if err == nil || !strings.Contains(err.Error(), "router confidence") {
		t.Fatalf("expected router confidence error, got %v", err)
	}
}

func TestValidateConfigRequiresToolRootForLocalFiles(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "write a file",
		Workflow:      workflowBasic,
		Provider:      providerEcho,
		ToolHarness:   "local-files",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "auto-approved-safe",
	})

	if err == nil || !strings.Contains(err.Error(), "tool root") {
		t.Fatalf("expected tool root error, got %v", err)
	}
}

func TestValidateConfigRequiresToolMaxRoundsForLocalFiles(t *testing.T) {
	err := validateConfig(runConfig{
		Task:        "write a file",
		Workflow:    workflowBasic,
		Provider:    providerEcho,
		ToolHarness: "local-files",
		ToolRoot:    "/tmp/agent-machine-wiki",
		ToolTimeout: "1000",
	})

	if err == nil || !strings.Contains(err.Error(), "tool max rounds") {
		t.Fatalf("expected tool max rounds error, got %v", err)
	}
}

func TestValidateConfigAcceptsCodeEditHarness(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "edit code",
		Workflow:      workflowBasic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "full-access",
	})

	if err != nil {
		t.Fatalf("expected valid code-edit config, got %v", err)
	}
}

func TestValidateConfigAcceptsTimeHarness(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "what time is it?",
		Workflow:      workflowAuto,
		Provider:      providerEcho,
		ToolHarness:   "time",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "read-only",
	})

	if err != nil {
		t.Fatalf("expected valid time harness config, got %v", err)
	}
}

func TestValidateConfigRejectsTimeHarnessRoot(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "what time is it?",
		Workflow:      workflowAuto,
		Provider:      providerEcho,
		ToolHarness:   "time",
		ToolRoot:      "/tmp/agent-machine-time",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "read-only",
	})

	if err == nil || !strings.Contains(err.Error(), "time tool harness") {
		t.Fatalf("expected time harness root error, got %v", err)
	}
}

func TestValidateConfigRequiresSkillsDirForAutoSkills(t *testing.T) {
	err := validateConfig(runConfig{
		Task:       "write docs",
		Workflow:   workflowAgentic,
		Provider:   providerEcho,
		SkillsMode: "auto",
	})

	if err == nil || !strings.Contains(err.Error(), "skills dir") {
		t.Fatalf("expected skills dir error, got %v", err)
	}
}

func TestValidateConfigRejectsAutoSkillsWithExplicitNames(t *testing.T) {
	err := validateConfig(runConfig{
		Task:       "write docs",
		Workflow:   workflowAgentic,
		Provider:   providerEcho,
		SkillsMode: "auto",
		SkillsDir:  "/tmp/skills",
		SkillNames: []string{"docs-helper"},
	})

	if err == nil || !strings.Contains(err.Error(), "cannot be combined") {
		t.Fatalf("expected skills mode error, got %v", err)
	}
}

func TestValidateConfigRequiresToolApprovalMode(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "edit code",
		Workflow:      workflowBasic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
	})

	if err == nil || !strings.Contains(err.Error(), "approval mode") {
		t.Fatalf("expected approval mode error, got %v", err)
	}
}

func TestAgentDetailRendersToolEvents(t *testing.T) {
	lines := agentEventLines([]eventSummary{
		{
			Type:       "tool_call_finished",
			ToolCallID: "call-1",
			Tool:       "write_file",
			Round:      1,
			Status:     "ok",
		},
	})

	if !strings.Contains(lines, "tool=write_file call=call-1 status=ok round=1") {
		t.Fatalf("expected rendered tool event, got %q", lines)
	}
}

func TestAgentDetailCompactsHeartbeatEvents(t *testing.T) {
	lines := agentEventLines([]eventSummary{
		{Type: "agent_started", AgentID: "builder", Summary: "builder started attempt 1"},
		{Type: "agent_heartbeat", AgentID: "builder", Summary: "builder heartbeat", Status: "running"},
		{Type: "agent_heartbeat", AgentID: "builder", Summary: "builder heartbeat", Status: "running"},
		{Type: "agent_heartbeat", AgentID: "builder", Summary: "builder heartbeat", Status: "running"},
	})

	if strings.Count(lines, "builder heartbeat") != 1 || !strings.Contains(lines, "x3") {
		t.Fatalf("expected compact heartbeat line, got %q", lines)
	}
}

func TestLiveActivityCompactsReadOnlyToolEvents(t *testing.T) {
	lines := compactEventDisplayLines([]eventSummary{
		{Type: "tool_call_finished", AgentID: "worker", Tool: "read_file", Status: "ok", Summary: "worker read README.md"},
		{Type: "tool_call_finished", AgentID: "worker", Tool: "read_file", Status: "ok", Summary: "worker read lib/app.ex"},
		{Type: "tool_call_failed", AgentID: "worker", Tool: "read_file", Status: "error", Summary: "worker failed read_file: denied"},
	})

	rendered := strings.Join(lines, "\n")
	if !strings.Contains(rendered, "worker read lib/app.ex") || !strings.Contains(rendered, "x2") {
		t.Fatalf("expected repeated read events to collapse, got %q", rendered)
	}
	if !strings.Contains(rendered, "worker failed read_file: denied") {
		t.Fatalf("expected errors to remain visible, got %q", rendered)
	}
}

func TestAgentDetailShowsRunningPlaceholders(t *testing.T) {
	m := model{
		selectedAgent: "setup-nextjs",
		agents: map[string]agentState{
			"setup-nextjs": {
				ID:        "setup-nextjs",
				Status:    "running",
				Attempt:   1,
				StartedAt: "2026-04-25T10:00:00Z",
				Events: []eventSummary{
					{Type: "provider_request_started", AgentID: "setup-nextjs", Summary: "setup-nextjs sent provider request"},
				},
			},
		},
	}

	view := m.agentDetailView()
	for _, expected := range []string{
		"(pending until agent finishes)",
		"(provider request in progress; no streamed output yet)",
		"(none so far)",
	} {
		if !strings.Contains(view, expected) {
			t.Fatalf("expected %q in detail view, got %q", expected, view)
		}
	}
}

func TestEventDisplayLineDoesNotRenderAssistantDeltaContent(t *testing.T) {
	line := eventDisplayLine(eventSummary{
		Type:    "assistant_delta",
		AgentID: "builder1",
		Summary: "builder1 streamed text",
		Delta:   "hello\nfrom the streamed answer",
	})

	if !strings.Contains(line, "builder1 streamed text") {
		t.Fatalf("expected streamed text summary, got %q", line)
	}
	if strings.Contains(line, "hello") || strings.Contains(line, "streamed answer") {
		t.Fatalf("expected streamed content to stay hidden, got %q", line)
	}
}

func TestChatViewRendersThinkingAnimationWithoutStreamedText(t *testing.T) {
	m := model{
		running:       true,
		streamFrame:   1,
		liveAssistant: "hidden streamed content",
		messages:      []chatMessage{{Role: "user", Text: "hello"}},
		eventLog: []eventSummary{
			{Type: "provider_request_started", Summary: "assistant sent provider request"},
		},
	}

	view := m.chatView()

	if !strings.Contains(view, "thinking /") {
		t.Fatalf("expected thinking animation, got %q", view)
	}
	if strings.Contains(view, "hidden streamed content") {
		t.Fatalf("expected streamed text to stay hidden, got %q", view)
	}
}

func TestChatViewWrapsLongSystemMessages(t *testing.T) {
	m := model{
		width: 44,
		messages: []chatMessage{
			{
				Role: "system",
				Text: "running OpenRouter / openai/gpt-5.1-codex-mini / router local dir=/Users/pawel/Library/Application Support/agent-machine/router-models/mdeberta-v3-base-xnli-multilingual-nli-2mil7",
			},
		},
	}

	view := m.chatView()

	if !strings.Contains(view, "\n        ") {
		t.Fatalf("expected wrapped continuation line with role indentation, got %q", view)
	}
	if strings.Contains(view, "mdeberta-v3-base-xnli-multilingual-nli-2mil7\n\n") {
		t.Fatalf("expected long model path to wrap before the message ended, got %q", view)
	}
}

func TestWrapTextBreaksLongWords(t *testing.T) {
	wrapped := wrapText("abcdef ghijkl", 4)

	if wrapped != "abcd\nef\nghij\nkl" {
		t.Fatalf("unexpected wrapped text: %q", wrapped)
	}
}

func TestWindowSizeUpdatesInputAndWrapWidth(t *testing.T) {
	m := model{}

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 72, Height: 20})
	result := updated.(model)

	if result.width != 72 || result.height != 20 {
		t.Fatalf("expected window dimensions to be stored, got width=%d height=%d", result.width, result.height)
	}
	if result.input.Width != 68 {
		t.Fatalf("expected input width to follow terminal width, got %d", result.input.Width)
	}
}

func TestAgentDetailRendersPlannerDecision(t *testing.T) {
	m := model{
		selectedAgent: "planner",
		agents: map[string]agentState{
			"planner": {
				ID:     "planner",
				Status: "ok",
				Decision: plannerDecision{
					Mode:              "delegate",
					Reason:            "Needs file edits.",
					DelegatedAgentIDs: []string{"worker"},
				},
			},
		},
	}

	view := m.agentDetailView()
	if !strings.Contains(view, "mode: delegate") || !strings.Contains(view, "delegated: worker") {
		t.Fatalf("expected planner decision in detail view, got %q", view)
	}
}

func TestAgentsViewRendersSelectedSkills(t *testing.T) {
	m := model{
		provider:    providerEcho,
		providerSet: true,
		lastSummary: summary{
			Skills: []skillSummary{{Name: "docs-helper"}},
			WorkflowRoute: workflowRoute{
				Requested:    "auto",
				Selected:     "tool",
				Reason:       "time_intent_with_read_only_tool",
				ToolIntent:   "time",
				ToolsExposed: true,
			},
		},
		agents: map[string]agentState{
			"planner": {ID: "planner", Status: "ok"},
		},
		agentOrder: []string{"planner"},
	}

	view := m.agentsView()
	if !strings.Contains(view, "Skills: docs-helper") {
		t.Fatalf("expected selected skills in agents view, got %q", view)
	}
	if !strings.Contains(view, "Workflow route: requested=auto selected=tool intent=time tools=true") {
		t.Fatalf("expected workflow route in agents view, got %q", view)
	}
	if !strings.Contains(m.statusLine(), "route=auto->tool") {
		t.Fatalf("expected workflow route in status line, got %q", m.statusLine())
	}
}

func TestResolveConfigUsesOpenAIPricingProfileAndTimeoutDefault(t *testing.T) {
	resolved, err := resolveConfig(runConfig{
		Task:     "review this project",
		Workflow: workflowBasic,
		Provider: providerOpenAI,
		APIKey:   "test-key",
		Model:    "gpt-4o-mini",
	})

	if err != nil {
		t.Fatalf("expected resolve to succeed, got %v", err)
	}

	if resolved.InputPrice != "0.15" {
		t.Fatalf("unexpected input price: %q", resolved.InputPrice)
	}

	if resolved.OutputPrice != "0.6" {
		t.Fatalf("unexpected output price: %q", resolved.OutputPrice)
	}

	if resolved.HTTPTimeout != defaultHTTPTimeoutMS {
		t.Fatalf("unexpected HTTP timeout: %q", resolved.HTTPTimeout)
	}
}

func TestResolveConfigUsesOpenRouterPricingLookup(t *testing.T) {
	originalLookup := openRouterPricingLookup
	openRouterPricingLookup = func(model string) (modelPricing, error) {
		if model != "openai/gpt-4o-mini" {
			t.Fatalf("unexpected model lookup: %q", model)
		}

		return modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}, nil
	}
	t.Cleanup(func() {
		openRouterPricingLookup = originalLookup
	})

	resolved, err := resolveConfig(runConfig{
		Task:     "review this project",
		Workflow: workflowBasic,
		Provider: providerOpenRouter,
		APIKey:   "test-key",
		Model:    "openai/gpt-4o-mini",
	})

	if err != nil {
		t.Fatalf("expected resolve to succeed, got %v", err)
	}

	if resolved.InputPrice != "0.15" {
		t.Fatalf("unexpected input price: %q", resolved.InputPrice)
	}

	if resolved.OutputPrice != "0.6" {
		t.Fatalf("unexpected output price: %q", resolved.OutputPrice)
	}

	if resolved.HTTPTimeout != defaultHTTPTimeoutMS {
		t.Fatalf("unexpected HTTP timeout: %q", resolved.HTTPTimeout)
	}
}

func TestOpenRouterModelPricingConvertsPerTokenPricesToPerMillion(t *testing.T) {
	pricing, err := openRouterModelPricing(openRouterModel{
		ID: "test/model",
		Pricing: openRouterPricing{
			Prompt:     "0.00000015",
			Completion: "0.00000060",
		},
	})

	if err != nil {
		t.Fatalf("expected pricing conversion to succeed, got %v", err)
	}

	if pricing.InputPerMillion != 0.15 {
		t.Fatalf("unexpected input price: %f", pricing.InputPerMillion)
	}

	if pricing.OutputPerMillion != 0.60 {
		t.Fatalf("unexpected output price: %f", pricing.OutputPerMillion)
	}
}

func TestModelListMessageSelectsFirstLoadedModel(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}
	m.provider = providerOpenRouter

	updated, _ := m.Update(modelListMsg{
		Provider: providerOpenRouter,
		Models: []modelOption{
			{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}},
			{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}},
		},
	})

	result := updated.(model)

	if result.selectedModel != "anthropic/claude" {
		t.Fatalf("unexpected selected model: %q", result.selectedModel)
	}

	if result.modelStatus != "loaded 2 models" {
		t.Fatalf("unexpected model status: %q", result.modelStatus)
	}
}

func TestConfigUsesLoadedModelPricing(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}
	m.provider = providerOpenRouter
	m.providerSet = true
	m.savedConfig.OpenRouterAPIKey = "test-key"
	m.selectedModel = "openai/gpt-4o-mini"
	m.modelOptions = []modelOption{
		{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}},
	}

	config := m.runConfig("review this project")

	if config.Workflow != workflowAuto {
		t.Fatalf("expected progressive auto workflow request, got %q", config.Workflow)
	}

	if config.InputPrice != "0.15" {
		t.Fatalf("unexpected input price: %q", config.InputPrice)
	}

	if config.OutputPrice != "0.6" {
		t.Fatalf("unexpected output price: %q", config.OutputPrice)
	}

	if config.HTTPTimeout != defaultHTTPTimeoutMS {
		t.Fatalf("unexpected HTTP timeout: %q", config.HTTPTimeout)
	}
}

func TestRunConfigUsesModelContextWindowUnlessExplicitConfigOverridesIt(t *testing.T) {
	m := model{
		provider:      providerOpenRouter,
		providerSet:   true,
		selectedModel: "openai/gpt-4o-mini",
		modelOptions: []modelOption{
			{
				ID:                  "openai/gpt-4o-mini",
				Pricing:             modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60},
				ContextWindowTokens: 128000,
			},
		},
		savedConfig: savedConfig{OpenRouterAPIKey: "test-key"},
	}

	config := m.runConfig("review this project")
	if config.ContextWindow != "128000" {
		t.Fatalf("expected model metadata context window, got %q", config.ContextWindow)
	}

	m.savedConfig.ContextWindow = "64000"
	config = m.runConfig("review this project")
	if config.ContextWindow != "64000" {
		t.Fatalf("expected explicit context window override, got %q", config.ContextWindow)
	}
}

func TestCompactCommandCallsCompactCLIAndReplacesActiveMessages(t *testing.T) {
	originalRunner := compactRunner
	var capturedMessages []chatMessage
	compactRunner = func(config runConfig, messages []chatMessage) (compactSummary, string, error) {
		if config.Provider != providerEcho || config.Model != "echo" {
			t.Fatalf("unexpected compact config: %#v", config)
		}
		capturedMessages = append([]chatMessage(nil), messages...)
		return compactSummary{Status: "ok", Summary: "User asked for Poland news; assistant needed browsing approval.", CoveredItems: []string{"1", "2"}}, "{}", nil
	}
	t.Cleanup(func() {
		compactRunner = originalRunner
	})

	m := model{
		provider:    providerEcho,
		providerSet: true,
		configPath:  filepath.Join(t.TempDir(), "config.json"),
		messages: []chatMessage{
			{Role: "system", Text: "loaded"},
			{Role: "user", Text: "research latest Poland news"},
			{Role: "assistant", Text: "I need browsing approval"},
		},
	}

	updated, cmd := m.handleCommand("/compact")
	if cmd == nil {
		t.Fatal("expected compact command")
	}

	msg := cmd().(compactResultMsg)
	updated, _ = updated.(model).Update(msg)
	result := updated.(model)

	if len(capturedMessages) != 2 {
		t.Fatalf("expected user and assistant messages to compact, got %#v", capturedMessages)
	}
	if len(result.messages) != 1 {
		t.Fatalf("expected compacted history to replace active messages, got %#v", result.messages)
	}
	if result.messages[0].Role != "summary" {
		t.Fatalf("expected summary role, got %#v", result.messages[0])
	}
	if !strings.Contains(result.messages[0].Text, "Poland news") {
		t.Fatalf("expected compact summary text, got %q", result.messages[0].Text)
	}
}

func TestTaskContextIncludesCompactedSummaryAndNewerUserMessages(t *testing.T) {
	m := model{
		messages: []chatMessage{
			{Role: "summary", Text: "Compacted conversation summary:\nUser wants Poland news."},
			{Role: "user", Text: "newer follow-up"},
			{Role: "assistant", Text: "previous answer"},
		},
	}

	task := m.taskWithConversationContext("current request")

	if !strings.Contains(task, "Compacted conversation summary: User wants Poland news.") {
		t.Fatalf("expected compacted summary in task context, got %q", task)
	}
	if !strings.Contains(task, "user: newer follow-up") {
		t.Fatalf("expected newer user message in task context, got %q", task)
	}
	if !strings.Contains(task, "Current user request:\ncurrent request") {
		t.Fatalf("expected current request in task context, got %q", task)
	}
}

func TestOpenAIModelOptionsKeepOnlyKnownPricingProfiles(t *testing.T) {
	options := openAIModelOptions([]openAIModel{
		{ID: "unknown-model"},
		{ID: "gpt-4o-mini"},
	})

	if len(options) != 1 {
		t.Fatalf("expected one priced option, got %#v", options)
	}

	if options[0].ID != "gpt-4o-mini" {
		t.Fatalf("unexpected model id: %q", options[0].ID)
	}

	if options[0].Pricing.InputPerMillion != 0.15 {
		t.Fatalf("unexpected pricing: %#v", options[0].Pricing)
	}
}

func TestProviderCommandSwitchesSessionProvider(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/provider openrouter")
	result := updated.(model)

	if result.provider != providerOpenRouter {
		t.Fatalf("unexpected provider: %q", result.provider)
	}

	if !result.providerSet {
		t.Fatal("expected provider to be explicit")
	}

	if result.selectedModel != "" {
		t.Fatalf("expected selected model to reset, got %q", result.selectedModel)
	}
}

func TestProviderCommandPersistsSelectedProvider(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	_, _ = m.handleCommand("/provider openrouter")

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.Provider != "openrouter" {
		t.Fatalf("expected provider to persist, got %q", loaded.Provider)
	}
}

func TestInitialModelRequiresProviderBeforeRun(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, cmd := m.startRun("review this project")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command without provider setup")
	}
	if result.view != viewSetup {
		t.Fatalf("expected setup view, got %v", result.view)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "select a provider") {
		t.Fatalf("unexpected message: %#v", result.messages[len(result.messages)-1])
	}
}

func TestStartRunUsesAutoWithoutWorkflowSetup(t *testing.T) {
	m := model{
		provider:    providerEcho,
		providerSet: true,
		configPath:  filepath.Join(t.TempDir(), "config.json"),
	}

	updated, cmd := m.startRun("review this project")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command")
	}
	if result.activeConfig.Workflow != workflowAuto {
		t.Fatalf("expected auto workflow request, got %q", result.activeConfig.Workflow)
	}
}

func TestStartRunTimeQuestionWithCodeEditToolsStaysInChat(t *testing.T) {
	m := model{
		provider:      providerOpenRouter,
		providerSet:   true,
		selectedModel: "stepfun/step-3.5-flash",
		configPath:    filepath.Join(t.TempDir(), "config.json"),
		modelOptions: []modelOption{
			{
				ID: "stepfun/step-3.5-flash",
				Pricing: modelPricing{
					InputPerMillion:  0.01,
					OutputPerMillion: 0.01,
				},
			},
		},
		savedConfig: savedConfig{
			OpenRouterAPIKey: "test-key",
			ToolHarness:      "code-edit",
			ToolRoot:         "/tmp/agent-machine-project",
			ToolTimeout:      "1000",
			ToolMaxRounds:    "6",
			ToolApproval:     "auto-approved-safe",
		},
	}

	updated, cmd := m.startRun("what time we have")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command")
	}
	if result.view != viewChat {
		t.Fatalf("expected chat view, got %v", result.view)
	}
	if !result.running {
		t.Fatal("expected run to start")
	}
	if result.activeConfig.Workflow != workflowAuto {
		t.Fatalf("expected auto workflow, got %q", result.activeConfig.Workflow)
	}
}

func TestStartRunPreparationErrorStaysInChatWhenProviderIsSet(t *testing.T) {
	m := model{
		provider:      providerOpenRouter,
		providerSet:   true,
		selectedModel: "",
		configPath:    filepath.Join(t.TempDir(), "config.json"),
		savedConfig:   savedConfig{OpenRouterAPIKey: "test-key"},
	}

	updated, cmd := m.startRun("what time we have")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command")
	}
	if result.view != viewChat {
		t.Fatalf("expected chat view for preparation error, got %v", result.view)
	}
	if len(result.messages) == 0 || !strings.Contains(result.messages[len(result.messages)-1].Text, "model") {
		t.Fatalf("expected model error message in chat, got %#v", result.messages)
	}
}

func TestSetupAndHelpUseProgressiveAutoMode(t *testing.T) {
	m := model{provider: providerEcho, providerSet: true}

	setup := m.setupView()
	if !strings.Contains(setup, "mode: progressive auto") {
		t.Fatalf("expected progressive auto mode in setup view, got %q", setup)
	}
	if !strings.Contains(setup, "chat/tool/basic/agentic") {
		t.Fatalf("expected setup view to describe selected routes, got %q", setup)
	}
	if strings.Contains(setup, "/workflow") || strings.Contains(setup, "workflow:") {
		t.Fatalf("expected setup view to omit workflow selection, got %q", setup)
	}

	help := helpText()
	if strings.Contains(help, "/workflow") {
		t.Fatalf("expected help to omit workflow command, got %q", help)
	}
	if !strings.Contains(help, "read-only tool") {
		t.Fatalf("expected help to mention read-only tool route, got %q", help)
	}

	status := m.statusLine()
	if strings.Contains(status, "workflow=") {
		t.Fatalf("expected status to omit workflow, got %q", status)
	}
}

func TestWorkflowCommandReportsProgressiveAutoMode(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/workflow agentic")
	result := updated.(model)

	if result.workflowSet {
		t.Fatal("expected workflow command not to mutate workflow setup")
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "progressive auto") {
		t.Fatalf("unexpected workflow message: %#v", result.messages[len(result.messages)-1])
	}
}

func TestWorkflowCommandDoesNotPersistWorkflow(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	_, _ = m.handleCommand("/workflow agentic")

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.Workflow != "" {
		t.Fatalf("expected workflow not to persist, got %q", loaded.Workflow)
	}
}

func TestRouterCommandPersistsLocalRouter(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/router local /tmp/agent-machine-router-model")
	result := updated.(model)

	if result.savedConfig.RouterMode != "local" {
		t.Fatalf("expected local router, got %q", result.savedConfig.RouterMode)
	}
	if result.savedConfig.RouterModelDir != "/tmp/agent-machine-router-model" {
		t.Fatalf("unexpected router model dir: %q", result.savedConfig.RouterModelDir)
	}
	if result.savedConfig.RouterTimeout != defaultRouterTimeoutMS || result.savedConfig.RouterConfidence != defaultRouterConfidence {
		t.Fatalf("unexpected local router defaults: %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.RouterMode != "local" || loaded.RouterModelDir != "/tmp/agent-machine-router-model" {
		t.Fatalf("unexpected saved router config: %#v", loaded)
	}
}

func TestRouterTuningCommandsPersistSettings(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/router local /tmp/agent-machine-router-model")
	result := updated.(model)
	updated, _ = result.handleCommand("/router-timeout 750")
	result = updated.(model)
	updated, _ = result.handleCommand("/router-confidence 0.7")
	result = updated.(model)

	if result.savedConfig.RouterTimeout != "750" || result.savedConfig.RouterConfidence != "0.7" {
		t.Fatalf("unexpected router tuning: %#v", result.savedConfig)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "confidence=0.7") {
		t.Fatalf("expected router status message, got %#v", result.messages[len(result.messages)-1])
	}
}

func TestRouterStatusCommandShowsCurrentSettings(t *testing.T) {
	m := model{
		savedConfig: savedConfig{
			RouterMode:       "local",
			RouterModelDir:   "/tmp/agent-machine-router-model",
			RouterTimeout:    "750",
			RouterConfidence: "0.7",
		},
	}

	updated, _ := m.handleCommand("/router-status")
	result := updated.(model)
	text := result.messages[len(result.messages)-1].Text

	if !strings.Contains(text, "router: local dir=/tmp/agent-machine-router-model timeout_ms=750 confidence=0.7") {
		t.Fatalf("unexpected router status: %q", text)
	}
}

func TestRouterConfidenceCommandValidatesValue(t *testing.T) {
	m := model{savedConfig: savedConfig{RouterMode: "local", RouterModelDir: "/tmp/agent-machine-router-model"}}

	updated, _ := m.handleCommand("/router-confidence 2")
	result := updated.(model)

	if !strings.Contains(result.messages[len(result.messages)-1].Text, "router confidence") {
		t.Fatalf("expected router confidence error, got %#v", result.messages[len(result.messages)-1])
	}
}

func TestToolsCommandPersistsLocalFileHarness(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools local-files /tmp/agent-machine-wiki 1000 2 auto-approved-safe")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "local-files" {
		t.Fatalf("expected local-files harness, got %q", result.savedConfig.ToolHarness)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolRoot != "/tmp/agent-machine-wiki" || loaded.ToolTimeout != "1000" || loaded.ToolMaxRounds != "2" || loaded.ToolApproval != "auto-approved-safe" {
		t.Fatalf("unexpected saved tool config: %#v", loaded)
	}
}

func TestToolsCommandPersistsCodeEditHarness(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools code-edit /tmp/agent-machine-project 1000 2 full-access")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "code-edit" {
		t.Fatalf("expected code-edit harness, got %q", result.savedConfig.ToolHarness)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolHarness != "code-edit" || loaded.ToolRoot != "/tmp/agent-machine-project" || loaded.ToolTimeout != "1000" || loaded.ToolMaxRounds != "2" || loaded.ToolApproval != "full-access" {
		t.Fatalf("unexpected saved tool config: %#v", loaded)
	}
}

func TestToolsCommandPersistsTimeHarness(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools time 1000 2 read-only")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "time" {
		t.Fatalf("expected time harness, got %q", result.savedConfig.ToolHarness)
	}
	if result.savedConfig.ToolRoot != "" {
		t.Fatalf("expected time harness without root, got %q", result.savedConfig.ToolRoot)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolHarness != "time" || loaded.ToolTimeout != "1000" || loaded.ToolMaxRounds != "2" || loaded.ToolApproval != "read-only" {
		t.Fatalf("unexpected saved time tool config: %#v", loaded)
	}
}

func TestTestCommandAddListAndClear(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/test-command add mix test")
	result := updated.(model)

	if len(result.savedConfig.TestCommands) != 1 || result.savedConfig.TestCommands[0] != "mix test" {
		t.Fatalf("expected saved test command, got %#v", result.savedConfig.TestCommands)
	}

	updated, _ = result.handleCommand("/test-command list")
	result = updated.(model)
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "mix test") {
		t.Fatalf("expected test command list, got %#v", result.messages)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if len(loaded.TestCommands) != 1 || loaded.TestCommands[0] != "mix test" {
		t.Fatalf("expected persisted test command, got %#v", loaded.TestCommands)
	}

	updated, _ = result.handleCommand("/test-command clear")
	result = updated.(model)
	if len(result.savedConfig.TestCommands) != 0 {
		t.Fatalf("expected cleared test commands, got %#v", result.savedConfig.TestCommands)
	}
}

func TestMCPConfigCommandPersistsAndClearsPath(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	modelAfter, _ := m.handleCommand("/mcp-config /tmp/agent-machine.mcp.json 120000 6 full-access")
	result := modelAfter.(model)
	if result.savedConfig.MCPConfig != "/tmp/agent-machine.mcp.json" {
		t.Fatalf("expected MCP config path, got %#v", result.savedConfig)
	}
	if result.savedConfig.ToolTimeout != "120000" || result.savedConfig.ToolMaxRounds != "6" || result.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("expected MCP tool budget, got %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.MCPConfig != "/tmp/agent-machine.mcp.json" {
		t.Fatalf("expected persisted MCP config path, got %#v", loaded)
	}
	if loaded.ToolTimeout != "120000" || loaded.ToolMaxRounds != "6" || loaded.ToolApproval != "full-access" {
		t.Fatalf("expected persisted MCP tool budget, got %#v", loaded)
	}

	modelAfter, _ = result.handleCommand("/mcp-config off")
	result = modelAfter.(model)
	if result.savedConfig.MCPConfig != "" {
		t.Fatalf("expected cleared MCP config path, got %#v", result.savedConfig)
	}
}

func TestMCPConfigCommandRejectsMissingToolBudget(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	modelAfter, _ := m.handleCommand("/mcp-config /tmp/agent-machine.mcp.json")
	result := modelAfter.(model)

	if result.savedConfig.MCPConfig != "" {
		t.Fatalf("expected MCP config not to persist without budget, got %#v", result.savedConfig)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "tool timeout") {
		t.Fatalf("expected explicit missing budget error, got %#v", result.messages)
	}
}

func TestMCPAddPlaywrightCreatesManagedConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	if err := saveSavedConfig(configPath, savedConfig{
		ToolHarness:   "local-files",
		ToolRoot:      "/tmp/project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "auto-approved-safe",
	}); err != nil {
		t.Fatal(err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	modelAfter, _ := m.handleCommand("/mcp add playwright npx @playwright/mcp@latest")
	result := modelAfter.(model)
	managedPath := managedMCPConfigPath(configPath)

	if result.savedConfig.MCPConfig != managedPath {
		t.Fatalf("expected managed MCP config, got %#v", result.savedConfig)
	}
	if result.savedConfig.ToolHarness != "" || result.savedConfig.ToolRoot != "" {
		t.Fatalf("expected MCP preset to disable filesystem tools, got %#v", result.savedConfig)
	}
	if result.savedConfig.ToolTimeout != "120000" || result.savedConfig.ToolMaxRounds != "6" || result.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("expected MCP tool budget, got %#v", result.savedConfig)
	}

	data, err := os.ReadFile(managedPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	expectedOrder := []string{
		`"--yes"`,
		`"--cache"`,
		`"@playwright/mcp@latest"`,
		`"--headless"`,
	}
	lastIndex := -1
	for _, expected := range expectedOrder {
		index := strings.Index(text, expected)
		if index <= lastIndex {
			t.Fatalf("expected %s after previous npx/playwright arg in generated config: %s", expected, text)
		}
		lastIndex = index
	}
	for _, expected := range []string{
		`"id": "playwright"`,
		`"command": "npx"`,
		`"browser_navigate"`,
		`"risk": "network"`,
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("expected generated MCP config to contain %q, got %s", expected, text)
		}
	}
}

func TestPlaywrightCommandPutsHeadlessAfterPackage(t *testing.T) {
	command, args, err := playwrightCommand([]string{"npx", "@playwright/mcp@latest"})
	if err != nil {
		t.Fatal(err)
	}
	if command != "npx" {
		t.Fatalf("expected npx command, got %q", command)
	}

	packageIndex := indexOf(args, "@playwright/mcp@latest")
	headlessIndex := indexOf(args, "--headless")
	cacheIndex := indexOf(args, "--cache")

	if cacheIndex < 0 || packageIndex < 0 || headlessIndex < 0 {
		t.Fatalf("expected cache, package, and headless args, got %#v", args)
	}
	if !(cacheIndex < packageIndex && packageIndex < headlessIndex) {
		t.Fatalf("expected npx options before package and --headless after package, got %#v", args)
	}
}

func indexOf(values []string, expected string) int {
	for index, value := range values {
		if value == expected {
			return index
		}
	}
	return -1
}

func TestMCPRemovePlaywrightClearsManagedConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	modelAfter, _ := m.handleCommand("/mcp add playwright npx @playwright/mcp@latest")
	result := modelAfter.(model)
	managedPath := managedMCPConfigPath(configPath)

	modelAfter, _ = result.handleCommand("/mcp remove playwright")
	result = modelAfter.(model)

	if result.savedConfig.MCPConfig != "" {
		t.Fatalf("expected MCP config to clear, got %#v", result.savedConfig)
	}
	if _, err := os.Stat(managedPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected managed MCP config file to be removed, got %v", err)
	}
}

func TestStartupMCPFlagsPersistConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModelWithArgs([]string{
		"--mcp-config",
		"/tmp/agent-machine.mcp.json",
		"--tool-timeout-ms",
		"120000",
		"--tool-max-rounds",
		"6",
		"--tool-approval-mode",
		"full-access",
	})
	if err != nil {
		t.Fatalf("expected startup MCP flags to load, got %v", err)
	}

	if m.savedConfig.MCPConfig != "/tmp/agent-machine.mcp.json" {
		t.Fatalf("expected MCP config path, got %#v", m.savedConfig)
	}
	if m.savedConfig.ToolTimeout != "120000" || m.savedConfig.ToolMaxRounds != "6" || m.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("expected tool budget to persist, got %#v", m.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.MCPConfig != "/tmp/agent-machine.mcp.json" || loaded.ToolApproval != "full-access" {
		t.Fatalf("expected persisted startup MCP config, got %#v", loaded)
	}
}

func TestStartupMCPFlagsRequireToolBudget(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	_, err := initialModelWithArgs([]string{
		"--mcp-config",
		"/tmp/agent-machine.mcp.json",
	})
	if err == nil || !strings.Contains(err.Error(), "--tool-timeout-ms") {
		t.Fatalf("expected missing tool budget error, got %v", err)
	}
}

func TestSkillsCommandPersistsAutoMode(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/skills auto /tmp/agent-machine-skills")
	result := updated.(model)

	if result.savedConfig.SkillsMode != "auto" || result.savedConfig.SkillsDir != "/tmp/agent-machine-skills" {
		t.Fatalf("unexpected skills config: %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.SkillsMode != "auto" || loaded.SkillsDir != "/tmp/agent-machine-skills" {
		t.Fatalf("expected persisted skills config, got %#v", loaded)
	}
}

func TestSkillsCommandPersistsExplicitSkill(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/skills dir /tmp/agent-machine-skills")
	result := updated.(model)
	updated, _ = result.handleCommand("/skills add docs-helper")
	result = updated.(model)

	if len(result.savedConfig.SkillNames) != 1 || result.savedConfig.SkillNames[0] != "docs-helper" {
		t.Fatalf("expected selected skill, got %#v", result.savedConfig.SkillNames)
	}
	if result.savedConfig.SkillsMode != "" {
		t.Fatalf("expected explicit skills to clear auto mode, got %#v", result.savedConfig)
	}
}

func TestSkillsClawHubCLIArgsStayThin(t *testing.T) {
	args, err := buildSkillsCLIArgs(
		[]string{"search", "docs", "--source", "clawhub", "--sort", "downloads", "--limit", "20"},
		"",
		false,
	)
	if err != nil {
		t.Fatalf("expected ClawHub search args without skills dir, got %v", err)
	}
	assertContainsSequence(t, args, []string{"search", "docs", "--source", "clawhub"})
	assertContainsSequence(t, args, []string{"--sort", "downloads"})
	assertContainsSequence(t, args, []string{"--json"})

	args, err = buildSkillsCLIArgs([]string{"install", "clawhub:docs-helper"}, "/tmp/skills", true)
	if err != nil {
		t.Fatalf("expected ClawHub install args, got %v", err)
	}
	assertContainsSequence(t, args, []string{"install", "clawhub:docs-helper", "--skills-dir", "/tmp/skills"})
	assertContainsSequence(t, args, []string{"--json"})
}

func TestSkillsClawHubUpdateUsesSkillsDir(t *testing.T) {
	args, err := buildSkillsCLIArgs([]string{"update", "--all"}, "/tmp/skills", true)
	if err != nil {
		t.Fatalf("expected ClawHub update args, got %v", err)
	}
	assertContainsSequence(t, args, []string{"update", "--all", "--skills-dir", "/tmp/skills"})
	assertContainsSequence(t, args, []string{"--json"})
}

func TestValidateConfigRejectsMCPConfigWithoutToolBudget(t *testing.T) {
	err := validateToolConfig(runConfig{MCPConfig: "/tmp/agent-machine.mcp.json"})
	if err == nil {
		t.Fatal("expected MCP config without tool budget to fail")
	}

	err = validateToolConfig(runConfig{
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "read-only",
		MCPConfig:     "/tmp/agent-machine.mcp.json",
	})
	if err != nil {
		t.Fatalf("expected MCP config with explicit budget to pass: %v", err)
	}
}

func TestValidateConfigRejectsTestCommandsWithoutCodeEditFullAccess(t *testing.T) {
	err := validateToolConfig(runConfig{
		ToolHarness:   "local-files",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "full-access",
		TestCommands:  []string{"mix test"},
	})
	if err == nil || !strings.Contains(err.Error(), "test commands require code-edit") {
		t.Fatalf("expected code-edit validation error, got %v", err)
	}

	err = validateToolConfig(runConfig{
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "auto-approved-safe",
		TestCommands:  []string{"mix test"},
	})
	if err == nil || !strings.Contains(err.Error(), "test commands require full-access") {
		t.Fatalf("expected full-access validation error, got %v", err)
	}
}

func TestToolsOffClearsTestCommands(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	if err := saveSavedConfig(configPath, savedConfig{
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "full-access",
		TestCommands:  []string{"mix test"},
	}); err != nil {
		t.Fatalf("expected saved config write to succeed, got %v", err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools off")
	result := updated.(model)

	if len(result.savedConfig.TestCommands) != 0 {
		t.Fatalf("expected test commands to clear, got %#v", result.savedConfig.TestCommands)
	}
}

func TestToolsCommandRejectsInvalidApprovalMode(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools code-edit /tmp/agent-machine-project 1000 2 maybe")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "" {
		t.Fatalf("expected invalid approval mode not to save tools, got %#v", result.savedConfig)
	}
	if len(result.messages) == 0 || !strings.Contains(result.messages[len(result.messages)-1].Text, "unsupported tool approval mode") {
		t.Fatalf("expected approval mode error, got %#v", result.messages)
	}
}

func TestToolsOffClearsToolHarness(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	if err := saveSavedConfig(configPath, savedConfig{
		ToolHarness:   "local-files",
		ToolRoot:      "/tmp/agent-machine-wiki",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "auto-approved-safe",
	}); err != nil {
		t.Fatalf("expected saved config write to succeed, got %v", err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools off")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "" || result.savedConfig.ToolRoot != "" || result.savedConfig.ToolTimeout != "" || result.savedConfig.ToolMaxRounds != "" || result.savedConfig.ToolApproval != "" {
		t.Fatalf("expected cleared tool config, got %#v", result.savedConfig)
	}
}

func TestFilesystemWritePromptRequiresToolPermissionWhenToolsOff(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		configPath:  configPath,
	}

	updated, cmd := m.startRun("create directory testmme in my home folder")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command before tool permission")
	}
	if result.running {
		t.Fatal("expected run to remain stopped")
	}
	if result.pendingToolTask == "" {
		t.Fatal("expected pending tool task")
	}
	if result.pendingToolHarness != "local-files" {
		t.Fatalf("expected local-files pending harness, got %q", result.pendingToolHarness)
	}
	last := result.messages[len(result.messages)-1].Text
	if !strings.Contains(last, "filesystem permission required") || !strings.Contains(last, "required harness: local-files") || !strings.Contains(last, "Use the selector below") || !strings.Contains(last, "/allow-tools") || !strings.Contains(last, "/deny-tools") {
		t.Fatalf("expected permission prompt, got %q", last)
	}
	view := result.View()
	if !strings.Contains(view, "Tool Permission") || !strings.Contains(view, "> Allow writes") || !strings.Contains(view, "Full access") || !strings.Contains(view, "Deny") {
		t.Fatalf("expected permission selector, got %q", view)
	}
}

func TestCodeEditFollowUpPromptRequiresCodeEditHarness(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		configPath:  configPath,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
		},
		messages: []chatMessage{
			{Role: "user", Text: "Hi check in home folder Project1 and if thats app works"},
			{Role: "assistant", Text: "Found Projekt1/weather_app.py. The Python script is malformed and needs rewriting."},
		},
	}

	updated, cmd := m.startRun("yes rewrite and fix")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command before code-edit permission")
	}
	if result.pendingToolTask != "yes rewrite and fix" {
		t.Fatalf("expected pending follow-up task, got %q", result.pendingToolTask)
	}
	if result.pendingToolHarness != "code-edit" {
		t.Fatalf("expected code-edit pending harness, got %q", result.pendingToolHarness)
	}
	last := result.messages[len(result.messages)-1].Text
	if !strings.Contains(last, "required harness: code-edit") || !strings.Contains(last, "active tool harness cannot perform this filesystem action") {
		t.Fatalf("expected code-edit permission prompt, got %q", last)
	}
}

func TestNextJSProjectCreationRequiresCodeEditHarness(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		configPath:  configPath,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
		},
	}

	updated, cmd := m.startRun("in home folder create tt100 dir and create nextjs project")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command before code-edit permission")
	}
	if result.pendingToolHarness != "code-edit" {
		t.Fatalf("expected code-edit pending harness, got %q", result.pendingToolHarness)
	}
	last := result.messages[len(result.messages)-1].Text
	if !strings.Contains(last, "required harness: code-edit") ||
		!strings.Contains(last, "active tool harness cannot perform this filesystem action") {
		t.Fatalf("expected code-edit permission prompt, got %q", last)
	}
}

func TestRouterMutationCapabilityErrorShowsPermissionSelector(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "read-only",
		},
		messages: []chatMessage{
			{Role: "user", Text: "in home folder create me dir test1 and create a nice nextjs website"},
		},
	}

	err := errors.New("mix command failed: exit status 1\n** (ArgumentError) auto workflow detected code mutation intent but :code_edit tool harness is not configured")
	updated, handled := m.withRunPermissionError(err)

	if !handled {
		t.Fatal("expected router permission error to be handled")
	}
	if updated.pendingToolTask == "" {
		t.Fatal("expected pending tool task")
	}
	if updated.pendingToolHarness != "code-edit" {
		t.Fatalf("expected code-edit harness, got %q", updated.pendingToolHarness)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "filesystem permission required") ||
		!strings.Contains(last, "required harness: code-edit") ||
		!strings.Contains(last, "active tool harness cannot perform this filesystem action") {
		t.Fatalf("expected permission prompt, got %q", last)
	}
}

func TestRouterFileMutationCapabilityErrorShowsLocalFilesSelector(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness: "",
		},
		messages: []chatMessage{
			{Role: "user", Text: "in home folder create folder reports"},
		},
	}

	err := errors.New("mix command failed: exit status 1\n** (ArgumentError) auto workflow detected mutation intent but no write-capable tool harness is configured")
	updated, handled := m.withRunPermissionError(err)

	if !handled {
		t.Fatal("expected router permission error to be handled")
	}
	if updated.pendingToolHarness != "local-files" {
		t.Fatalf("expected local-files harness, got %q", updated.pendingToolHarness)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "required harness: local-files") ||
		!strings.Contains(last, "filesystem tools are off") {
		t.Fatalf("expected local-files permission prompt, got %q", last)
	}
}

func TestRouterTestIntentApprovalErrorShowsCodeEditSelector(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "code-edit",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
		},
		messages: []chatMessage{
			{Role: "user", Text: "in home folder run mix test"},
		},
	}

	err := errors.New("mix command failed: exit status 1\n** (ArgumentError) auto workflow detected test intent but :tool_approval_mode must be :full_access")
	updated, handled := m.withRunPermissionError(err)

	if !handled {
		t.Fatal("expected router permission error to be handled")
	}
	if updated.pendingToolHarness != "code-edit" {
		t.Fatalf("expected code-edit harness, got %q", updated.pendingToolHarness)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "required harness: code-edit") ||
		!strings.Contains(last, "full-access") {
		t.Fatalf("expected code-edit full-access permission prompt, got %q", last)
	}
}

func TestRouterWebBrowseApprovalErrorShowsMCPBrowserSelector(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
			MCPConfig:     "/tmp/agent-machine.mcp.json",
		},
		messages: []chatMessage{
			{Role: "user", Text: "reearch me in google latest news in Poland"},
		},
	}

	err := errors.New("mix command failed: exit status 1\n** (ArgumentError) auto workflow detected web browse intent but :tool_approval_mode must be :full_access for network-risk MCP browser tools")
	updated, handled := m.withRunPermissionError(err)

	if !handled {
		t.Fatal("expected web browse approval error to be handled")
	}
	if updated.pendingToolHarness != pendingHarnessMCPBrowser {
		t.Fatalf("expected MCP browser pending harness, got %q", updated.pendingToolHarness)
	}
	if updated.pendingToolRoot != "" {
		t.Fatalf("expected no filesystem root for MCP browser approval, got %q", updated.pendingToolRoot)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "MCP browser permission required") ||
		!strings.Contains(last, "full-access") ||
		!strings.Contains(last, "/tmp/agent-machine.mcp.json") {
		t.Fatalf("expected MCP browser permission prompt, got %q", last)
	}
	view := updated.View()
	if !strings.Contains(view, "harness: "+pendingHarnessMCPBrowser) ||
		!strings.Contains(view, "> Full access") ||
		!strings.Contains(view, "Deny") {
		t.Fatalf("expected MCP browser permission selector, got %q", view)
	}
}

func TestAllowToolsApprovesPendingFilesystemRun(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("expected home directory, got %v", err)
	}

	m := model{
		workflow:        workflowBasic,
		workflowSet:     true,
		provider:        providerEcho,
		providerSet:     true,
		configPath:      configPath,
		pendingToolTask: "create directory testmme in my home folder",
		pendingToolRoot: home,
	}

	updated, cmd := m.handleCommand("/allow-tools")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after allowing tools")
	}
	if !result.running {
		t.Fatal("expected run to start after allowing tools")
	}
	if result.savedConfig.ToolHarness != "local-files" || result.savedConfig.ToolRoot != home || result.savedConfig.ToolApproval != "auto-approved-safe" {
		t.Fatalf("unexpected tool config: %#v", result.savedConfig)
	}
	if result.activeConfig.Workflow != workflowAgentic {
		t.Fatalf("expected permission retry to run agentic, got %q", result.activeConfig.Workflow)
	}
	if result.pendingToolTask != "" || result.pendingToolRoot != "" || result.pendingToolHarness != "" {
		t.Fatalf("expected pending tool request to be cleared, got task=%q root=%q harness=%q", result.pendingToolTask, result.pendingToolRoot, result.pendingToolHarness)
	}
}

func TestAllowToolsApprovesPendingMCPBrowserRun(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")

	m := model{
		workflow:           workflowBasic,
		workflowSet:        true,
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		pendingToolTask:    "reearch me in google latest news in Poland",
		pendingToolHarness: pendingHarnessMCPBrowser,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
			MCPConfig:     "/tmp/agent-machine.mcp.json",
		},
	}

	updated, cmd := m.handleCommand("/allow-tools")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after allowing MCP browser tools")
	}
	if !result.running {
		t.Fatal("expected run to start after allowing MCP browser tools")
	}
	if result.savedConfig.ToolHarness != "" || result.savedConfig.ToolRoot != "" {
		t.Fatalf("expected MCP-only retry to disable filesystem tools, got %#v", result.savedConfig)
	}
	if result.savedConfig.MCPConfig != "/tmp/agent-machine.mcp.json" ||
		result.savedConfig.ToolTimeout != defaultMCPToolTimeout ||
		result.savedConfig.ToolMaxRounds != defaultMCPToolMaxRounds ||
		result.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("unexpected MCP browser tool config: %#v", result.savedConfig)
	}
	if result.activeConfig.Workflow != workflowAuto {
		t.Fatalf("expected MCP browser approval retry to run auto workflow, got %q", result.activeConfig.Workflow)
	}
	if result.pendingToolTask != "" || result.pendingToolRoot != "" || result.pendingToolHarness != "" {
		t.Fatalf("expected pending MCP browser request to clear, got task=%q root=%q harness=%q", result.pendingToolTask, result.pendingToolRoot, result.pendingToolHarness)
	}
}

func TestAllowToolsApprovesPendingCodeEditRun(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")

	m := model{
		workflow:           workflowBasic,
		workflowSet:        true,
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		pendingToolTask:    "yes rewrite and fix",
		pendingToolRoot:    "/tmp/agent-machine-home",
		pendingToolHarness: "code-edit",
	}

	updated, cmd := m.handleCommand("/allow-tools")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after allowing code-edit tools")
	}
	if result.savedConfig.ToolHarness != "code-edit" || result.savedConfig.ToolRoot != "/tmp/agent-machine-home" || result.savedConfig.ToolApproval != "auto-approved-safe" {
		t.Fatalf("unexpected tool config: %#v", result.savedConfig)
	}
	if result.activeConfig.Workflow != workflowAgentic {
		t.Fatalf("expected permission retry to run agentic, got %q", result.activeConfig.Workflow)
	}
	if result.pendingToolTask != "" || result.pendingToolRoot != "" || result.pendingToolHarness != "" {
		t.Fatalf("expected pending tool request to clear, got task=%q root=%q harness=%q", result.pendingToolTask, result.pendingToolRoot, result.pendingToolHarness)
	}
}

func TestYoloToolsUsesFullAccessForPendingFilesystemRun(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("expected home directory, got %v", err)
	}

	m := model{
		workflow:        workflowBasic,
		workflowSet:     true,
		provider:        providerEcho,
		providerSet:     true,
		configPath:      configPath,
		pendingToolTask: "create directory testmme in my home folder",
		pendingToolRoot: home,
	}

	updated, cmd := m.handleCommand("/yolo-tools")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after yolo tools")
	}
	if result.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("expected full-access, got %#v", result.savedConfig)
	}
}

func TestPendingToolSelectorApprovesWithKeyboard(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("expected home directory, got %v", err)
	}

	m := model{
		workflow:           workflowBasic,
		workflowSet:        true,
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		view:               viewChat,
		input:              textinput.New(),
		pendingToolTask:    "create directory testmme in my home folder",
		pendingToolRoot:    home,
		pendingToolHarness: "local-files",
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after selecting allow")
	}
	if !result.running {
		t.Fatal("expected run to start after selector approval")
	}
	if result.savedConfig.ToolHarness != "local-files" || result.savedConfig.ToolRoot != home || result.savedConfig.ToolApproval != "auto-approved-safe" {
		t.Fatalf("unexpected tool config: %#v", result.savedConfig)
	}
	if result.pendingToolTask != "" {
		t.Fatalf("expected pending request to clear, got %q", result.pendingToolTask)
	}
}

func TestPendingToolSelectorCanChooseFullAccessAndDeny(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")

	m := model{
		workflow:           workflowBasic,
		workflowSet:        true,
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		view:               viewChat,
		input:              textinput.New(),
		pendingToolTask:    "fix /tmp/agent-machine-home/app.py",
		pendingToolRoot:    "/tmp/agent-machine-home",
		pendingToolHarness: "code-edit",
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	result := updated.(model)
	if cmd != nil {
		t.Fatal("expected no command while moving selector")
	}
	if result.pendingToolChoice != 1 {
		t.Fatalf("expected full-access selection, got %d", result.pendingToolChoice)
	}

	updated, cmd = result.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result = updated.(model)
	if cmd == nil {
		t.Fatal("expected run command after full-access selector approval")
	}
	if result.savedConfig.ToolHarness != "code-edit" || result.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("unexpected tool config: %#v", result.savedConfig)
	}

	deny := model{
		view:               viewChat,
		input:              textinput.New(),
		pendingToolTask:    "fix the existing app",
		pendingToolRoot:    "/tmp/agent-machine-home",
		pendingToolHarness: "code-edit",
		pendingToolChoice:  2,
	}
	updated, cmd = deny.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result = updated.(model)
	if cmd != nil {
		t.Fatal("expected no run command after deny")
	}
	if result.pendingToolTask != "" || result.pendingToolHarness != "" {
		t.Fatalf("expected deny to clear pending request, got %#v", result)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "denied") {
		t.Fatalf("expected denied message, got %#v", result.messages)
	}
}

func TestDenyToolsClearsPendingFilesystemRun(t *testing.T) {
	m := model{
		pendingToolTask: "create directory testmme in my home folder",
		pendingToolRoot: "/tmp/agent-machine-home",
	}

	updated, cmd := m.handleCommand("/deny-tools")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no command after denying tools")
	}
	if result.pendingToolTask != "" || result.pendingToolRoot != "" || result.pendingToolHarness != "" {
		t.Fatalf("expected pending request to clear, got task=%q root=%q harness=%q", result.pendingToolTask, result.pendingToolRoot, result.pendingToolHarness)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "denied") {
		t.Fatalf("expected denied message, got %#v", result.messages)
	}
}

func TestStartRunIncludesRecentConversationContext(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "2",
			ToolApproval:  "auto-approved-safe",
		},
		messages: []chatMessage{
			{Role: "user", Text: "create me in home folder directory myproj1"},
			{Role: "assistant", Text: "Created directory myproj1."},
		},
	}

	updated, cmd := m.startRun("inside this dir create index.html")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command")
	}
	if !strings.Contains(result.activeConfig.Task, "Conversation context:") {
		t.Fatalf("expected conversation context, got %q", result.activeConfig.Task)
	}
	if result.activeConfig.LogFile == "" {
		t.Fatal("expected active run log file")
	}
	if !strings.Contains(result.activeConfig.Task, "myproj1") {
		t.Fatalf("expected previous directory reference, got %q", result.activeConfig.Task)
	}
	if !strings.Contains(result.activeConfig.Task, "Current user request:\ninside this dir create index.html") {
		t.Fatalf("expected current request marker, got %q", result.activeConfig.Task)
	}
}

func TestTaskWithoutHistoryDoesNotAddConversationContext(t *testing.T) {
	m := model{}

	task := m.taskWithConversationContext("create index.html")

	if task != "create index.html" {
		t.Fatalf("expected unchanged task, got %q", task)
	}
}

func TestSummaryDisplayTextFallsBackToAgentOutputs(t *testing.T) {
	text := summaryDisplayText(summary{
		Status: "completed",
		Results: map[string]runResultSummary{
			"planner": {Status: "ok", Output: "planned worker"},
			"worker":  {Status: "ok", Output: "created index.html"},
		},
	})

	if !strings.Contains(text, "Run completed without a final response") {
		t.Fatalf("expected fallback heading, got %q", text)
	}
	if !strings.Contains(text, "worker: created index.html") {
		t.Fatalf("expected worker output, got %q", text)
	}
}

func TestSummaryDisplayTextIncludesPlannerDecision(t *testing.T) {
	text := summaryDisplayText(summary{
		Status: "completed",
		Results: map[string]runResultSummary{
			"planner": {
				Status: "ok",
				Output: "planned worker",
				Decision: plannerDecision{
					Mode:              "delegate",
					Reason:            "Filesystem edits require tools.",
					DelegatedAgentIDs: []string{"worker"},
				},
			},
		},
	})

	if !strings.Contains(text, "planner decision: delegate - Filesystem edits require tools.") {
		t.Fatalf("expected planner decision, got %q", text)
	}
}

func TestRunningStatusIncludesSkillsState(t *testing.T) {
	status := runningStatus(runConfig{
		Provider:   providerEcho,
		Model:      "echo",
		SkillsMode: "auto",
		SkillsDir:  "/tmp/skills",
	})

	if !strings.Contains(status, "skills auto dir=/tmp/skills") {
		t.Fatalf("expected skills status, got %q", status)
	}
}

func TestSummaryDisplayTextReportsTimeout(t *testing.T) {
	text := summaryDisplayText(summary{
		Status: "timeout",
		Results: map[string]runResultSummary{
			"planner": {Status: "ok", Output: "planned worker"},
		},
	})

	if !strings.Contains(text, "Run timed out before a final response") {
		t.Fatalf("expected timeout heading, got %q", text)
	}
	if !strings.Contains(text, "planner: planned worker") {
		t.Fatalf("expected partial planner output, got %q", text)
	}
}

func TestSummaryDisplayTextUsesFinalOutputWhenPresent(t *testing.T) {
	text := summaryDisplayText(summary{FinalOutput: "done"})

	if text != "done" {
		t.Fatalf("expected final output, got %q", text)
	}
}

func TestRecentConversationMessagesSkipsSystemMessages(t *testing.T) {
	messages := []chatMessage{
		{Role: "system", Text: "running..."},
		{Role: "user", Text: "one"},
		{Role: "assistant", Text: "two"},
		{Role: "user", Text: "three"},
	}

	selected := recentConversationMessages(messages, 6)

	if len(selected) != 2 || selected[0].Text != "one" || selected[1].Text != "three" {
		t.Fatalf("unexpected selected messages: %#v", selected)
	}
}

func TestTaskConversationContextOmitsAssistantRefusals(t *testing.T) {
	m := model{
		messages: []chatMessage{
			{Role: "user", Text: "research me in google the latest news in poland"},
			{Role: "assistant", Text: "this chat route itself has no tools or workers; use agents to gather news"},
		},
	}

	task := m.taskWithConversationContext("you playwright mcp")

	if strings.Contains(task, "chat route") || strings.Contains(task, "use agents") {
		t.Fatalf("expected assistant refusal to be omitted from context, got %q", task)
	}
	if !strings.Contains(task, "research me in google the latest news in poland") {
		t.Fatalf("expected prior user request in context, got %q", task)
	}
}

func TestFilesystemWritePromptWhenActiveRootDoesNotCoverRequest(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		configPath:  configPath,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-wiki",
			ToolTimeout:   "1000",
			ToolMaxRounds: "2",
			ToolApproval:  "auto-approved-safe",
		},
	}

	updated, cmd := m.startRun("create directory testmme in my home folder")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command when root does not cover request")
	}
	last := result.messages[len(result.messages)-1].Text
	if !strings.Contains(last, "outside the active tool root") {
		t.Fatalf("expected active root warning, got %q", last)
	}
}

func TestModelCommandSelectsLoadedModel(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		configPath:  configPath,
		modelOptions: []modelOption{
			{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}},
			{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}},
		},
	}

	updated, _ := m.handleCommand("/model openai/gpt-4o-mini")
	result := updated.(model)

	if result.selectedModel != "openai/gpt-4o-mini" {
		t.Fatalf("unexpected selected model: %q", result.selectedModel)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.OpenRouterModel != "openai/gpt-4o-mini" {
		t.Fatalf("expected model to persist, got %q", loaded.OpenRouterModel)
	}
}

func TestInitialModelLoadsSavedSetup(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	if err := saveSavedConfig(configPath, savedConfig{
		Workflow:        "legacy-invalid",
		Provider:        "openrouter",
		OpenRouterModel: "openai/gpt-4o-mini",
		ToolHarness:     "local-files",
		ToolRoot:        "/tmp/agent-machine-wiki",
		ToolTimeout:     "1000",
		ToolMaxRounds:   "2",
		ToolApproval:    "auto-approved-safe",
	}); err != nil {
		t.Fatalf("expected saved config write to succeed, got %v", err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if m.workflowSet || m.workflow != "" {
		t.Fatalf("expected saved workflow to be ignored, got set=%v workflow=%q", m.workflowSet, m.workflow)
	}
	if !m.providerSet || m.provider != providerOpenRouter {
		t.Fatalf("expected saved provider, got set=%v provider=%q", m.providerSet, m.provider)
	}
	if m.selectedModel != "openai/gpt-4o-mini" {
		t.Fatalf("expected saved model, got %q", m.selectedModel)
	}
	if m.view != viewChat {
		t.Fatalf("expected chat view for saved setup, got %v", m.view)
	}
	if m.savedConfig.ToolHarness != "local-files" {
		t.Fatalf("expected saved tools, got %#v", m.savedConfig)
	}
}

func TestInitialModelUsesInstalledZeroShotRouterByDefault(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "agent-machine", "tui-config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	modelDir := defaultRouterModelDir(configPath)
	writeRouterModelFilesForTest(t, modelDir)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if m.savedConfig.RouterMode != "local" {
		t.Fatalf("expected local router default, got %#v", m.savedConfig)
	}
	if m.savedConfig.RouterModelDir != modelDir {
		t.Fatalf("unexpected router model dir: %q", m.savedConfig.RouterModelDir)
	}
	if m.savedConfig.RouterTimeout != defaultRouterTimeoutMS ||
		m.savedConfig.RouterConfidence != defaultRouterConfidence {
		t.Fatalf("unexpected router defaults: %#v", m.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected config load, got %v", err)
	}
	if loaded.RouterMode != "" {
		t.Fatalf("expected auto-detected router not to persist until user changes settings, got %#v", loaded)
	}
}

func TestInitialModelLeavesRouterUnsetWhenZeroShotModelMissing(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "agent-machine", "tui-config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if m.savedConfig.RouterMode != "" || m.savedConfig.RouterModelDir != "" {
		t.Fatalf("expected router to stay unset without installed model, got %#v", m.savedConfig)
	}
}

func TestModelCommandOpensModelPicker(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		modelOptions: []modelOption{
			{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}},
			{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}},
		},
		modelIndex:    1,
		selectedModel: "openai/gpt-4o-mini",
	}

	updated, _ := m.handleCommand("/model")
	result := updated.(model)

	if !result.modelPickerOpen {
		t.Fatal("expected model picker to open")
	}
	if result.modelPickerIndex != 1 {
		t.Fatalf("expected picker index to follow current model, got %d", result.modelPickerIndex)
	}
	if result.view != viewChat {
		t.Fatalf("expected chat view for picker overlay, got %v", result.view)
	}
}

func TestModelCommandLoadsModelsBeforeOpeningPicker(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
	}

	updated, cmd := m.handleCommand("/model")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected model loading command")
	}
	if !result.modelPickerPending {
		t.Fatal("expected picker to open after model loading")
	}
	if result.modelStatus != "loading models..." {
		t.Fatalf("unexpected model status: %q", result.modelStatus)
	}
}

func TestLoadedModelsOpenPendingModelPicker(t *testing.T) {
	m := model{
		provider:           providerOpenRouter,
		providerSet:        true,
		modelPickerPending: true,
	}

	updated, _ := m.Update(modelListMsg{
		Provider: providerOpenRouter,
		Models: []modelOption{
			{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}},
		},
	})
	result := updated.(model)

	if !result.modelPickerOpen {
		t.Fatal("expected loaded models to open picker")
	}
	if result.modelPickerPending {
		t.Fatal("expected pending state to clear")
	}
}

func TestModelPickerSelectsModelWithArrowAndEnter(t *testing.T) {
	m := model{
		provider:         providerOpenRouter,
		providerSet:      true,
		modelOptions:     []modelOption{{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}}, {ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}}},
		modelIndex:       0,
		modelPickerIndex: 0,
		selectedModel:    "anthropic/claude",
		modelPickerOpen:  true,
		view:             viewChat,
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	updated, _ = updated.(model).Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)

	if result.modelPickerOpen {
		t.Fatal("expected model picker to close after selection")
	}
	if result.selectedModel != "openai/gpt-4o-mini" {
		t.Fatalf("expected selected model to be openai/gpt-4o-mini, got %q", result.selectedModel)
	}
	if result.modelIndex != 1 {
		t.Fatalf("expected model index to update, got %d", result.modelIndex)
	}
}

func TestModelPickerFiltersModelsWhileTyping(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		modelOptions: []modelOption{
			{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}},
			{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}},
		},
		modelPickerOpen:  true,
		modelPickerIndex: 0,
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("g")})
	updated, _ = updated.(model).Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("p")})
	updated, _ = updated.(model).Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("t")})
	result := updated.(model)

	if result.modelPickerQuery != "gpt" {
		t.Fatalf("expected query to be gpt, got %q", result.modelPickerQuery)
	}
	if result.modelPickerIndex != 1 {
		t.Fatalf("expected picker to select matching model, got %d", result.modelPickerIndex)
	}

	updated, _ = result.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result = updated.(model)
	if result.selectedModel != "openai/gpt-4o-mini" {
		t.Fatalf("expected filtered model selection, got %q", result.selectedModel)
	}
}

func TestModelPickerBackspaceUpdatesFilter(t *testing.T) {
	m := model{
		provider:         providerOpenRouter,
		providerSet:      true,
		modelOptions:     []modelOption{{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}}},
		modelPickerOpen:  true,
		modelPickerIndex: 0,
		modelPickerQuery: "gp",
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyBackspace})
	result := updated.(model)

	if result.modelPickerQuery != "g" {
		t.Fatalf("expected query to remove last rune, got %q", result.modelPickerQuery)
	}
}

func TestModelPickerLetterJFiltersInsteadOfMoving(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		modelOptions: []modelOption{
			{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}},
			{ID: "jamba-large", Pricing: modelPricing{InputPerMillion: 2, OutputPerMillion: 8}},
		},
		modelPickerOpen:  true,
		modelPickerIndex: 0,
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("j")})
	result := updated.(model)

	if result.modelPickerQuery != "j" {
		t.Fatalf("expected j to update search query, got %q", result.modelPickerQuery)
	}
	if result.modelPickerIndex != 1 {
		t.Fatalf("expected j search to select jamba-large, got %d", result.modelPickerIndex)
	}
}

func TestModelPickerEscapeCancels(t *testing.T) {
	m := model{
		provider:         providerOpenRouter,
		providerSet:      true,
		modelOptions:     []modelOption{{ID: "anthropic/claude", Pricing: modelPricing{InputPerMillion: 3, OutputPerMillion: 15}}},
		modelPickerOpen:  true,
		modelPickerIndex: 0,
		view:             viewChat,
		selectedModel:    "anthropic/claude",
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	result := updated.(model)
	if result.modelPickerOpen {
		t.Fatal("expected picker to close on escape")
	}
}

func TestAgentCommandOpensAgentDetailView(t *testing.T) {
	m := model{
		agents: map[string]agentState{
			"assistant": {ID: "assistant", Status: "error", Error: "provider rejected request", Attempt: 1},
		},
		agentOrder: []string{"assistant"},
	}

	updated, _ := m.handleCommand("/agent assistant")
	result := updated.(model)

	if result.view != viewAgentDetail {
		t.Fatalf("unexpected view: %v", result.view)
	}

	if result.selectedAgent != "assistant" {
		t.Fatalf("unexpected selected agent: %q", result.selectedAgent)
	}
}

func TestJSONLLineUpdatesLiveAgentTree(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"agent_started","run_id":"run-1","agent_id":"worker","parent_agent_id":"planner","attempt":1,"at":"2026-04-25T10:00:00Z"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"agent_started","run_id":"run-1","agent_id":"planner","attempt":1,"at":"2026-04-25T09:59:59Z"}}`)

	if updated.agents["worker"].ParentAgentID != "planner" {
		t.Fatalf("expected worker parent, got %#v", updated.agents["worker"])
	}

	visible := updated.visibleAgentIDs()
	if strings.Join(visible, ",") != "planner,worker" {
		t.Fatalf("unexpected visible order: %#v", visible)
	}
}

func TestJSONLRunTimeoutMarksRunningAgentsTimedOut(t *testing.T) {
	m := model{agents: map[string]agentState{}, eventAutoScroll: true}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"agent_started","run_id":"run-1","agent_id":"worker","parent_agent_id":"planner","attempt":1,"at":"2026-04-25T10:00:00Z"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"run_timed_out","run_id":"run-1","reason":"hard timeout reached after 3000ms","at":"2026-04-25T10:00:03Z"}}`)

	agent := updated.agents["worker"]
	if agent.Status != "timeout" {
		t.Fatalf("expected timeout status, got %#v", agent)
	}
	if !strings.Contains(agent.Error, "hard timeout") {
		t.Fatalf("expected timeout reason, got %#v", agent)
	}
}

func TestAgentChecklistViewRendersStatusMarkers(t *testing.T) {
	duration := 42
	m := model{
		running: true,
		agents: map[string]agentState{
			"planner": {
				ID:        "planner",
				Status:    "running",
				Attempt:   1,
				StartedAt: "2026-04-25T10:00:00Z",
				Events: []eventSummary{
					{Type: "agent_heartbeat", Summary: "planner heartbeat"},
				},
			},
			"worker": {
				ID:            "worker",
				ParentAgentID: "planner",
				Status:        "ok",
				Attempt:       1,
				DurationMS:    &duration,
				Events: []eventSummary{
					{Type: "agent_finished", Summary: "worker finished with ok"},
				},
			},
			"failed": {
				ID:            "failed",
				ParentAgentID: "planner",
				Status:        "error",
				Attempt:       1,
				Events: []eventSummary{
					{Type: "agent_finished", Summary: "failed finished with error"},
				},
			},
			"timed": {
				ID:            "timed",
				ParentAgentID: "planner",
				Status:        "timeout",
				Attempt:       1,
				Events: []eventSummary{
					{Type: "run_timed_out", Summary: "Run timed out: hard timeout reached"},
				},
			},
		},
		agentOrder: []string{"planner", "worker", "failed", "timed"},
	}

	view := m.agentChecklistView()
	for _, expected := range []string{"[-] planner", "[x] worker", "[!] failed", "[T] timed"} {
		if !strings.Contains(view, expected) {
			t.Fatalf("expected checklist to contain %q, got %q", expected, view)
		}
	}
	if !strings.Contains(view, "parent=planner") {
		t.Fatalf("expected parent context in checklist, got %q", view)
	}
}

func TestJSONLSummaryAppliesCompletedAgentResults(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-1","status":"completed","final_output":"done","results":{"assistant":{"status":"ok","output":"hello","attempt":1}},"usage":{"agents":1},"events":[]}}`)

	if updated.lastSummary.FinalOutput != "done" {
		t.Fatalf("unexpected final output: %q", updated.lastSummary.FinalOutput)
	}
	if updated.agents["assistant"].Output != "hello" {
		t.Fatalf("expected assistant output, got %#v", updated.agents["assistant"])
	}
}

func TestJSONLSummaryAppliesChecklist(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-1","status":"completed","final_output":"done","results":{},"checklist":[{"id":"agent:planner","kind":"agent","label":"planner","status":"done","latest_summary":"planner finished"},{"id":"tool:worker:call-1","kind":"tool","label":"worker read README.md","parent_id":"agent:worker","status":"done","latest_summary":"worker read README.md"}],"usage":{"agents":1},"events":[]}}`)

	if len(updated.workOrder) != 2 {
		t.Fatalf("expected checklist rows, got %#v", updated.workOrder)
	}
	view := updated.workChecklistView()
	if !strings.Contains(view, "[x] planner") || !strings.Contains(view, "worker read README.md") {
		t.Fatalf("expected work checklist to render summary rows, got %q", view)
	}
}

func TestJSONLEventsMaintainWorkChecklist(t *testing.T) {
	m := model{agents: map[string]agentState{}, workItems: map[string]workItem{}}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"agent_delegation_scheduled","run_id":"run-1","agent_id":"planner","delegated_agent_ids":["worker"],"summary":"planner scheduled 1 delegated agent(s)"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"agent_started","run_id":"run-1","agent_id":"worker","parent_agent_id":"planner","summary":"worker started attempt 1","at":"2026-04-25T10:00:00Z"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"tool_call_started","run_id":"run-1","agent_id":"worker","tool_call_id":"call-1","tool":"read_file","summary":"worker started read_file README.md","at":"2026-04-25T10:00:01Z"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"tool_call_finished","run_id":"run-1","agent_id":"worker","tool_call_id":"call-1","tool":"read_file","status":"ok","summary":"worker read README.md","duration_ms":12,"at":"2026-04-25T10:00:02Z"}}`)

	if updated.workItems["agent:worker"].Status != "running" {
		t.Fatalf("expected worker running row, got %#v", updated.workItems["agent:worker"])
	}
	if updated.workItems["tool:worker:call-1"].Status != "done" {
		t.Fatalf("expected tool done row, got %#v", updated.workItems["tool:worker:call-1"])
	}
	view := updated.workChecklistView()
	if !strings.Contains(view, "worker read README.md") || !strings.Contains(view, "duration=12ms") {
		t.Fatalf("expected tool checklist row, got %q", view)
	}
}

func TestJSONLAssistantDeltaUpdatesDraftWithoutLiveFeedNoise(t *testing.T) {
	m := model{agents: map[string]agentState{}, eventAutoScroll: true}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"assistant_delta","run_id":"run-1","agent_id":"assistant","attempt":1,"delta":"hel","summary":"assistant streamed text","details":{"attempt":1},"at":"2026-04-25T10:00:00Z"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"assistant_delta","run_id":"run-1","agent_id":"assistant","attempt":1,"delta":"lo","summary":"assistant streamed text","details":{"attempt":1},"at":"2026-04-25T10:00:01Z"}}`)

	if updated.liveAssistant != "hello" {
		t.Fatalf("expected live assistant draft, got %q", updated.liveAssistant)
	}
	if updated.agents["assistant"].Output != "hello" {
		t.Fatalf("expected agent output draft, got %#v", updated.agents["assistant"])
	}
	if len(updated.eventLog) != 0 {
		t.Fatalf("expected assistant deltas to stay out of event log, got %d", len(updated.eventLog))
	}
	if len(updated.agents["assistant"].Events) != 2 {
		t.Fatalf("expected assistant delta activity in agent event list, got %#v", updated.agents["assistant"].Events)
	}
	for _, event := range updated.agents["assistant"].Events {
		if event.Delta != "" {
			t.Fatalf("expected stored stream event content to be hidden, got %#v", event)
		}
	}
}

func TestLiveActivityViewRendersSummariesAndScrollHint(t *testing.T) {
	m := model{running: true, streamFrame: 1, eventAutoScroll: true}
	for i := 0; i < liveEventWindowSize+1; i++ {
		m.eventLog = append(m.eventLog, eventSummary{
			Type:    "provider_request_started",
			AgentID: "assistant",
			Summary: "assistant sent provider request",
		})
	}
	m.clampEventScroll()

	view := m.liveActivityView()
	if !strings.Contains(view, "assistant sent provider request") {
		t.Fatalf("expected event summary in live view, got %q", view)
	}
	if !strings.Contains(view, "Up/Down scroll") {
		t.Fatalf("expected scroll hint, got %q", view)
	}
}

func TestEnterWhileRunningQueuesMessage(t *testing.T) {
	input := textinput.New()
	input.SetValue("next question")
	m := model{input: input, running: true, view: viewChat}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no run command while current run is active")
	}
	if len(result.queuedMessages) != 1 || result.queuedMessages[0].Text != "next question" {
		t.Fatalf("expected queued message, got %#v", result.queuedMessages)
	}
	if result.input.Value() != "" {
		t.Fatalf("expected input to clear, got %q", result.input.Value())
	}
}

func TestQueueCommandsEditRemoveClearAndRun(t *testing.T) {
	m := model{
		queuedMessages: []queuedMessage{
			{ID: 1, Text: "first"},
			{ID: 2, Text: "second"},
		},
	}

	updated, _ := m.handleCommand("/queue edit 2 updated message")
	result := updated.(model)
	if result.queuedMessages[1].Text != "updated message" {
		t.Fatalf("expected edited queue item, got %#v", result.queuedMessages)
	}

	updated, _ = result.handleCommand("/queue remove 1")
	result = updated.(model)
	if len(result.queuedMessages) != 1 || result.queuedMessages[0].Text != "updated message" {
		t.Fatalf("expected first item removed, got %#v", result.queuedMessages)
	}

	updated, _ = result.handleCommand("/queue clear")
	result = updated.(model)
	if len(result.queuedMessages) != 0 {
		t.Fatalf("expected cleared queue, got %#v", result.queuedMessages)
	}
}

func TestQueueRunStartsImmediatelyWhenIdle(t *testing.T) {
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		configPath:  filepath.Join(t.TempDir(), "config.json"),
		queuedMessages: []queuedMessage{
			{ID: 1, Text: "first"},
			{ID: 2, Text: "second"},
		},
	}

	updated, cmd := m.handleCommand("/queue run 2")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected queued run command")
	}
	if !result.running {
		t.Fatal("expected run to start")
	}
	if len(result.queuedMessages) != 1 || result.queuedMessages[0].Text != "first" {
		t.Fatalf("expected selected item removed from queue, got %#v", result.queuedMessages)
	}
}

func TestQueueRunMovesItemToFrontWhileRunning(t *testing.T) {
	m := model{
		running: true,
		queuedMessages: []queuedMessage{
			{ID: 1, Text: "first"},
			{ID: 2, Text: "second"},
			{ID: 3, Text: "third"},
		},
	}

	updated, cmd := m.handleCommand("/queue run 3")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no command while current run is active")
	}
	if result.queuedMessages[0].Text != "third" {
		t.Fatalf("expected third to move to front, got %#v", result.queuedMessages)
	}
}

func TestQueuedMessageStartsAfterCurrentRun(t *testing.T) {
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		configPath:  filepath.Join(t.TempDir(), "config.json"),
		queuedMessages: []queuedMessage{
			{ID: 1, Text: "next"},
		},
	}

	updated, cmd := m.startNextQueuedRun()
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected queued run command")
	}
	if !result.running || len(result.queuedMessages) != 0 {
		t.Fatalf("expected queued run to start and queue to empty, running=%v queue=%#v", result.running, result.queuedMessages)
	}
}

func TestNonQueueCommandRejectedWhileRunning(t *testing.T) {
	m := model{running: true}

	updated, cmd := m.handleCommand("/provider echo")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no command")
	}
	if len(result.messages) == 0 || !strings.Contains(result.messages[len(result.messages)-1].Text, "command unavailable") {
		t.Fatalf("expected unavailable command message, got %#v", result.messages)
	}
}

func TestQueueRendersInStatusAndChat(t *testing.T) {
	m := model{
		provider:    providerEcho,
		providerSet: true,
		queuedMessages: []queuedMessage{
			{ID: 1, Text: "queued message"},
		},
	}

	if !strings.Contains(m.statusLine(), "queue=1") {
		t.Fatalf("expected queue count in status, got %q", m.statusLine())
	}
	if !strings.Contains(m.chatView(), "queued message") {
		t.Fatalf("expected queued message in chat view, got %q", m.chatView())
	}
}

func TestAgentNavigationOpensSelectedAgentAndEscReturns(t *testing.T) {
	m := model{
		view: viewAgents,
		agents: map[string]agentState{
			"planner": {ID: "planner", Status: "ok"},
			"worker":  {ID: "worker", ParentAgentID: "planner", Status: "running"},
		},
		agentOrder:         []string{"planner", "worker"},
		selectedAgentIndex: 1,
	}

	opened, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := opened.(model)
	if result.view != viewAgentDetail || result.selectedAgent != "worker" {
		t.Fatalf("expected worker detail, got view=%v selected=%q", result.view, result.selectedAgent)
	}

	back, _ := result.Update(tea.KeyMsg{Type: tea.KeyEsc})
	backResult := back.(model)
	if backResult.view != viewAgents {
		t.Fatalf("expected agents view after esc, got %v", backResult.view)
	}
}

func TestInputKeepsCommonTerminalShortcutHandling(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}
	m.view = viewChat
	m.input.SetValue("delete me")

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
	result := updated.(model)

	if result.input.Value() != "" {
		t.Fatalf("expected ctrl+u to clear input, got %q", result.input.Value())
	}
}

func TestInputHistoryUsesUpAndDownOutsideAgentList(t *testing.T) {
	m := model{
		view:         viewChat,
		inputHistory: []string{"/provider echo", "review this project"},
		historyIndex: 2,
	}
	m.input = textInputForTest()
	m.input.SetValue("draft")

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyUp})
	result := updated.(model)
	if result.input.Value() != "review this project" {
		t.Fatalf("expected last history entry, got %q", result.input.Value())
	}

	updated, _ = result.Update(tea.KeyMsg{Type: tea.KeyUp})
	result = updated.(model)
	if result.input.Value() != "/provider echo" {
		t.Fatalf("expected previous history entry, got %q", result.input.Value())
	}

	updated, _ = result.Update(tea.KeyMsg{Type: tea.KeyDown})
	result = updated.(model)
	if result.input.Value() != "review this project" {
		t.Fatalf("expected next history entry, got %q", result.input.Value())
	}

	updated, _ = result.Update(tea.KeyMsg{Type: tea.KeyDown})
	result = updated.(model)
	if result.input.Value() != "draft" {
		t.Fatalf("expected draft restore, got %q", result.input.Value())
	}
}

func TestUpDownKeepSelectingAgentsInAgentList(t *testing.T) {
	m := model{
		view: viewAgents,
		agents: map[string]agentState{
			"planner": {ID: "planner"},
			"worker":  {ID: "worker"},
		},
		agentOrder:   []string{"planner", "worker"},
		inputHistory: []string{"review this project"},
		historyIndex: 1,
	}
	m.input = textInputForTest()

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	result := updated.(model)

	if result.selectedAgentIndex != 1 {
		t.Fatalf("expected agent selection to move, got %d", result.selectedAgentIndex)
	}
	if result.input.Value() != "" {
		t.Fatalf("expected input history untouched in agents view, got %q", result.input.Value())
	}
}

func TestModelsReloadCommandStartsModelLoadingForRemoteProvider(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}
	m.provider = providerOpenRouter
	m.providerSet = true

	_, cmd := m.handleModelsCommand([]string{"reload"})
	if cmd == nil {
		t.Fatal("expected model loading command")
	}
}

func TestCommandEnvInjectsSelectedProviderKey(t *testing.T) {
	env := commandEnv(
		[]string{"PATH=/bin", "OPENROUTER_API_KEY=old-key"},
		runConfig{Provider: providerOpenRouter, APIKey: "new-key"},
	)

	if countEnv(env, "OPENROUTER_API_KEY") != 1 {
		t.Fatalf("expected exactly one OPENROUTER_API_KEY entry, got %#v", env)
	}

	if !containsEnv(env, "OPENROUTER_API_KEY=new-key") {
		t.Fatalf("expected OpenRouter key in env, got %#v", env)
	}

	if !containsEnv(env, "PATH=/bin") {
		t.Fatalf("expected existing env to be preserved, got %#v", env)
	}
}

func TestSavedConfigRoundTripUsesPrivateFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-machine", "config.json")

	err := saveSavedConfig(path, savedConfig{
		OpenAIAPIKey:     "openai-key",
		OpenRouterAPIKey: "openrouter-key",
		Workflow:         "agentic",
		Provider:         "openrouter",
		OpenAIModel:      "gpt-4o-mini",
		OpenRouterModel:  "openai/gpt-4o-mini",
		ToolHarness:      "local-files",
		ToolRoot:         "/tmp/agent-machine-wiki",
		ToolTimeout:      "1000",
		ToolMaxRounds:    "2",
		ToolApproval:     "auto-approved-safe",
	})
	if err != nil {
		t.Fatalf("expected save to succeed, got %v", err)
	}

	loaded, err := loadSavedConfig(path)
	if err != nil {
		t.Fatalf("expected load to succeed, got %v", err)
	}

	if loaded.OpenAIAPIKey != "openai-key" {
		t.Fatalf("unexpected OpenAI key: %q", loaded.OpenAIAPIKey)
	}

	if loaded.OpenRouterAPIKey != "openrouter-key" {
		t.Fatalf("unexpected OpenRouter key: %q", loaded.OpenRouterAPIKey)
	}
	if loaded.Workflow != "agentic" {
		t.Fatalf("unexpected workflow: %q", loaded.Workflow)
	}
	if loaded.Provider != "openrouter" {
		t.Fatalf("unexpected provider: %q", loaded.Provider)
	}
	if loaded.OpenAIModel != "gpt-4o-mini" {
		t.Fatalf("unexpected OpenAI model: %q", loaded.OpenAIModel)
	}
	if loaded.OpenRouterModel != "openai/gpt-4o-mini" {
		t.Fatalf("unexpected OpenRouter model: %q", loaded.OpenRouterModel)
	}
	if loaded.ToolHarness != "local-files" {
		t.Fatalf("unexpected tool harness: %q", loaded.ToolHarness)
	}
	if loaded.ToolRoot != "/tmp/agent-machine-wiki" {
		t.Fatalf("unexpected tool root: %q", loaded.ToolRoot)
	}
	if loaded.ToolTimeout != "1000" {
		t.Fatalf("unexpected tool timeout: %q", loaded.ToolTimeout)
	}
	if loaded.ToolMaxRounds != "2" {
		t.Fatalf("unexpected tool max rounds: %q", loaded.ToolMaxRounds)
	}
	if loaded.ToolApproval != "auto-approved-safe" {
		t.Fatalf("unexpected tool approval mode: %q", loaded.ToolApproval)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("expected config file stat to succeed, got %v", err)
	}

	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("expected config permissions 0600, got %o", got)
	}
}

func containsEnv(env []string, expected string) bool {
	for _, value := range env {
		if value == expected {
			return true
		}
	}

	return false
}

func containsArgPair(args []string, key string, value string) bool {
	for index := 0; index < len(args)-1; index++ {
		if args[index] == key && args[index+1] == value {
			return true
		}
	}

	return false
}

func countEnv(env []string, name string) int {
	count := 0
	prefix := name + "="

	for _, value := range env {
		if strings.HasPrefix(value, prefix) {
			count++
		}
	}

	return count
}

func assertContainsSequence(t *testing.T, values []string, sequence []string) {
	t.Helper()

	for i := 0; i <= len(values)-len(sequence); i++ {
		matched := true
		for j := range sequence {
			if values[i+j] != sequence[j] {
				matched = false
				break
			}
		}
		if matched {
			return
		}
	}

	t.Fatalf("expected %#v to contain sequence %#v", values, sequence)
}

func textInputForTest() textinput.Model {
	input := textinput.New()
	input.Focus()
	return input
}

func writeRouterModelFilesForTest(t *testing.T, modelDir string) {
	t.Helper()

	for _, path := range []string{
		filepath.Join(modelDir, "tokenizer.json"),
		filepath.Join(modelDir, "config.json"),
		filepath.Join(modelDir, "onnx", "model_quantized.onnx"),
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatalf("expected router model directory creation to succeed, got %v", err)
		}
		if err := os.WriteFile(path, []byte("{}"), 0o600); err != nil {
			t.Fatalf("expected router model file write to succeed, got %v", err)
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

func TestParseSummaryIncludesFailedResultErrors(t *testing.T) {
	parsed, err := parseSummary(`{"run_id":"run-1","status":"failed","error":"assistant: provider rejected request","final_output":null,"results":{"assistant":{"status":"error","error":"provider rejected request"}},"usage":{"agents":0,"input_tokens":0,"output_tokens":0,"total_tokens":0,"cost_usd":0},"events":[]}`)
	if err != nil {
		t.Fatalf("expected parse to succeed, got %v", err)
	}

	if parsed.Status != "failed" {
		t.Fatalf("unexpected status: %q", parsed.Status)
	}

	if summaryError(parsed) != "assistant: provider rejected request" {
		t.Fatalf("unexpected summary error: %q", summaryError(parsed))
	}
}

func TestParseSummaryRequiresJSONLine(t *testing.T) {
	_, err := parseSummary("Compiling files\nGenerated app")
	if err == nil {
		t.Fatal("expected parse error")
	}
}
