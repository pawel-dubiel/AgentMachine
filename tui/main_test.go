package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

var ansiEscapePattern = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(text string) string {
	return ansiEscapePattern.ReplaceAllString(text, "")
}

type closeBuffer struct {
	bytes.Buffer
}

func (buffer *closeBuffer) Close() error {
	return nil
}

func writeTestFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("failed to write test file %s: %v", path, err)
	}
}

func TestProjectRootUsesExplicitAgentMachineRoot(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "mix.exs"), "defmodule AgentMachine.MixProject do\nend\n")
	t.Setenv("AGENT_MACHINE_ROOT", root)

	resolved, err := projectRoot()
	if err != nil {
		t.Fatalf("expected explicit project root to resolve, got %v", err)
	}

	expected, err := filepath.Abs(root)
	if err != nil {
		t.Fatalf("failed to resolve temp root: %v", err)
	}
	if resolved != expected {
		t.Fatalf("expected %q, got %q", expected, resolved)
	}
}

func TestProjectRootRejectsInvalidExplicitRoot(t *testing.T) {
	root := t.TempDir()
	t.Setenv("AGENT_MACHINE_ROOT", root)

	_, err := projectRoot()
	if err == nil {
		t.Fatalf("expected invalid explicit root to fail")
	}
	if !strings.Contains(err.Error(), "AGENT_MACHINE_ROOT") || !strings.Contains(err.Error(), "mix.exs") {
		t.Fatalf("expected root validation error, got %v", err)
	}
}

func TestProjectRootFailsOutsideRepositoryWithoutExplicitRoot(t *testing.T) {
	t.Setenv("AGENT_MACHINE_ROOT", "")
	t.Chdir(t.TempDir())

	_, err := projectRoot()
	if err == nil {
		t.Fatalf("expected missing project root to fail")
	}
	if !strings.Contains(err.Error(), "AGENT_MACHINE_ROOT") {
		t.Fatalf("expected setup guidance, got %v", err)
	}
}

func TestProjectRootFindsParentRepositoryFromTUIDirectory(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "mix.exs"), "defmodule AgentMachine.MixProject do\nend\n")
	tuiDir := filepath.Join(root, "tui")
	if err := os.Mkdir(tuiDir, 0o700); err != nil {
		t.Fatalf("failed to create tui dir: %v", err)
	}
	t.Setenv("AGENT_MACHINE_ROOT", "")
	t.Chdir(tuiDir)

	resolved, err := projectRoot()
	if err != nil {
		t.Fatalf("expected parent project root to resolve, got %v", err)
	}
	if resolved != root {
		t.Fatalf("expected %q, got %q", root, resolved)
	}
}

func TestBuildRunArgsIncludesExplicitRuntimeOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "review this project",
		Workflow: workflowAgentic,
		Provider: providerEcho,
	})

	expected := []string{
		"agent_machine.run",
		"--provider", "echo",
		"--timeout-ms", defaultAgenticRunTimeoutMS,
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
		Workflow:   workflowAgentic,
		Provider:   providerEcho,
		RunTimeout: "240000",
	})

	expected := []string{
		"agent_machine.run",
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

func TestBuildRunArgsIncludesAgenticPersistenceOnlyWhenEnabled(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:                     "review this project",
		Workflow:                 workflowAgentic,
		Provider:                 providerEcho,
		RunTimeout:               "300000",
		MaxSteps:                 "9",
		AgenticPersistenceRounds: "2",
	})

	if containsArg(args, "--workflow") ||
		!containsArgPair(args, "--timeout-ms", "300000") ||
		!containsArgPair(args, "--max-steps", "9") {
		t.Fatalf("expected explicit persistence runtime args, got %#v", args)
	}
	assertContainsSequence(t, args, []string{"--agentic-persistence-rounds", "2", "review this project"})

	withoutPersistence := buildRunArgs(runConfig{
		Task:     "review this project",
		Workflow: workflowAgentic,
		Provider: providerEcho,
	})
	for _, arg := range withoutPersistence {
		if arg == "--agentic-persistence-rounds" {
			t.Fatalf("unexpected persistence flag when disabled: %#v", withoutPersistence)
		}
	}
}

func TestBuildRunArgsIncludesPlannerReviewWhenEnabled(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:                      "review this project",
		Workflow:                  workflowAgentic,
		Provider:                  providerEcho,
		PlannerReviewMaxRevisions: "2",
	})

	assertContainsSequence(t, args, []string{"--planner-review", "jsonl-stdio", "--planner-review-max-revisions", "2", "review this project"})
}

func TestSessionRunPayloadUsesTypedRuntimeOptions(t *testing.T) {
	logFile := filepath.Join(t.TempDir(), "run.jsonl")
	payload, err := sessionRunPayload(runConfig{
		Task:              "review this project",
		Workflow:          workflowAgentic,
		Provider:          providerOpenRouter,
		Model:             "moonshotai/kimi-k2.6",
		LogFile:           logFile,
		InputPrice:        "1.00",
		OutputPrice:       "3.00",
		HTTPTimeout:       "120000",
		RunTimeout:        "240000",
		ToolHarness:       "code-edit",
		ToolRoot:          "/tmp/project",
		ToolTimeout:       "120000",
		ToolMaxRounds:     "6",
		ToolApproval:      "ask-before-write",
		TestCommands:      []string{"mix test"},
		MCPConfig:         "/tmp/mcp.json",
		RunContextCompact: "off",
	})
	if err != nil {
		t.Fatalf("sessionRunPayload returned error: %v", err)
	}

	if payload["task"] != "review this project" || payload["provider"] != "openrouter" {
		t.Fatalf("unexpected basic payload: %#v", payload)
	}
	if _, ok := payload["workflow"]; ok {
		t.Fatalf("session payload must omit workflow, got %#v", payload["workflow"])
	}
	if payload["log_file"] != logFile {
		t.Fatalf("expected run log file in payload, got %#v", payload)
	}
	if payload["timeout_ms"] != 240000 || payload["session_tool_timeout_ms"] != 240000 {
		t.Fatalf("expected typed timeout values, got %#v", payload)
	}
	if payload["session_tool_max_rounds"] != 16 {
		t.Fatalf("expected explicit session tool max rounds, got %#v", payload["session_tool_max_rounds"])
	}
	harnesses, ok := payload["tool_harnesses"].([]string)
	if !ok || strings.Join(harnesses, ",") != "code-edit,mcp" {
		t.Fatalf("unexpected tool harnesses: %#v", payload["tool_harnesses"])
	}
	pricing, ok := payload["pricing"].(map[string]any)
	if !ok || pricing["input_per_million"] != 1.0 || pricing["output_per_million"] != 3.0 {
		t.Fatalf("unexpected pricing payload: %#v", payload["pricing"])
	}
}

func TestSessionRunPayloadIncludesAgenticPersistenceWhenEnabled(t *testing.T) {
	payload, err := sessionRunPayload(runConfig{
		Task:                     "review this project",
		Workflow:                 workflowAgentic,
		Provider:                 providerEcho,
		RunTimeout:               "300000",
		MaxSteps:                 "9",
		AgenticPersistenceRounds: "2",
	})
	if err != nil {
		t.Fatalf("sessionRunPayload returned error: %v", err)
	}

	if payload["max_steps"] != 9 || payload["timeout_ms"] != 300000 {
		t.Fatalf("unexpected agentic persistence payload: %#v", payload)
	}
	if _, ok := payload["workflow"]; ok {
		t.Fatalf("session payload must omit workflow, got %#v", payload["workflow"])
	}
	if payload["agentic_persistence_rounds"] != 2 {
		t.Fatalf("expected persistence rounds in payload, got %#v", payload)
	}
}

func TestSessionRunPayloadIncludesPlannerReviewWhenEnabled(t *testing.T) {
	payload, err := sessionRunPayload(runConfig{
		Task:                      "review this project",
		Workflow:                  workflowAgentic,
		Provider:                  providerEcho,
		PlannerReviewMaxRevisions: "2",
	})
	if err != nil {
		t.Fatalf("sessionRunPayload returned error: %v", err)
	}

	if _, ok := payload["workflow"]; ok {
		t.Fatalf("session payload must omit workflow, got %#v", payload["workflow"])
	}
	if payload["planner_review_mode"] != "jsonl-stdio" || payload["planner_review_max_revisions"] != 2 {
		t.Fatalf("expected planner review payload, got %#v", payload)
	}
}

func TestSessionUserMessagePayloadRejectsInvalidNumbers(t *testing.T) {
	_, err := sessionUserMessagePayload(runConfig{
		Task:         "review this project",
		Workflow:     workflowAgentic,
		Provider:     providerEcho,
		RunTimeout:   "nope",
		EventLogFile: filepath.Join(t.TempDir(), "session.jsonl"),
	})
	if err == nil {
		t.Fatal("expected invalid run timeout error")
	}
}

func TestBuildRunArgsIncludesLocalRouterOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:             "review this project",
		Workflow:         workflowAgentic,
		Provider:         providerEcho,
		RouterMode:       "local",
		RouterModelDir:   "/tmp/agent-machine-router-model",
		RouterTimeout:    "5000",
		RouterConfidence: "0.55",
	})

	expected := []string{
		"agent_machine.run",
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

func TestBuildRunArgsIncludesExplicitLLMRouterMode(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:       "review this project",
		Workflow:   workflowAgentic,
		Provider:   providerOpenRouter,
		Model:      "openai/gpt-4o-mini",
		RouterMode: "llm",
	})

	assertContainsSequence(t, args, []string{"--router-mode", "llm"})
	if containsArg(args, "--router-model-dir") {
		t.Fatalf("expected llm router not to include local router options: %#v", args)
	}
}

func TestBuildRunArgsIncludesSessionEventLog(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:           "review this project",
		Workflow:       workflowAgentic,
		Provider:       providerEcho,
		EventLogFile:   "/tmp/agent-machine-session.jsonl",
		EventSessionID: "session-1",
	})

	assertContainsSequence(t, args, []string{"--event-log-file", "/tmp/agent-machine-session.jsonl"})
	assertContainsSequence(t, args, []string{"--event-session-id", "session-1"})
}

func TestBuildRunArgsIncludesProgressObserver(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:             "hello",
		Workflow:         workflowAgentic,
		Provider:         providerEcho,
		RunTimeout:       "1000",
		MaxSteps:         "1",
		ProgressObserver: true,
	})

	assertContainsSequence(t, args, []string{"--progress-observer"})
}

func TestSessionRunPayloadIncludesProgressObserver(t *testing.T) {
	payload, err := sessionRunPayload(runConfig{
		Task:             "hello",
		Workflow:         workflowAgentic,
		Provider:         providerEcho,
		RunTimeout:       "1000",
		MaxSteps:         "1",
		EventLogFile:     filepath.Join(t.TempDir(), "session.jsonl"),
		EventSessionID:   "session-1",
		ProgressObserver: true,
	})
	if err != nil {
		t.Fatalf("expected session run payload: %v", err)
	}

	if payload["progress_observer"] != true {
		t.Fatalf("expected progress observer payload, got %#v", payload)
	}
}

func TestBuildRunArgsIncludesContextOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:              "review this project",
		Workflow:          workflowAgentic,
		Provider:          providerEcho,
		ContextWindow:     "128000",
		ContextWarning:    "80",
		ContextTokenizer:  "/tmp/context-tokenizer.json",
		ReservedOutput:    "4096",
		RunContextCompact: "on",
		ContextCompactPct: "90",
		MaxContextCompact: "2",
	})

	assertContainsSequence(t, args, []string{"--context-window-tokens", "128000"})
	assertContainsSequence(t, args, []string{"--context-warning-percent", "80"})
	assertContainsSequence(t, args, []string{"--context-tokenizer-path", "/tmp/context-tokenizer.json"})
	assertContainsSequence(t, args, []string{"--reserved-output-tokens", "4096"})
	assertContainsSequence(t, args, []string{"--run-context-compaction", "on"})
	assertContainsSequence(t, args, []string{"--run-context-compact-percent", "90"})
	assertContainsSequence(t, args, []string{"--max-context-compactions", "2"})
}

func TestContextTokenizerAndReserveCommandsPersistConfig(t *testing.T) {
	dir := t.TempDir()
	tokenizerPath := filepath.Join(dir, "tokenizer.json")
	if err := os.WriteFile(tokenizerPath, []byte("{}"), 0o600); err != nil {
		t.Fatalf("failed to write tokenizer fixture: %v", err)
	}

	configPath := filepath.Join(dir, "config.json")
	m := model{configPath: configPath}

	updated, _ := m.handleContextTokenizerCommand([]string{tokenizerPath})
	result := updated.(model)
	if result.savedConfig.ContextTokenizer != tokenizerPath {
		t.Fatalf("expected tokenizer path to persist in model, got %q", result.savedConfig.ContextTokenizer)
	}

	updated, _ = result.handleContextReserveCommand([]string{"4096"})
	result = updated.(model)
	if result.savedConfig.ReservedOutput != "4096" {
		t.Fatalf("expected reserved output to persist in model, got %q", result.savedConfig.ReservedOutput)
	}

	saved, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config, got %v", err)
	}
	if saved.ContextTokenizer != tokenizerPath || saved.ReservedOutput != "4096" {
		t.Fatalf("unexpected saved context config: %#v", saved)
	}
}

func TestThemeCommandPersistsSelectedTheme(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{configPath: configPath, theme: themeClassic}

	updated, _ := m.handleCommand("/theme matrix")
	result := updated.(model)

	if result.theme != themeMatrix {
		t.Fatalf("expected matrix theme in model, got %q", result.theme)
	}
	if result.savedConfig.Theme != string(themeMatrix) {
		t.Fatalf("expected matrix theme in saved config, got %#v", result.savedConfig)
	}
	if len(result.messages) == 0 || !strings.Contains(result.messages[len(result.messages)-1].Text, "theme set to matrix") {
		t.Fatalf("expected theme confirmation message, got %#v", result.messages)
	}

	saved, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config, got %v", err)
	}
	if saved.Theme != string(themeMatrix) {
		t.Fatalf("expected persisted matrix theme, got %#v", saved)
	}
}

func TestThemeCommandRejectsUnknownTheme(t *testing.T) {
	m := model{configPath: filepath.Join(t.TempDir(), "config.json"), theme: themeClassic}

	updated, _ := m.handleCommand("/theme neon")
	result := updated.(model)

	if result.theme != themeClassic {
		t.Fatalf("expected theme to remain classic, got %q", result.theme)
	}
	if result.savedConfig.Theme != "" {
		t.Fatalf("expected invalid theme not to persist, got %#v", result.savedConfig)
	}
	if len(result.messages) == 0 || !strings.Contains(result.messages[len(result.messages)-1].Text, "usage: /theme classic|matrix") {
		t.Fatalf("expected usage message, got %#v", result.messages)
	}
}

func TestInitialModelFailsOnInvalidSavedTheme(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := saveSavedConfig(configPath, savedConfig{Theme: "neon"}); err != nil {
		t.Fatalf("expected save to succeed, got %v", err)
	}
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	_, err := initialModel()

	if err == nil || !strings.Contains(err.Error(), "invalid saved theme") {
		t.Fatalf("expected invalid saved theme error, got %v", err)
	}
}

func TestTUIConfigPathUsesHomeAgentMachineByDefault(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	workspace := filepath.Join(dir, "workspace", "project")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatalf("failed to create workspace: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Chdir(workspace)

	configPath, err := tuiConfigPath()
	if err != nil {
		t.Fatalf("expected config path, got %v", err)
	}

	expected := filepath.Join(home, ".agent-machine", "tui-config.json")
	if configPath != expected {
		t.Fatalf("expected %q, got %q", expected, configPath)
	}
}

func TestLoadResolvedSavedConfigAppliesProjectOverrideWithoutSecrets(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	project := filepath.Join(dir, "repo")
	subdir := filepath.Join(project, "apps", "demo")
	if err := os.MkdirAll(subdir, 0o700); err != nil {
		t.Fatalf("failed to create project fixture: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Chdir(subdir)

	userPath := filepath.Join(home, ".agent-machine", "tui-config.json")
	if err := saveSavedConfig(userPath, savedConfig{
		OpenRouterAPIKey: "user-secret",
		Provider:         "echo",
		ToolTimeout:      "1000",
	}); err != nil {
		t.Fatalf("failed to write user config: %v", err)
	}

	projectPath := filepath.Join(project, ".agent-machine", "tui-config.json")
	if err := saveSavedConfig(projectPath, savedConfig{
		Provider:        "openrouter",
		OpenRouterModel: "x-ai/grok-4.3",
		ToolRoot:        ".",
		ToolTimeout:     "120000",
		MCPConfig:       ".agent-machine/mcp.json",
	}); err != nil {
		t.Fatalf("failed to write project config: %v", err)
	}

	resolution, err := resolveTUIConfig()
	if err != nil {
		t.Fatalf("expected config resolution, got %v", err)
	}
	config, loadedLegacy, err := loadResolvedSavedConfig(resolution)
	if err != nil {
		t.Fatalf("expected merged config, got %v", err)
	}

	if loadedLegacy {
		t.Fatal("expected user config, not legacy fallback")
	}
	if resolution.Path != userPath {
		t.Fatalf("expected user config path %q, got %q", userPath, resolution.Path)
	}
	if resolution.ProjectPath != projectPath {
		t.Fatalf("expected project config path %q, got %q", projectPath, resolution.ProjectPath)
	}
	if config.OpenRouterAPIKey != "user-secret" {
		t.Fatalf("expected user API key to remain user scoped, got %#v", config)
	}
	if config.Provider != "openrouter" || config.OpenRouterModel != "x-ai/grok-4.3" {
		t.Fatalf("expected project provider/model override, got %#v", config)
	}
	if config.ToolTimeout != "120000" || config.ToolRoot != project {
		t.Fatalf("expected project tool override with resolved root, got %#v", config)
	}
	expectedMCPConfig := filepath.Join(project, ".agent-machine", "mcp.json")
	if config.MCPConfig != expectedMCPConfig {
		t.Fatalf("expected project MCP path %q, got %q", expectedMCPConfig, config.MCPConfig)
	}
}

func TestInitialModelMigratesHomeToolRootToLaunchDirectory(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	workspace := filepath.Join(home, "repo")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatalf("failed to create workspace: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Chdir(workspace)

	configPath := filepath.Join(home, ".agent-machine", "tui-config.json")
	if err := saveSavedConfig(configPath, savedConfig{
		Provider:      "echo",
		ToolHarness:   "local-files",
		ToolRoot:      home,
		ToolTimeout:   "120000",
		ToolMaxRounds: "16",
		ToolApproval:  "ask-before-write",
	}); err != nil {
		t.Fatalf("failed to write user config: %v", err)
	}

	model, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if model.savedConfig.ToolRoot != workspace {
		t.Fatalf("expected launch workspace root, got %#v", model.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolRoot != workspace {
		t.Fatalf("expected migrated saved root %q, got %q", workspace, loaded.ToolRoot)
	}
}

func TestInitialModelMigratesTUISubdirToolRootToLaunchDirectory(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	workspace := t.TempDir()
	tuiRoot := filepath.Join(workspace, "tui")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	t.Chdir(workspace)

	if err := saveSavedConfig(configPath, savedConfig{
		Provider:      "echo",
		ToolHarness:   "code-edit",
		ToolRoot:      tuiRoot,
		ToolTimeout:   "120000",
		ToolMaxRounds: "16",
		ToolApproval:  "ask-before-write",
	}); err != nil {
		t.Fatalf("failed to write user config: %v", err)
	}

	model, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if model.savedConfig.ToolRoot != workspace {
		t.Fatalf("expected launch workspace root, got %#v", model.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolRoot != workspace {
		t.Fatalf("expected migrated saved root %q, got %q", workspace, loaded.ToolRoot)
	}
}

func TestInitialModelUsesLaunchDirectoryAsToolRootBase(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	workspace := t.TempDir()
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	t.Chdir(workspace)

	model, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if model.toolRootBaseDir() != workspace {
		t.Fatalf("expected launch directory %q as tool root base, got %q", workspace, model.toolRootBaseDir())
	}
}

func TestInitialModelInitializesDefaultSkillsDir(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	workspace := filepath.Join(home, "repo")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatalf("failed to create workspace: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Chdir(workspace)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	expected := filepath.Join(home, ".agent-machine", "skills")
	if m.savedConfig.SkillsDir != expected {
		t.Fatalf("expected default skills dir %q, got %q", expected, m.savedConfig.SkillsDir)
	}
	if info, err := os.Stat(expected); err != nil || !info.IsDir() {
		t.Fatalf("expected default skills dir to exist, stat=%#v err=%v", info, err)
	}

	loaded, err := loadSavedConfig(filepath.Join(home, ".agent-machine", "tui-config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if loaded.SkillsDir != expected {
		t.Fatalf("expected persisted default skills dir %q, got %q", expected, loaded.SkillsDir)
	}
}

func TestInitialModelMigratesLegacyConfigToHomeAgentMachine(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	workspace := filepath.Join(dir, "workspace")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatalf("failed to create workspace fixture: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	t.Chdir(workspace)

	legacyPath, err := legacyTUIConfigPath()
	if err != nil {
		t.Fatalf("expected legacy config path, got %v", err)
	}
	if err := saveSavedConfig(legacyPath, savedConfig{Theme: string(themeMatrix)}); err != nil {
		t.Fatalf("failed to write legacy config: %v", err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model to load legacy config, got %v", err)
	}

	if m.configPath != filepath.Join(home, ".agent-machine", "tui-config.json") {
		t.Fatalf("expected new user config path, got %q", m.configPath)
	}
	if m.theme != themeMatrix {
		t.Fatalf("expected legacy theme to load, got %q", m.theme)
	}
	migrated, err := loadSavedConfig(m.configPath)
	if err != nil {
		t.Fatalf("expected migrated user config, got %v", err)
	}
	if migrated.Theme != string(themeMatrix) {
		t.Fatalf("expected migrated legacy config, got %#v", migrated)
	}
}

func TestProjectTUIConfigRejectsSecrets(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	project := filepath.Join(dir, "repo")
	if err := os.MkdirAll(project, 0o700); err != nil {
		t.Fatalf("failed to create project fixture: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Chdir(project)

	projectPath := filepath.Join(project, ".agent-machine", "tui-config.json")
	if err := saveSavedConfig(projectPath, savedConfig{OpenAIAPIKey: "project-secret"}); err != nil {
		t.Fatalf("failed to write project config: %v", err)
	}

	resolution, err := resolveTUIConfig()
	if err != nil {
		t.Fatalf("expected config resolution, got %v", err)
	}
	_, _, err = loadResolvedSavedConfig(resolution)
	if err == nil || !strings.Contains(err.Error(), "must not contain API keys") {
		t.Fatalf("expected project secret rejection, got %v", err)
	}
}

func TestProjectTUIConfigCannotInheritFullAccessForToolSurface(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "home")
	project := filepath.Join(dir, "repo")
	if err := os.MkdirAll(project, 0o700); err != nil {
		t.Fatalf("failed to create project fixture: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", "")
	t.Setenv("HOME", home)
	t.Chdir(project)

	userPath := filepath.Join(home, ".agent-machine", "tui-config.json")
	if err := saveSavedConfig(userPath, savedConfig{
		ToolApproval: "full-access",
		ToolRoot:     project,
	}); err != nil {
		t.Fatalf("failed to write user config: %v", err)
	}

	projectPath := filepath.Join(project, ".agent-machine", "tui-config.json")
	if err := saveSavedConfig(projectPath, savedConfig{
		MCPConfig: ".agent-machine/mcp.json",
	}); err != nil {
		t.Fatalf("failed to write project config: %v", err)
	}

	resolution, err := resolveTUIConfig()
	if err != nil {
		t.Fatalf("expected config resolution, got %v", err)
	}
	_, _, err = loadResolvedSavedConfig(resolution)
	if err == nil || !strings.Contains(err.Error(), "must not inherit full-access") {
		t.Fatalf("expected full-access inheritance rejection, got %v", err)
	}
}

func TestStatusLineRendersContextBudgetEvents(t *testing.T) {
	available := 69000
	used := 42.3
	m := model{
		provider:    providerEcho,
		providerSet: true,
		latestContextBudget: &eventSummary{
			Type:            "context_budget",
			Status:          "ok",
			UsedTokens:      54123,
			ContextWindow:   128000,
			AvailableTokens: &available,
			UsedPercent:     &used,
		},
	}
	if status := m.statusLine(); !strings.Contains(status, "ctx=42.3% 54123/128000 avail=69000") {
		t.Fatalf("expected known context budget in status, got %q", status)
	}

	warning := 86.1
	m.latestContextBudget = &eventSummary{
		Type:            "context_budget",
		Status:          "warning",
		UsedTokens:      110000,
		ContextWindow:   128000,
		AvailableTokens: &available,
		UsedPercent:     &warning,
	}
	if status := m.statusLine(); !strings.Contains(status, "ctx=warning 86.1% 110000/128000 avail=69000") {
		t.Fatalf("expected warning context budget in status, got %q", status)
	}

	m.latestContextBudget = &eventSummary{
		Type:   "context_budget",
		Status: "unknown",
		Reason: "missing_context_tokenizer_path",
	}
	if status := m.statusLine(); !strings.Contains(status, "ctx=unknown missing_context_tokenizer_path") {
		t.Fatalf("expected unknown context budget in status, got %q", status)
	}
}

func TestStatusLinesRenderSessionUsageWorkingDirAndBranch(t *testing.T) {
	t.Setenv("HOME", "/Users/pawel")
	m := model{
		running:         true,
		workingDir:      "/Users/pawel/priv/elixir",
		gitBranchStatus: "codex/status-line",
		sessionUsage: usageSummary{
			TotalTokens: 12345,
		},
	}

	for _, line := range []string{
		m.statusLine(),
		m.inputStatusLine("Running. Enter queues message. /queue edits queue. Tab navigates."),
		m.inputStatusLine("Type a message or /help. Tab changes view. Esc goes back."),
	} {
		if !strings.Contains(line, "session_tokens=12345") {
			t.Fatalf("expected token usage in status line, got %q", line)
		}
		if !strings.Contains(line, "cwd=~/priv/elixir") {
			t.Fatalf("expected compact cwd in status line, got %q", line)
		}
		if !strings.Contains(line, "branch=codex/status-line") {
			t.Fatalf("expected branch in status line, got %q", line)
		}
	}
	if !strings.Contains(m.inputStatusLine("Running. Enter queues message. /queue edits queue. Tab navigates."), "Running. Enter queues message. /queue edits queue. Tab navigates.") {
		t.Fatalf("expected running queue help to remain, got %q", m.inputStatusLine("Running. Enter queues message. /queue edits queue. Tab navigates."))
	}
}

func TestDefaultInputHintRendersSessionStatus(t *testing.T) {
	t.Setenv("HOME", "/Users/pawel")
	m := model{
		input:           textinput.New(),
		workingDir:      "/Users/pawel/priv/elixir",
		gitBranchStatus: "main",
		sessionUsage: usageSummary{
			TotalTokens: 42,
		},
	}

	view := stripANSI(m.View())
	if !strings.Contains(view, "Type a message or /help. Tab changes view. Esc goes back.") {
		t.Fatalf("expected default prompt help, got %q", view)
	}
	if !strings.Contains(view, "session_tokens=42") || !strings.Contains(view, "cwd=~/priv/elixir") || !strings.Contains(view, "branch=main") {
		t.Fatalf("expected session status in default prompt hint, got %q", view)
	}
}

func TestCompactWorkingDirStatusUsesHomeRelativePath(t *testing.T) {
	t.Setenv("HOME", "/Users/pawel")

	if got := compactWorkingDirStatus("/Users/pawel/priv/elixir"); got != "~/priv/elixir" {
		t.Fatalf("expected home-relative cwd, got %q", got)
	}
	if got := compactWorkingDirStatus(""); got != "missing" {
		t.Fatalf("expected explicit missing cwd, got %q", got)
	}
}

func TestGitBranchStatusForWorkingDirReportsNotGit(t *testing.T) {
	if got := gitBranchStatusForWorkingDir(t.TempDir()); got != "not-git" {
		t.Fatalf("expected not-git status, got %q", got)
	}
}

func TestGitBranchStatusForWorkingDirReportsBranchAndDetachedHead(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skipf("git is required for branch status test: %v", err)
	}
	repo := t.TempDir()
	runGit(t, repo, "init")
	runGit(t, repo, "checkout", "-B", "status-test")

	if got := gitBranchStatusForWorkingDir(repo); got != "status-test" {
		t.Fatalf("expected branch name, got %q", got)
	}

	runGit(t, repo, "-c", "user.name=AgentMachine Test", "-c", "user.email=agent-machine@example.test", "commit", "--allow-empty", "-m", "init")
	runGit(t, repo, "checkout", "--detach", "HEAD")
	if got := gitBranchStatusForWorkingDir(repo); !strings.HasPrefix(got, "detached:") {
		t.Fatalf("expected detached branch status, got %q", got)
	}
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	commandArgs := append([]string{"-C", dir}, args...)
	cmd := exec.Command("git", commandArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, string(output))
	}
	return strings.TrimSpace(string(output))
}

func TestBuildRunArgsUsesLongerTimeoutForAutoRuns(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "fix the existing app",
		Workflow: workflowAgentic,
		Provider: providerEcho,
	})

	assertContainsSequence(t, args, []string{"--timeout-ms", defaultAgenticRunTimeoutMS})
}

func TestBuildRunArgsIncludesLocalFileToolHarness(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "create hello",
		Workflow:      workflowAgentic,
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
		"--provider", "openrouter",
		"--timeout-ms", defaultAgenticRunTimeoutMS,
		"--max-steps", defaultAgenticSteps,
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

func TestBuildRunArgsIncludesPermissionControlForAskBeforeWriteTools(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:          "edit app",
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "3",
		ToolApproval:  "ask-before-write",
	})

	assertContainsSequence(t, args, []string{"--tool-approval-mode", "ask-before-write"})
	assertContainsSequence(t, args, []string{"--permission-control", "jsonl-stdio"})
	assertContainsSequence(t, args, []string{"--tool-root", "/tmp/agent-machine-project"})
}

func TestBuildRunArgsIncludesRunLogFile(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "review this project",
		Workflow: workflowAgentic,
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
		Workflow:      workflowAgentic,
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
		Workflow:      workflowAgentic,
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
		Workflow: workflowAgentic,
		Provider: providerOpenRouter,
		Model:    "qwen/qwen3.5-flash-02-23",
	})

	if !strings.Contains(withoutTools, "tools off") {
		t.Fatalf("expected tools off in running status, got %q", withoutTools)
	}
	if !strings.Contains(withoutTools, "strategy pending") {
		t.Fatalf("expected pending strategy in running status, got %q", withoutTools)
	}
	if !strings.Contains(withoutTools, "router llm current model") {
		t.Fatalf("expected llm router in running status, got %q", withoutTools)
	}
	if !strings.Contains(withoutTools, "idle_timeout_ms="+defaultAgenticRunTimeoutMS+" hard_cap_ms=720000") {
		t.Fatalf("expected auto idle lease and hard cap in running status, got %q", withoutTools)
	}

	withTools := runningStatus(runConfig{
		Workflow:    workflowAgentic,
		Provider:    providerOpenRouter,
		Model:       "qwen/qwen3.5-flash-02-23",
		ToolHarness: "local-files",
		ToolRoot:    "/tmp/agent-machine-home",
	})

	if !strings.Contains(withTools, "tools local-files root=/tmp/agent-machine-home") {
		t.Fatalf("expected tool root in running status, got %q", withTools)
	}

	withLocalRouter := runningStatus(runConfig{
		Workflow:         workflowAgentic,
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
		Workflow:      workflowAgentic,
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
		"--provider", "openrouter",
		"--timeout-ms", defaultAgenticRunTimeoutMS,
		"--max-steps", defaultAgenticSteps,
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
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "time",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "read-only",
	})

	expected := []string{
		"agent_machine.run",
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
		Workflow:    workflowAgentic,
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
		Workflow:    workflowAgentic,
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
		Workflow:         workflowAgentic,
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

func TestValidateConfigAcceptsLLMRouterConfig(t *testing.T) {
	err := validateConfig(runConfig{
		Task:        "review this project",
		Workflow:    workflowAgentic,
		Provider:    providerOpenRouter,
		APIKey:      "test-key",
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.60",
		HTTPTimeout: defaultHTTPTimeoutMS,
		RouterMode:  "llm",
	})

	if err != nil {
		t.Fatalf("expected valid llm router config, got %v", err)
	}
}

func TestValidateConfigRejectsInvalidLocalRouterConfig(t *testing.T) {
	err := validateConfig(runConfig{
		Task:             "review this project",
		Workflow:         workflowAgentic,
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
		Workflow:         workflowAgentic,
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
		Workflow:         workflowAgentic,
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

func TestValidateConfigRejectsLocalSettingsForLLMRouter(t *testing.T) {
	err := validateConfig(runConfig{
		Task:           "review this project",
		Workflow:       workflowAgentic,
		Provider:       providerEcho,
		RouterMode:     "llm",
		RouterModelDir: "/tmp/agent-machine-router-model",
	})

	if err == nil || !strings.Contains(err.Error(), "llm router does not accept local router settings") {
		t.Fatalf("expected llm router local settings error, got %v", err)
	}
}

func TestValidateConfigRequiresToolRootForLocalFiles(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "write a file",
		Workflow:      workflowAgentic,
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
		Workflow:    workflowAgentic,
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
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   defaultFilesystemToolTimeout,
		ToolMaxRounds: defaultFilesystemToolMaxRounds,
		ToolApproval:  "full-access",
	})

	if err != nil {
		t.Fatalf("expected valid code-edit config, got %v", err)
	}
}

func TestValidateRunnableConfigAllowsCodeEditBudgetUntilRuntimeStrategyIsKnown(t *testing.T) {
	err := validateRunnableConfig(runConfig{
		Task:          "edit code",
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/Users/pawel/priv/java",
		ToolTimeout:   "1000",
		ToolMaxRounds: "6",
		ToolApproval:  "full-access",
	})

	if err != nil {
		t.Fatalf("expected TUI to defer shell budget validation to runtime strategy selection, got %v", err)
	}
}

func TestStartRunAllowsDirectPromptWithLegacyCodeEditShellBudget(t *testing.T) {
	m := model{
		provider:    providerEcho,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "code-edit",
			ToolRoot:      "/Users/pawel/priv/java",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "full-access",
		},
	}

	updated, cmd := m.startRun("hi")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command because direct prompts should not be blocked by stale code-edit shell budget")
	}
	if !result.running {
		t.Fatal("expected run to start")
	}
	if result.messages[len(result.messages)-2].Role != "user" ||
		result.messages[len(result.messages)-2].Text != "hi" {
		t.Fatalf("expected user message before run, got %#v", result.messages)
	}
}

func TestStartRunDefersCommandCapableCodeEditBudgetToRuntime(t *testing.T) {
	m := model{
		provider:    providerEcho,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "code-edit",
			ToolRoot:      "/Users/pawel/priv/java",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "full-access",
		},
	}

	updated, cmd := m.startRun("in dir /Users/pawel/priv/java create me bootstrap project")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command so runtime can select strategy before validating shell budget")
	}
	if !result.running {
		t.Fatal("expected run to start")
	}
}

func TestValidateConfigAllowsSafeCodeEditWithSmallToolBudget(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "edit code",
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/tmp/agent-machine-project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "6",
		ToolApproval:  "auto-approved-safe",
	})

	if err != nil {
		t.Fatalf("expected safe code-edit config without shell access, got %v", err)
	}
}

func TestValidateConfigRejectsTaskPathOutsideToolRoot(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "setup me /Users/pawel/priv/java bootstrap project",
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/Users/pawel/priv/elixir",
		ToolTimeout:   "1000",
		ToolMaxRounds: "6",
		ToolApproval:  "full-access",
	})

	if err == nil {
		t.Fatal("expected task path outside tool root error")
	}
	for _, expected := range []string{
		"tool root /Users/pawel/priv/elixir does not cover requested path /Users/pawel/priv/java",
		"/tools code-edit /Users/pawel/priv/java 1000 6 full-access",
	} {
		if !strings.Contains(err.Error(), expected) {
			t.Fatalf("expected error to contain %q, got %v", expected, err)
		}
	}
}

func TestValidateConfigAcceptsTaskPathInsideToolRoot(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "setup me /Users/pawel/priv/java bootstrap project",
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/Users/pawel/priv",
		ToolTimeout:   "1000",
		ToolMaxRounds: "6",
		ToolApproval:  "full-access",
	})

	if err != nil {
		t.Fatalf("expected valid config, got %v", err)
	}
}

func TestValidateConfigIgnoresSlashCommandsAsTaskPaths(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "explain the /setup command",
		Workflow:      workflowAgentic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/Users/pawel/priv/elixir",
		ToolTimeout:   "1000",
		ToolMaxRounds: "6",
		ToolApproval:  "full-access",
	})

	if err != nil {
		t.Fatalf("expected slash command text to be ignored as a path, got %v", err)
	}
}

func TestValidateConfigAcceptsTimeHarness(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "what time is it?",
		Workflow:      workflowAgentic,
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
		Workflow:      workflowAgentic,
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
		Workflow:      workflowAgentic,
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

func TestAgentDetailCompactsAssistantDeltaEvents(t *testing.T) {
	lines := agentEventLines([]eventSummary{
		{Type: "assistant_delta", AgentID: "planner", Summary: "planner streamed text"},
		{Type: "assistant_delta", AgentID: "planner", Summary: "planner streamed text"},
		{Type: "assistant_delta", AgentID: "planner", Summary: "planner streamed text"},
		{Type: "assistant_done", AgentID: "planner", Summary: "planner finished streaming text"},
	})

	if strings.Count(lines, "planner streamed text") != 1 || !strings.Contains(lines, "x3") {
		t.Fatalf("expected compact stream event line, got %q", lines)
	}
	if !strings.Contains(lines, "planner finished streaming text") {
		t.Fatalf("expected stream completion event, got %q", lines)
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
		"(provider request in progress; no streamed text yet)",
		"(none so far)",
	} {
		if !strings.Contains(view, expected) {
			t.Fatalf("expected %q in detail view, got %q", expected, view)
		}
	}
}

func TestAgentDetailShowsStreamAndFinalOutput(t *testing.T) {
	m := model{
		selectedAgent: "planner",
		agents: map[string]agentState{
			"planner": {
				ID:           "planner",
				Status:       "ok",
				Attempt:      1,
				StreamOutput: "{\"decision\":{\"mode\":\"delegate\"},\"output\":\"draft plan\"}",
				Output:       "draft plan",
				Decision: plannerDecision{
					Mode:              "delegate",
					Reason:            "Need one worker for the filesystem change.",
					DelegatedAgentIDs: []string{"create-experiments-folder"},
				},
			},
		},
	}

	view := m.agentDetailView()
	for _, expected := range []string{
		"Stream",
		"{\"decision\":{\"mode\":\"delegate\"},\"output\":\"draft plan\"}",
		"Output",
		"draft plan",
		"reason: Need one worker for the filesystem change.",
		"delegated: create-experiments-folder",
	} {
		if !strings.Contains(view, expected) {
			t.Fatalf("expected %q in detail view, got %q", expected, view)
		}
	}
}

func TestAgentDetailRendersFinalOutputMarkdown(t *testing.T) {
	m := model{
		width:         80,
		selectedAgent: "finalizer",
		agents: map[string]agentState{
			"finalizer": {
				ID:      "finalizer",
				Status:  "ok",
				Attempt: 1,
				Output:  "### Summary\n\n**done**",
			},
		},
	}

	view := m.agentDetailView()

	if strings.Contains(view, "### Summary") || strings.Contains(view, "**done**") {
		t.Fatalf("expected final output markdown to be rendered, got %q", view)
	}
	if !strings.Contains(stripANSI(view), "Summary") || !strings.Contains(stripANSI(view), "done") {
		t.Fatalf("expected final output markdown content to remain visible, got %q", view)
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

func TestEventDisplayLineShowsApprovedPermission(t *testing.T) {
	line := eventDisplayLine(eventSummary{
		Type:          "permission_decided",
		AgentID:       "worker",
		RequestID:     "req-1",
		Kind:          "tool_execution",
		Decision:      "approved",
		Tool:          "write_file",
		ApprovalRisk:  "write",
		ApprovalMode:  "ask_before_write",
		RequestedRoot: "/tmp/project",
		Reason:        "TUI approve",
	})

	for _, expected := range []string{
		"permission approved: worker may run write_file",
		"root=/tmp/project",
		"risk=write",
		"mode=ask_before_write",
		"reason=TUI approve",
	} {
		if !strings.Contains(line, expected) {
			t.Fatalf("expected %q in permission event line, got %q", expected, line)
		}
	}
}

func TestChatViewRendersThinkingAnimationWithoutStreamedText(t *testing.T) {
	m := model{
		running:       true,
		streamFrame:   1,
		theme:         themeClassic,
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

func TestChatViewRendersMatrixWorkSignalWithoutStreamedText(t *testing.T) {
	m := model{
		running:       true,
		streamFrame:   matrixSignalFrameHold,
		theme:         themeMatrix,
		liveAssistant: "hidden streamed content",
		messages:      []chatMessage{{Role: "user", Text: "hello"}},
		eventLog: []eventSummary{
			{Type: "provider_request_started", Summary: "assistant sent provider request"},
		},
	}

	view := stripANSI(m.chatView())

	if strings.Contains(view, "thinking") {
		t.Fatalf("expected matrix work signal instead of thinking text, got %q", view)
	}
	if !strings.Contains(view, "construct loading") {
		t.Fatalf("expected matrix work signal, got %q", view)
	}
	if strings.Contains(view, "hidden streamed content") {
		t.Fatalf("expected streamed text to stay hidden, got %q", view)
	}
}

func TestProgressCommentaryRendersOutsideConversationMessages(t *testing.T) {
	m := model{running: true, eventAutoScroll: true}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"progress_commentary","run_id":"run-1","source":"observer","commentary":"The repo already has a broad skill surface, so I am narrowing the UI gap.","summary":"The repo already has a broad skill surface, so I am narrowing the UI gap.","evidence_count":3,"agent_ids":["worker"],"tool_call_ids":["call-1"],"at":"2026-04-25T10:00:00Z"}}`)

	if len(updated.messages) != 0 {
		t.Fatalf("expected progress commentary to stay out of conversation messages, got %#v", updated.messages)
	}
	if len(updated.progressComments) != 1 {
		t.Fatalf("expected progress commentary state, got %#v", updated.progressComments)
	}

	view := updated.chatView()
	if !strings.Contains(view, "Observer progress") || !strings.Contains(view, "broad skill surface") {
		t.Fatalf("expected progress commentary in chat view, got %q", view)
	}
	if strings.Contains(updated.taskWithConversationContext("next request"), "broad skill surface") {
		t.Fatalf("expected progress commentary to stay out of next LLM task context")
	}
	if compacted := compactableConversationMessages(updated.messages); len(compacted) != 0 {
		t.Fatalf("expected progress commentary to stay out of compactable messages, got %#v", compacted)
	}
}

func TestProgressObserverCommandPersistsConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{configPath: configPath, view: viewChat}

	updated, _ := m.handleCommand("/progress observer on")
	result := updated.(model)

	if !result.savedConfig.ProgressObserver {
		t.Fatalf("expected progress observer enabled, got %#v", result.savedConfig)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "progress observer: on") {
		t.Fatalf("expected progress status message, got %#v", result.messages)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config: %v", err)
	}
	if !loaded.ProgressObserver {
		t.Fatalf("expected persisted progress observer, got %#v", loaded)
	}

	updated, _ = result.handleCommand("/progress observer off")
	result = updated.(model)
	if result.savedConfig.ProgressObserver {
		t.Fatalf("expected progress observer disabled, got %#v", result.savedConfig)
	}
}

func TestMatrixWorkSignalChangesMoreSlowlyThanStreamFrame(t *testing.T) {
	first := matrixWorkSignal(0)
	lastHeldFrame := matrixWorkSignal(matrixSignalFrameHold - 1)
	next := matrixWorkSignal(matrixSignalFrameHold)

	if first != lastHeldFrame {
		t.Fatalf("expected matrix signal to hold for %d frames, got %q then %q", matrixSignalFrameHold, first, lastHeldFrame)
	}
	if first == next {
		t.Fatalf("expected matrix signal to advance after hold, still got %q", first)
	}
}

func TestMatrixGradientTextAnimatesWithoutChangingPlainText(t *testing.T) {
	first := matrixGradientText("construct loading", 0)
	next := matrixGradientText("construct loading", 1)

	if matrixGradientColor(0, 0) == matrixGradientColor(0, 1) {
		t.Fatalf("expected gradient color to advance between frames")
	}
	if stripANSI(first) != "construct loading" || stripANSI(next) != "construct loading" {
		t.Fatalf("expected gradient to preserve plain text, got %q and %q", first, next)
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

func TestChatViewRendersAssistantMarkdown(t *testing.T) {
	m := model{
		width: 80,
		messages: []chatMessage{
			{Role: "assistant", Text: "**hello**"},
		},
	}

	view := m.chatView()

	if strings.Contains(view, "**hello**") {
		t.Fatalf("expected assistant markdown markers to be rendered, got %q", view)
	}
	if !strings.Contains(stripANSI(view), "assistant: hello") {
		t.Fatalf("expected assistant markdown text to remain visible, got %q", view)
	}
}

func TestMarkdownRendererStylesBoldText(t *testing.T) {
	rendered, err := renderMarkdownText("**hello**", 80)
	if err != nil {
		t.Fatalf("expected markdown renderer to succeed: %v", err)
	}

	if !strings.Contains(rendered, "\x1b[") {
		t.Fatalf("expected markdown renderer to include ANSI styling, got %q", rendered)
	}
	if strings.TrimSpace(stripANSI(rendered)) != "hello" {
		t.Fatalf("expected rendered markdown text, got %q", rendered)
	}
}

func TestMarkdownRendererStylesHeaders(t *testing.T) {
	rendered, err := renderMarkdownText("## Result", 80)
	if err != nil {
		t.Fatalf("expected markdown renderer to succeed: %v", err)
	}

	if strings.Contains(rendered, "## Result") {
		t.Fatalf("expected markdown header marker to be rendered, got %q", rendered)
	}
	if !strings.Contains(rendered, "\x1b[") {
		t.Fatalf("expected markdown header to include ANSI styling, got %q", rendered)
	}
	if strings.TrimSpace(stripANSI(rendered)) != "Result" {
		t.Fatalf("expected rendered header text, got %q", rendered)
	}
}

func TestMatrixMarkdownRendererStylesCodeBlocks(t *testing.T) {
	rendered, err := renderMarkdownTextWithTheme("```go\n// hi\nfmt.Println(42)\n```", 80, themeMatrix)
	if err != nil {
		t.Fatalf("expected matrix markdown renderer to succeed: %v", err)
	}

	if !strings.Contains(rendered, "\x1b[") {
		t.Fatalf("expected matrix code block to include ANSI styling, got %q", rendered)
	}
	if !strings.Contains(stripANSI(rendered), "fmt.Println") {
		t.Fatalf("expected rendered code text, got %q", rendered)
	}
}

func TestChatViewRendersAssistantMarkdownHeaders(t *testing.T) {
	m := model{
		width: 80,
		messages: []chatMessage{
			{Role: "assistant", Text: "## Result\n\nAll done."},
		},
	}

	view := m.chatView()

	if strings.Contains(view, "## Result") {
		t.Fatalf("expected assistant markdown header marker to be rendered, got %q", view)
	}
	if !strings.Contains(stripANSI(view), "Result") || !strings.Contains(stripANSI(view), "All done.") {
		t.Fatalf("expected assistant markdown content to remain visible, got %q", view)
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
			ExecutionStrategy: workflowRoute{
				Requested:    "agentic",
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
	if !strings.Contains(view, "Execution strategy: runtime=agentic strategy=tool intent=time tools=true") {
		t.Fatalf("expected execution strategy in agents view, got %q", view)
	}
	if !strings.Contains(m.statusLine(), "strategy=tool") {
		t.Fatalf("expected execution strategy in status line, got %q", m.statusLine())
	}
}

func TestAgentsViewRendersWorkChecklistToolRows(t *testing.T) {
	m := model{
		agents: map[string]agentState{
			"planner": {ID: "planner", Status: "ok"},
			"worker":  {ID: "worker", ParentAgentID: "planner", Status: "running"},
		},
		agentOrder: []string{"planner", "worker"},
		workItems: map[string]workItem{
			"agent:planner": {
				ID:            "agent:planner",
				Kind:          "agent",
				Label:         "planner",
				Status:        "done",
				LatestSummary: "planner finished",
			},
			"agent:worker": {
				ID:            "agent:worker",
				Kind:          "agent",
				Label:         "worker",
				ParentID:      "agent:planner",
				Status:        "running",
				LatestSummary: "worker started attempt 1",
			},
			"tool:worker:call-1": {
				ID:            "tool:worker:call-1",
				Kind:          "tool",
				Label:         "worker read README.md",
				ParentID:      "agent:worker",
				Status:        "done",
				LatestSummary: "worker read README.md",
			},
		},
		workOrder: []string{"agent:planner", "agent:worker", "tool:worker:call-1"},
		eventLog: []eventSummary{
			{Type: "tool_call_finished", AgentID: "worker", Summary: "worker read README.md"},
		},
	}

	view := m.agentsView()
	if !strings.Contains(view, "Latest event") {
		t.Fatalf("expected latest event label in agents view, got %q", view)
	}
	if !strings.Contains(view, "Work") || !strings.Contains(view, "worker read README.md") {
		t.Fatalf("expected work checklist rows in agents view, got %q", view)
	}
}

func TestResolveConfigRequiresExplicitRemotePricing(t *testing.T) {
	_, err := resolveConfig(runConfig{
		Task:     "review this project",
		Workflow: workflowAgentic,
		Provider: providerOpenAI,
		APIKey:   "test-key",
		Model:    "gpt-4o-mini",
	})

	if err == nil {
		t.Fatal("expected missing pricing to fail")
	}
	if !strings.Contains(err.Error(), "pricing is missing") {
		t.Fatalf("expected pricing error, got %v", err)
	}
}

func TestStartRunLoadsModelMetadataWhenSavedModelPricingIsMissing(t *testing.T) {
	originalLookup := providerModelLookup
	providerModelLookup = func(config runConfig) ([]modelOption, error) {
		if config.Provider != providerOpenRouter {
			t.Fatalf("unexpected provider lookup config: %#v", config)
		}
		return []modelOption{
			{
				ID: "stepfun/step-3.5-flash",
				Pricing: modelPricing{
					InputPerMillion:  0.04,
					OutputPerMillion: 0.16,
				},
			},
		}, nil
	}
	defer func() { providerModelLookup = originalLookup }()

	m := model{
		provider:      providerOpenRouter,
		providerSet:   true,
		selectedModel: "stepfun/step-3.5-flash",
		configPath:    filepath.Join(t.TempDir(), "config.json"),
		savedConfig: savedConfig{
			ProviderSecrets: map[string]map[string]string{
				string(providerOpenRouter): {"api_key": "test-key"},
			},
			ProviderModels: map[string]string{
				string(providerOpenRouter): "stepfun/step-3.5-flash",
			},
		},
	}

	updated, cmd := m.startRun("hi")
	result := updated.(model)
	if cmd == nil {
		t.Fatal("expected model metadata load command")
	}
	if result.running {
		t.Fatal("expected run to wait for model metadata")
	}
	if result.pendingRunAfterModelLoad != "hi" {
		t.Fatalf("expected pending run after model load, got %q", result.pendingRunAfterModelLoad)
	}

	msg := cmd()
	updated, cmd = result.Update(msg)
	result = updated.(model)
	if cmd == nil {
		t.Fatal("expected pending run to start after model metadata load")
	}
	if !result.running {
		t.Fatal("expected pending run to start")
	}
	if result.activeConfig.InputPrice != "0.04" || result.activeConfig.OutputPrice != "0.16" {
		t.Fatalf("expected loaded pricing in active config, got %#v", result.activeConfig)
	}
}

func TestResolveConfigAcceptsExplicitRemotePricingAndTimeout(t *testing.T) {
	resolved, err := resolveConfig(runConfig{
		Task:        "review this project",
		Workflow:    workflowAgentic,
		Provider:    providerOpenRouter,
		APIKey:      "test-key",
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.6",
		HTTPTimeout: defaultHTTPTimeoutMS,
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

func TestModelListMessagePersistsSelectedModelMetadata(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		provider:      providerOpenRouter,
		providerSet:   true,
		configPath:    configPath,
		selectedModel: "stepfun/step-3.5-flash",
		savedConfig: savedConfig{
			Provider: string(providerOpenRouter),
			ProviderSecrets: map[string]map[string]string{
				string(providerOpenRouter): {"api_key": "test-key"},
			},
			ProviderModels: map[string]string{
				string(providerOpenRouter): "stepfun/step-3.5-flash",
			},
		},
	}

	updated, _ := m.Update(modelListMsg{
		Provider: providerOpenRouter,
		Models: []modelOption{
			{
				ID: "stepfun/step-3.5-flash",
				Pricing: modelPricing{
					InputPerMillion:  0.04,
					OutputPerMillion: 0.16,
				},
				ContextWindowTokens: 262144,
			},
		},
	})
	result := updated.(model)

	if result.selectedModel != "stepfun/step-3.5-flash" {
		t.Fatalf("unexpected selected model: %q", result.selectedModel)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config, got %v", err)
	}
	metadata, ok := loaded.modelMetadataFor(providerOpenRouter, "stepfun/step-3.5-flash")
	if !ok {
		t.Fatalf("expected model metadata to persist, got %#v", loaded.ProviderModelMetadata)
	}
	if metadata.Pricing.InputPerMillion != 0.04 || metadata.Pricing.OutputPerMillion != 0.16 {
		t.Fatalf("unexpected persisted pricing: %#v", metadata.Pricing)
	}
	if metadata.ContextWindowTokens != 262144 {
		t.Fatalf("unexpected context window: %d", metadata.ContextWindowTokens)
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

	if config.Workflow != workflowAgentic {
		t.Fatalf("expected agentic runtime request, got %q", config.Workflow)
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

func TestConfigUsesSavedModelPricingMetadataWithoutReload(t *testing.T) {
	m := model{
		provider:      providerOpenRouter,
		providerSet:   true,
		selectedModel: "stepfun/step-3.5-flash",
		savedConfig: savedConfig{
			ProviderSecrets: map[string]map[string]string{
				string(providerOpenRouter): {"api_key": "test-key"},
			},
			ProviderModelMetadata: map[string]map[string]modelOption{
				string(providerOpenRouter): {
					"stepfun/step-3.5-flash": {
						ID: "stepfun/step-3.5-flash",
						Pricing: modelPricing{
							InputPerMillion:  0.04,
							OutputPerMillion: 0.16,
						},
						ContextWindowTokens: 262144,
					},
				},
			},
		},
	}

	config := m.runConfig("review this project")
	resolved, err := resolveConfig(config)
	if err != nil {
		t.Fatalf("expected saved model metadata to resolve pricing, got %v", err)
	}
	if resolved.InputPrice != "0.04" || resolved.OutputPrice != "0.16" {
		t.Fatalf("unexpected pricing: input=%q output=%q", resolved.InputPrice, resolved.OutputPrice)
	}
	if resolved.ContextWindow != "262144" {
		t.Fatalf("unexpected context window: %q", resolved.ContextWindow)
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

func TestProviderModelOptionsKeepOnlyCatalogModelsWithPricing(t *testing.T) {
	contextWindow := 128000
	options := providerModelOptions([]providerModelPayload{
		{ID: "missing-pricing"},
		{
			ID:                  "openai/gpt-4o-mini",
			Pricing:             &providerPricingPayload{InputPerMillion: 0.15, OutputPerMillion: 0.60},
			ContextWindowTokens: &contextWindow,
		},
	})

	if len(options) != 1 {
		t.Fatalf("expected one priced option, got %#v", options)
	}

	if options[0].ID != "openai/gpt-4o-mini" {
		t.Fatalf("unexpected model id: %q", options[0].ID)
	}

	if options[0].Pricing.InputPerMillion != 0.15 {
		t.Fatalf("unexpected pricing: %#v", options[0].Pricing)
	}
	if options[0].ContextWindowTokens != contextWindow {
		t.Fatalf("unexpected context window: %d", options[0].ContextWindowTokens)
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

func TestProviderCommandOpensProviderPickerWithCurrentProvider(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
	}

	updated, cmd := m.handleCommand("/provider")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no command when opening provider picker")
	}
	if !result.providerPickerOpen {
		t.Fatal("expected provider picker to open")
	}
	if result.providerPickerIndex != providerListIndex(providerOpenRouter) {
		t.Fatalf("expected picker index to follow current provider, got %d", result.providerPickerIndex)
	}

	view := stripANSI(result.providerPickerView())
	if !strings.Contains(view, "Current: OpenRouter (openrouter)") {
		t.Fatalf("expected current provider in picker, got %q", view)
	}
	if !strings.Contains(view, "[*] openrouter") {
		t.Fatalf("expected selected provider marker in picker, got %q", view)
	}
	if !strings.Contains(view, "openai") || !strings.Contains(view, "anthropic") || !strings.Contains(view, "vllm") {
		t.Fatalf("expected picker to list providers, got %q", view)
	}
}

func TestProviderPickerSelectsProviderWithArrowAndEnter(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		configPath:  configPath,
		provider:    providerEcho,
		providerSet: true,
		savedConfig: savedConfig{
			Provider: string(providerEcho),
		},
		providerPickerOpen:  true,
		providerPickerIndex: providerListIndex(providerEcho),
		selectedModel:       "echo",
		modelOptions:        []modelOption{{ID: "echo"}},
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	updated, cmd := updated.(model).Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)

	if result.providerPickerOpen {
		t.Fatal("expected provider picker to close")
	}
	if result.provider != "alibaba" {
		t.Fatalf("expected selected provider to be alibaba, got %q", result.provider)
	}
	if result.selectedModel != "" {
		t.Fatalf("expected selected model reset, got %q", result.selectedModel)
	}
	if cmd == nil {
		t.Fatal("expected model loading command after choosing remote provider")
	}
}

func TestProviderPickerSelectingCurrentProviderKeepsModel(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		configPath:  configPath,
		provider:    providerOpenRouter,
		providerSet: true,
		savedConfig: savedConfig{
			Provider:       string(providerOpenRouter),
			ProviderModels: map[string]string{string(providerOpenRouter): "openai/gpt-4o-mini"},
		},
		providerPickerOpen:  true,
		providerPickerIndex: providerListIndex(providerOpenRouter),
		selectedModel:       "openai/gpt-4o-mini",
		modelOptions:        []modelOption{{ID: "openai/gpt-4o-mini"}},
		modelIndex:          0,
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)

	if result.providerPickerOpen {
		t.Fatal("expected provider picker to close")
	}
	if result.provider != providerOpenRouter {
		t.Fatalf("expected provider to remain openrouter, got %q", result.provider)
	}
	if result.selectedModel != "openai/gpt-4o-mini" {
		t.Fatalf("expected current provider selection to keep model, got %q", result.selectedModel)
	}
	if cmd != nil {
		t.Fatal("expected no model reload command when selecting current provider")
	}
}

func TestRunConfigUsesAgenticWorkflowWhenPlannerReviewEnabled(t *testing.T) {
	m := model{
		provider:    providerEcho,
		providerSet: true,
		savedConfig: savedConfig{
			Provider:                  string(providerEcho),
			PlannerReviewMaxRevisions: "2",
		},
	}

	config := m.runConfig("simple prompt")

	if config.Workflow != workflowAgentic {
		t.Fatalf("expected planner review to use agentic runtime, got %q", config.Workflow)
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

func TestStartRunUsesAgenticRuntimeWithoutWorkflowSetup(t *testing.T) {
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
	if result.activeConfig.Workflow != workflowAgentic {
		t.Fatalf("expected agentic runtime request, got %q", result.activeConfig.Workflow)
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
	if result.activeConfig.Workflow != workflowAgentic {
		t.Fatalf("expected agentic runtime, got %q", result.activeConfig.Workflow)
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
	if !strings.Contains(help, "/theme classic|matrix") {
		t.Fatalf("expected help to mention theme command, got %q", help)
	}
	if !strings.Contains(help, "/skills list|show <name>|install <name>|generate <name> <description>|off") {
		t.Fatalf("expected help to mention skill generation command, got %q", help)
	}
	if !strings.Contains(help, "read-only tool") {
		t.Fatalf("expected help to mention read-only tool route, got %q", help)
	}

	status := m.statusLine()
	if strings.Contains(status, "workflow=") {
		t.Fatalf("expected status to omit workflow, got %q", status)
	}
}

func TestWorkflowCommandReportsRemovedWorkflowSelection(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/workflow agentic")
	result := updated.(model)

	if !strings.Contains(result.messages[len(result.messages)-1].Text, "Workflow selection was removed") {
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

	data, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("expected saved config to be readable or absent, got %v", err)
	}
	if strings.Contains(string(data), `"workflow"`) {
		t.Fatalf("expected workflow not to persist, got %s", string(data))
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

func TestRouterCommandPersistsLLMAndDeterministicRouters(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/router llm")
	result := updated.(model)
	if result.savedConfig.RouterMode != "llm" || result.savedConfig.RouterModelDir != "" {
		t.Fatalf("expected llm router config, got %#v", result.savedConfig)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "router: llm current model") {
		t.Fatalf("expected llm router status, got %#v", result.messages[len(result.messages)-1])
	}

	updated, _ = result.handleCommand("/router deterministic")
	result = updated.(model)
	if result.savedConfig.RouterMode != "deterministic" || result.savedConfig.RouterModelDir != "" {
		t.Fatalf("expected deterministic router config, got %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.RouterMode != "deterministic" {
		t.Fatalf("expected deterministic router to persist, got %#v", loaded)
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

func TestToolsCommandResolvesRelativeRootFromLaunchDirectory(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	workspace := filepath.Join(t.TempDir(), "workspace")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatalf("failed to create workspace: %v", err)
	}

	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	t.Chdir(workspace)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools local-files . 1000 2 auto-approved-safe")
	result := updated.(model)

	if result.savedConfig.ToolRoot != workspace {
		t.Fatalf("expected relative root to resolve to launch directory, got %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolRoot != workspace {
		t.Fatalf("expected saved root %q, got %q", workspace, loaded.ToolRoot)
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

func TestAgenticPersistenceCommandPersistsExplicitValues(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	modelAfter, _ := m.handleCommand("/agentic-persistence 2 9 300000")
	result := modelAfter.(model)

	if result.savedConfig.AgenticPersistenceRounds != "2" ||
		result.savedConfig.AgenticPersistenceMaxSteps != "9" ||
		result.savedConfig.AgenticPersistenceTimeout != "300000" {
		t.Fatalf("expected agentic persistence values, got %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.AgenticPersistenceRounds != "2" ||
		loaded.AgenticPersistenceMaxSteps != "9" ||
		loaded.AgenticPersistenceTimeout != "300000" {
		t.Fatalf("expected persisted agentic persistence values, got %#v", loaded)
	}
}

func TestAgenticPersistenceCommandClearsAllFields(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		configPath: configPath,
		savedConfig: savedConfig{
			AgenticPersistenceRounds:   "2",
			AgenticPersistenceMaxSteps: "9",
			AgenticPersistenceTimeout:  "300000",
		},
	}

	modelAfter, _ := m.handleCommand("/agentic-persistence off")
	result := modelAfter.(model)

	if result.savedConfig.AgenticPersistenceRounds != "" ||
		result.savedConfig.AgenticPersistenceMaxSteps != "" ||
		result.savedConfig.AgenticPersistenceTimeout != "" {
		t.Fatalf("expected cleared persistence config, got %#v", result.savedConfig)
	}
}

func TestAgenticPersistenceCommandRejectsInvalidValues(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{configPath: configPath}

	modelAfter, _ := m.handleCommand("/agentic-persistence 0 9 300000")
	result := modelAfter.(model)

	if result.savedConfig.AgenticPersistenceRounds != "" {
		t.Fatalf("expected invalid persistence config not to save, got %#v", result.savedConfig)
	}
	if len(result.messages) == 0 ||
		!strings.Contains(result.messages[len(result.messages)-1].Text, "positive integer") {
		t.Fatalf("expected validation message, got %#v", result.messages)
	}
}

func TestPlannerReviewCommandPersistsExplicitLimit(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	modelAfter, _ := m.handleCommand("/planner-review on 2")
	result := modelAfter.(model)

	if result.savedConfig.PlannerReviewMaxRevisions != "2" {
		t.Fatalf("expected planner review value, got %#v", result.savedConfig)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.PlannerReviewMaxRevisions != "2" {
		t.Fatalf("expected persisted planner review value, got %#v", loaded)
	}
}

func TestPlannerReviewCommandClearsLimit(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		configPath: configPath,
		savedConfig: savedConfig{
			PlannerReviewMaxRevisions: "2",
		},
	}

	modelAfter, _ := m.handleCommand("/planner-review off")
	result := modelAfter.(model)

	if result.savedConfig.PlannerReviewMaxRevisions != "" {
		t.Fatalf("expected cleared planner review config, got %#v", result.savedConfig)
	}
}

func TestPlannerReviewCommandRejectsInvalidLimit(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{configPath: configPath}

	modelAfter, _ := m.handleCommand("/planner-review on 0")
	result := modelAfter.(model)

	if result.savedConfig.PlannerReviewMaxRevisions != "" {
		t.Fatalf("expected invalid planner review config not to save, got %#v", result.savedConfig)
	}
	if len(result.messages) == 0 ||
		!strings.Contains(result.messages[len(result.messages)-1].Text, "positive integer") {
		t.Fatalf("expected validation message, got %#v", result.messages)
	}
}

func TestMCPConfigCommandRejectsInheritedToolBudget(t *testing.T) {
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

	modelAfter, _ := m.handleCommand("/mcp-config /tmp/agent-machine.mcp.json")
	result := modelAfter.(model)

	if result.savedConfig.MCPConfig != "" {
		t.Fatalf("expected MCP config not to inherit existing tool budget, got %#v", result.savedConfig)
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
	if result.savedConfig.ToolTimeout != "120000" || result.savedConfig.ToolMaxRounds != "6" || result.savedConfig.ToolApproval != "ask-before-write" {
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
		`"inputSchema"`,
		`"required": [`,
		`"url"`,
		`"risk": "network"`,
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("expected generated MCP config to contain %q, got %s", expected, text)
		}
	}
}

func TestInitialModelMigratesManagedPlaywrightMCPConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	managedPath := managedMCPConfigPath(configPath)

	if err := os.MkdirAll(filepath.Dir(managedPath), 0o700); err != nil {
		t.Fatal(err)
	}
	oldConfig := `{
  "servers": [
    {
      "id": "playwright",
      "transport": "stdio",
      "command": "npx",
      "args": ["--yes", "@playwright/mcp@latest", "--headless"],
      "env": {},
      "tools": [
        {
          "name": "browser_navigate",
          "permission": "mcp_playwright_browser_navigate",
          "risk": "network"
        },
        {
          "name": "browser_snapshot",
          "permission": "mcp_playwright_browser_snapshot",
          "risk": "read"
        }
      ]
    }
  ]
}
`
	if err := os.WriteFile(managedPath, []byte(oldConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := saveSavedConfig(configPath, savedConfig{
		MCPConfig:     managedPath,
		ToolTimeout:   defaultMCPToolTimeout,
		ToolMaxRounds: defaultMCPToolMaxRounds,
		ToolApproval:  defaultMCPToolApproval,
	}); err != nil {
		t.Fatal(err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}
	if m.savedConfig.MCPConfig != managedPath {
		t.Fatalf("expected managed MCP config, got %#v", m.savedConfig)
	}

	data, err := os.ReadFile(managedPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, expected := range []string{
		`"inputSchema"`,
		`"required": [`,
		`"url"`,
		`"browser_snapshot"`,
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("expected migrated MCP config to contain %q, got %s", expected, text)
		}
	}
}

func TestManagedMCPMigrationLeavesStandaloneConfigAlone(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	standalonePath := filepath.Join(t.TempDir(), "standalone.mcp.json")
	config := savedConfig{MCPConfig: standalonePath}

	if err := migrateManagedMCPConfig(configPath, &config); err != nil {
		t.Fatalf("expected standalone config to be ignored, got %v", err)
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

func TestSkillsListMessageOpensSkillPicker(t *testing.T) {
	m := model{savedConfig: savedConfig{SkillsDir: "/tmp/agent-machine-skills"}}

	updated, _ := m.Update(skillsCommandMsg{
		Action: "list",
		Output: `{"skills":[{"name":"docs-helper","description":"Helps write concise docs","root":"/tmp/agent-machine-skills/docs-helper"},{"name":"review-helper","description":"Reviews implementation notes","root":"/tmp/agent-machine-skills/review-helper"}]}`,
	})
	result := updated.(model)

	if !result.skillPickerOpen {
		t.Fatal("expected skill picker to open")
	}
	if len(result.skillOptions) != 2 || result.skillOptions[0].Name != "docs-helper" {
		t.Fatalf("expected parsed skill options, got %#v", result.skillOptions)
	}
	view := stripANSI(result.View())
	if !strings.Contains(view, "Installed skills") || !strings.Contains(view, "docs-helper") {
		t.Fatalf("expected skill picker view, got %q", view)
	}
}

func TestSkillPickerSelectsExplicitSkill(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	if err := saveSavedConfig(configPath, savedConfig{SkillsDir: "/tmp/agent-machine-skills"}); err != nil {
		t.Fatalf("expected config write, got %v", err)
	}

	m := model{
		configPath: configPath,
		savedConfig: savedConfig{
			SkillsMode: "auto",
			SkillsDir:  "/tmp/agent-machine-skills",
		},
		skillOptions: []skillCatalogEntry{
			{Name: "docs-helper", Description: "Helps write concise docs"},
			{Name: "review-helper", Description: "Reviews implementation notes"},
		},
		skillPickerOpen:  true,
		skillPickerIndex: 0,
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)

	if result.skillPickerOpen {
		t.Fatal("expected skill picker to close after selection")
	}
	if result.savedConfig.SkillsMode != "" {
		t.Fatalf("expected explicit selection to clear auto mode, got %#v", result.savedConfig)
	}
	if len(result.savedConfig.SkillNames) != 1 || result.savedConfig.SkillNames[0] != "docs-helper" {
		t.Fatalf("expected docs-helper to be selected, got %#v", result.savedConfig.SkillNames)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.SkillNames) != 1 || loaded.SkillNames[0] != "docs-helper" {
		t.Fatalf("expected selected skill to persist, got %#v", loaded)
	}
}

func TestSkillPickerFiltersSkillsWhileTyping(t *testing.T) {
	m := model{
		savedConfig: savedConfig{SkillsDir: "/tmp/agent-machine-skills"},
		skillOptions: []skillCatalogEntry{
			{Name: "docs-helper", Description: "Helps write concise docs"},
			{Name: "review-helper", Description: "Reviews implementation notes"},
		},
		skillPickerOpen:  true,
		skillPickerIndex: 0,
	}

	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("review")})
	result := updated.(model)

	if result.skillPickerQuery != "review" {
		t.Fatalf("expected skill query to be review, got %q", result.skillPickerQuery)
	}
	if result.skillPickerIndex != 1 {
		t.Fatalf("expected review-helper to be selected by filter, got %d", result.skillPickerIndex)
	}
}

func TestSkillsGenerateCommandRequiresSkillsDir(t *testing.T) {
	m := model{provider: providerEcho, providerSet: true}

	updated, _ := m.handleCommand("/skills generate docs-helper Helps write concise docs")
	result := updated.(model)

	if len(result.messages) == 0 ||
		!strings.Contains(result.messages[len(result.messages)-1].Text, "set /skills dir <skills-dir> before generating skills") {
		t.Fatalf("expected missing skills dir message, got %#v", result.messages)
	}
}

func TestSkillsGenerateCommandRequiresProvider(t *testing.T) {
	m := model{savedConfig: savedConfig{SkillsDir: "/tmp/skills"}}

	updated, _ := m.handleCommand("/skills generate docs-helper Helps write concise docs")
	result := updated.(model)

	if result.view != viewSetup {
		t.Fatalf("expected setup view, got %v", result.view)
	}
	if len(result.messages) == 0 ||
		!strings.Contains(result.messages[len(result.messages)-1].Text, "select a provider before generating skills") {
		t.Fatalf("expected missing provider message, got %#v", result.messages)
	}
}

func TestBuildSkillsGenerateCLIArgsIncludesProviderRuntime(t *testing.T) {
	args, err := buildSkillsGenerateCLIArgs(
		runConfig{
			Provider:     providerOpenRouter,
			Model:        "openai/gpt-5.1",
			HTTPTimeout:  "120000",
			InputPrice:   "1.25",
			OutputPrice:  "2.50",
			SkillsDir:    "/tmp/skills",
			ToolApproval: "read-only",
		},
		"docs-helper",
		"Helps write concise docs",
	)
	if err != nil {
		t.Fatalf("expected generate args, got %v", err)
	}

	assertContainsSequence(t, args, []string{
		"generate",
		"docs-helper",
		"--skills-dir",
		"/tmp/skills",
		"--description",
		"Helps write concise docs",
		"--provider",
		"openrouter",
		"--model",
		"openai/gpt-5.1",
		"--http-timeout-ms",
		"120000",
		"--input-price-per-million",
		"1.25",
		"--output-price-per-million",
		"2.50",
		"--json",
	})
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

func TestLastJSONLineIgnoresMixCompileNoise(t *testing.T) {
	raw := strings.Join([]string{
		"Compiling 2 files (.ex)",
		"Generated agent_machine app",
		`{"skills":[{"name":"docs-helper","description":"Helps write docs"}]}`,
	}, "\n")

	if got := lastJSONLine(raw); got != `{"skills":[{"name":"docs-helper","description":"Helps write docs"}]}` {
		t.Fatalf("expected final JSON line, got %q", got)
	}
}

func TestParseJSONLLineIgnoresObjectLikeNonProtocolNoise(t *testing.T) {
	envelope, ok, err := parseJSONLLine(`{ signal: lock acquired }`)
	if err != nil {
		t.Fatalf("expected non-protocol line to be ignored, got %v", err)
	}
	if ok || envelope.Type != "" {
		t.Fatalf("expected ignored line, got %#v", envelope)
	}
}

func TestParseJSONLLineRejectsMalformedProtocolEnvelope(t *testing.T) {
	_, _, err := parseJSONLLine(`{"type":event}`)
	if err == nil || !strings.Contains(err.Error(), "failed to parse AgentMachine JSONL line") {
		t.Fatalf("expected malformed AgentMachine envelope error, got %v", err)
	}
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

func TestFilesystemWriteStartsRuntimeWithoutTUIIntentGuessing(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		provider:    providerEcho,
		providerSet: true,
		configPath:  configPath,
	}

	updated, cmd := m.startRun("create directory testmme in my home folder")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected runtime command instead of TUI permission preflight")
	}
	if !result.running {
		t.Fatal("expected runtime run to start")
	}
	if result.pendingToolTask != "" || result.pendingToolHarness != "" || result.pendingToolRoot != "" {
		t.Fatalf("expected no TUI-inferred tool request, got task=%q harness=%q root=%q", result.pendingToolTask, result.pendingToolHarness, result.pendingToolRoot)
	}
}

func TestStartRunForcesAgenticWorkflowWhenPersistenceEnabled(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
		provider:    providerEcho,
		providerSet: true,
		configPath:  configPath,
		savedConfig: savedConfig{
			AgenticPersistenceRounds:   "2",
			AgenticPersistenceMaxSteps: "9",
			AgenticPersistenceTimeout:  "300000",
		},
	}

	updated, cmd := m.startRun("review this project")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected runtime command")
	}
	if result.activeConfig.Workflow != workflowAgentic {
		t.Fatalf("expected agentic runtime, got %q", result.activeConfig.Workflow)
	}
	if result.activeConfig.AgenticPersistenceRounds != "2" ||
		result.activeConfig.MaxSteps != "9" ||
		result.activeConfig.RunTimeout != "300000" {
		t.Fatalf("expected explicit persistence runtime config, got %#v", result.activeConfig)
	}
}

func TestValidateConfigRejectsIncompleteAgenticPersistence(t *testing.T) {
	err := validateConfig(runConfig{
		Task:                     "review this project",
		Workflow:                 workflowAgentic,
		Provider:                 providerEcho,
		AgenticPersistenceRounds: "2",
	})
	if err == nil || !strings.Contains(err.Error(), "explicit max steps") {
		t.Fatalf("expected missing max steps error, got %v", err)
	}

	err = validateConfig(runConfig{
		Task:                     "review this project",
		Workflow:                 workflowAgentic,
		Provider:                 providerEcho,
		RunTimeout:               "300000",
		MaxSteps:                 "9",
		AgenticPersistenceRounds: "2",
	})
	if err != nil {
		t.Fatalf("expected complete agentic persistence config, got %v", err)
	}
}

func TestCodeEditFollowUpStartsRuntimeWithoutTUIIntentGuessing(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
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

	if cmd == nil {
		t.Fatal("expected runtime command instead of TUI permission preflight")
	}
	if result.pendingToolTask != "" || result.pendingToolHarness != "" || result.pendingToolRoot != "" {
		t.Fatalf("expected no TUI-inferred tool request, got task=%q harness=%q root=%q", result.pendingToolTask, result.pendingToolHarness, result.pendingToolRoot)
	}
}

func TestNextJSProjectCreationStartsRuntimeWithoutTUIIntentGuessing(t *testing.T) {
	t.Setenv("HOME", "/tmp/agent-machine-home")

	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
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

	if cmd == nil {
		t.Fatal("expected runtime command instead of TUI permission preflight")
	}
	if result.pendingToolTask != "" || result.pendingToolHarness != "" || result.pendingToolRoot != "" {
		t.Fatalf("expected no TUI-inferred tool request, got task=%q harness=%q root=%q", result.pendingToolTask, result.pendingToolHarness, result.pendingToolRoot)
	}
}

func TestRouterMutationCapabilityErrorShowsPermissionSelector(t *testing.T) {
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
			{Role: "user", Text: "create a nice nextjs website"},
		},
	}

	updated, handled := m.withCapabilityRequired(capabilityRequired{
		Reason:          "missing_code_edit_harness",
		Intent:          "code_mutation",
		RequiredHarness: "code-edit",
		RequestedRoot:   "/tmp/agent-machine-home",
	})

	if !handled {
		t.Fatal("expected capability requirement to be handled")
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
		!strings.Contains(last, "missing_code_edit_harness") ||
		!strings.Contains(last, "timeout_ms="+defaultFilesystemToolTimeout) ||
		!strings.Contains(last, "max_rounds="+defaultFilesystemToolMaxRounds) {
		t.Fatalf("expected permission prompt, got %q", last)
	}
}

func TestPersistentSessionCapabilitySummaryShowsPermissionSelector(t *testing.T) {
	m := model{
		running:     true,
		stream:      &streamSession{persistent: true},
		provider:    providerOpenRouter,
		providerSet: true,
		agents:      map[string]agentState{},
		workItems:   map[string]workItem{},
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
		},
		messages: []chatMessage{
			{Role: "user", Text: "can you create me website"},
		},
	}

	updated, _ := m.handleStreamLine(`{"type":"summary","summary":{"status":"failed","error":"agentic runtime detected code mutation intent but :code_edit tool harness is not configured","final_output":null,"results":{},"events":[],"capability_required":{"reason":"missing_code_edit_harness","intent":"code_mutation","required_harness":"code-edit","requested_root":"/tmp/agent-machine-home"}}}`)

	if updated.pendingToolTask == "" {
		t.Fatal("expected pending tool task")
	}
	if updated.pendingToolHarness != "code-edit" {
		t.Fatalf("expected code-edit harness, got %q", updated.pendingToolHarness)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "filesystem permission required") ||
		!strings.Contains(last, "required harness: code-edit") ||
		!strings.Contains(last, "missing_code_edit_harness") {
		t.Fatalf("expected code-edit permission prompt, got %q", last)
	}
}

func TestCapabilitySummaryWithoutRootRequiresExplicitToolRoot(t *testing.T) {
	m := model{
		running:     true,
		stream:      &streamSession{persistent: true},
		provider:    providerOpenRouter,
		providerSet: true,
		agents:      map[string]agentState{},
		workItems:   map[string]workItem{},
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/tmp/agent-machine-home",
			ToolTimeout:   "1000",
			ToolMaxRounds: "6",
			ToolApproval:  "auto-approved-safe",
		},
		messages: []chatMessage{
			{Role: "user", Text: "can you create me react website"},
		},
	}

	updated, _ := m.handleStreamLine(`{"type":"summary","summary":{"status":"failed","error":"agentic runtime detected code mutation intent but :code_edit tool harness is not configured","final_output":null,"results":{},"events":[],"capability_required":{"reason":"missing_code_edit_harness","intent":"code_mutation","required_harness":"code-edit"}}}`)

	if updated.running {
		t.Fatal("expected persistent run to stop after failed summary")
	}
	if updated.pendingToolTask != "" || updated.pendingToolHarness != "" || updated.pendingToolRoot != "" {
		t.Fatalf("expected no pending approval without explicit root, got task=%q harness=%q root=%q", updated.pendingToolTask, updated.pendingToolHarness, updated.pendingToolRoot)
	}
	last := updated.messages[len(updated.messages)-1]
	if last.Role != "system" ||
		!strings.Contains(last.Text, "tool root is required") ||
		!strings.Contains(last.Text, "/tools code-edit <root>") {
		t.Fatalf("expected explicit root prompt, got %#v", last)
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

	updated, handled := m.withCapabilityRequired(capabilityRequired{
		Reason:          "missing_write_harness",
		Intent:          "file_mutation",
		RequiredHarness: "local-files",
		RequestedRoot:   "/tmp/agent-machine-home",
	})

	if !handled {
		t.Fatal("expected capability requirement to be handled")
	}
	if updated.pendingToolHarness != "local-files" {
		t.Fatalf("expected local-files harness, got %q", updated.pendingToolHarness)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "required harness: local-files") ||
		!strings.Contains(last, "missing_write_harness") {
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

	updated, handled := m.withCapabilityRequired(capabilityRequired{
		Reason:                "missing_test_approval",
		Intent:                "test_command",
		RequiredHarness:       "code-edit",
		RequiredApprovalModes: []string{"full-access", "ask-before-write"},
		RequestedRoot:         "/tmp/agent-machine-home",
	})

	if !handled {
		t.Fatal("expected capability requirement to be handled")
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

	updated, handled := m.withCapabilityRequired(capabilityRequired{
		Reason:                "missing_browser_approval",
		Intent:                "web_browse",
		RequiredHarness:       "mcp",
		RequiredMCPTool:       "browser_navigate",
		RequiredApprovalModes: []string{"full-access", "ask-before-write"},
	})

	if !handled {
		t.Fatal("expected web browse capability requirement to be handled")
	}
	if updated.pendingToolHarness != pendingHarnessMCPBrowser {
		t.Fatalf("expected MCP browser pending harness, got %q", updated.pendingToolHarness)
	}
	if updated.pendingToolRoot != "" {
		t.Fatalf("expected no filesystem root for MCP browser approval, got %q", updated.pendingToolRoot)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "MCP browser permission required") ||
		!strings.Contains(last, "ask-before-write") ||
		!strings.Contains(last, "/tmp/agent-machine.mcp.json") {
		t.Fatalf("expected MCP browser permission prompt, got %q", last)
	}
	view := updated.View()
	if !strings.Contains(view, "harness: "+pendingHarnessMCPBrowser) ||
		!strings.Contains(view, "> Ask each use") ||
		!strings.Contains(view, "Full access") ||
		!strings.Contains(view, "Deny") {
		t.Fatalf("expected MCP browser permission selector, got %q", view)
	}
}

func TestMCPBrowserTimeoutCapabilityErrorShowsMCPBrowserSelector(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
		savedConfig: savedConfig{
			ToolTimeout:   "1000",
			ToolMaxRounds: "16",
			ToolApproval:  "ask-before-write",
			MCPConfig:     "/tmp/agent-machine.mcp.json",
		},
		messages: []chatMessage{
			{Role: "user", Text: "make me research of latest AI papers"},
		},
	}

	updated, handled := m.withCapabilityRequired(capabilityRequired{
		Reason:          "insufficient_tool_timeout",
		Intent:          "web_browse",
		RequiredHarness: "mcp",
		RequiredMCPTool: "browser_navigate",
		Detail:          "MCP browser access requires :tool_timeout_ms >= 60000, got: 1000",
	})

	if !handled {
		t.Fatal("expected MCP browser timeout capability requirement to be handled")
	}
	if updated.pendingToolHarness != pendingHarnessMCPBrowser {
		t.Fatalf("expected MCP browser pending harness, got %q", updated.pendingToolHarness)
	}
	last := updated.messages[len(updated.messages)-1].Text
	if !strings.Contains(last, "MCP browser permission required") ||
		!strings.Contains(last, "/tmp/agent-machine.mcp.json") {
		t.Fatalf("expected MCP browser permission prompt, got %q", last)
	}
}

func TestAllowToolsApprovesPendingFilesystemRun(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("expected home directory, got %v", err)
	}

	m := model{
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		pendingToolTask:    "create directory testmme in my home folder",
		pendingToolRoot:    home,
		pendingToolHarness: "local-files",
	}

	updated, cmd := m.handleCommand("/allow-tools")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after allowing tools")
	}
	if !result.running {
		t.Fatal("expected run to start after allowing tools")
	}
	if result.savedConfig.ToolHarness != "local-files" ||
		result.savedConfig.ToolRoot != home ||
		result.savedConfig.ToolTimeout != defaultFilesystemToolTimeout ||
		result.savedConfig.ToolMaxRounds != defaultFilesystemToolMaxRounds ||
		result.savedConfig.ToolApproval != "ask-before-write" {
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
		result.savedConfig.ToolApproval != "ask-before-write" {
		t.Fatalf("unexpected MCP browser tool config: %#v", result.savedConfig)
	}
	if result.activeConfig.Workflow != workflowAgentic {
		t.Fatalf("expected MCP browser approval retry to use agentic runtime, got %q", result.activeConfig.Workflow)
	}
	if result.pendingToolTask != "" || result.pendingToolRoot != "" || result.pendingToolHarness != "" {
		t.Fatalf("expected pending MCP browser request to clear, got task=%q root=%q harness=%q", result.pendingToolTask, result.pendingToolRoot, result.pendingToolHarness)
	}
}

func TestAllowToolsApprovesPendingCodeEditRun(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")

	m := model{
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
	if result.savedConfig.ToolHarness != "code-edit" ||
		result.savedConfig.ToolRoot != "/tmp/agent-machine-home" ||
		result.savedConfig.ToolTimeout != defaultFilesystemToolTimeout ||
		result.savedConfig.ToolMaxRounds != defaultFilesystemToolMaxRounds ||
		result.savedConfig.ToolApproval != "ask-before-write" {
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
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		pendingToolTask:    "create directory testmme in my home folder",
		pendingToolRoot:    home,
		pendingToolHarness: "local-files",
	}

	updated, cmd := m.handleCommand("/yolo-tools")
	result := updated.(model)

	if cmd == nil {
		t.Fatal("expected run command after yolo tools")
	}
	if result.savedConfig.ToolTimeout != defaultFilesystemToolTimeout ||
		result.savedConfig.ToolMaxRounds != defaultFilesystemToolMaxRounds ||
		result.savedConfig.ToolApproval != "full-access" {
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
	if result.savedConfig.ToolHarness != "local-files" ||
		result.savedConfig.ToolRoot != home ||
		result.savedConfig.ToolTimeout != defaultFilesystemToolTimeout ||
		result.savedConfig.ToolMaxRounds != defaultFilesystemToolMaxRounds ||
		result.savedConfig.ToolApproval != "ask-before-write" {
		t.Fatalf("unexpected tool config: %#v", result.savedConfig)
	}
	if result.pendingToolTask != "" {
		t.Fatalf("expected pending request to clear, got %q", result.pendingToolTask)
	}
}

func TestPendingToolSelectorCanChooseFullAccessAndDeny(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")

	m := model{
		provider:           providerEcho,
		providerSet:        true,
		configPath:         configPath,
		view:               viewChat,
		input:              textinput.New(),
		pendingToolTask:    "fix /tmp/agent-machine-home/app.py",
		pendingToolRoot:    "/tmp/agent-machine-home",
		pendingToolHarness: "code-edit",
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	result := updated.(model)
	if cmd == nil {
		t.Fatal("expected run command after full-access selector approval")
	}
	if result.savedConfig.ToolHarness != "code-edit" ||
		result.savedConfig.ToolTimeout != defaultFilesystemToolTimeout ||
		result.savedConfig.ToolMaxRounds != defaultFilesystemToolMaxRounds ||
		result.savedConfig.ToolApproval != "full-access" {
		t.Fatalf("unexpected tool config: %#v", result.savedConfig)
	}

	deny := model{
		view:               viewChat,
		input:              textinput.New(),
		pendingToolTask:    "fix the existing app",
		pendingToolRoot:    "/tmp/agent-machine-home",
		pendingToolHarness: "code-edit",
		pendingToolChoice:  3,
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

func TestFilesystemWriteDoesNotPreflightActiveRootCoverage(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	m := model{
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

	if cmd == nil {
		t.Fatal("expected runtime command instead of TUI root coverage preflight")
	}
	if result.pendingToolTask != "" || result.pendingToolHarness != "" || result.pendingToolRoot != "" {
		t.Fatalf("expected no TUI-inferred tool request, got task=%q harness=%q root=%q", result.pendingToolTask, result.pendingToolHarness, result.pendingToolRoot)
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
	if loaded.ProviderModels[string(providerOpenRouter)] != "openai/gpt-4o-mini" {
		t.Fatalf("expected provider model to persist, got %#v", loaded.ProviderModels)
	}
	if loaded.OpenRouterModel != "" {
		t.Fatalf("expected legacy model field to stay empty, got %q", loaded.OpenRouterModel)
	}
}

func TestInitialModelLoadsSavedSetup(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	if err := saveSavedConfig(configPath, savedConfig{
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

func TestInitialModelKeepsLLMRouterDefaultWhenZeroShotModelIsInstalled(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "agent-machine", "tui-config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	modelDir := defaultRouterModelDir(configPath)
	writeRouterModelFilesForTest(t, modelDir)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if m.savedConfig.RouterMode != "" || m.savedConfig.RouterModelDir != "" {
		t.Fatalf("expected empty saved router config for llm default, got %#v", m.savedConfig)
	}
	if status := m.routerStatus(); status != "router: llm current model" {
		t.Fatalf("expected llm router status, got %q", status)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected config load, got %v", err)
	}
	if loaded.RouterMode != "" {
		t.Fatalf("expected auto-detected router not to persist until user changes settings, got %#v", loaded)
	}
}

func TestInitialModelMigratesSavedStandardLocalRouterDefaultToLLM(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "agent-machine", "tui-config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	if err := saveSavedConfig(configPath, savedConfig{
		RouterMode:       "local",
		RouterModelDir:   defaultRouterModelDir(configPath),
		RouterTimeout:    defaultRouterTimeoutMS,
		RouterConfidence: defaultRouterConfidence,
	}); err != nil {
		t.Fatalf("expected saved config write to succeed, got %v", err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if m.savedConfig.RouterMode != "" || m.savedConfig.RouterModelDir != "" || m.savedConfig.RouterTimeout != "" || m.savedConfig.RouterConfidence != "" {
		t.Fatalf("expected legacy local router default to migrate to empty llm config, got %#v", m.savedConfig)
	}
	if status := m.routerStatus(); status != "router: llm current model" {
		t.Fatalf("expected llm router status, got %q", status)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected config load, got %v", err)
	}
	if loaded.RouterMode != "" || loaded.RouterModelDir != "" || loaded.RouterTimeout != "" || loaded.RouterConfidence != "" {
		t.Fatalf("expected legacy local router default migration to persist, got %#v", loaded)
	}
}

func TestInitialModelKeepsCustomLocalRouterConfig(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "agent-machine", "tui-config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)
	customRouterDir := filepath.Join(t.TempDir(), "custom-router")

	if err := saveSavedConfig(configPath, savedConfig{
		RouterMode:       "local",
		RouterModelDir:   customRouterDir,
		RouterTimeout:    defaultRouterTimeoutMS,
		RouterConfidence: defaultRouterConfidence,
	}); err != nil {
		t.Fatalf("expected saved config write to succeed, got %v", err)
	}

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	if m.savedConfig.RouterMode != "local" || m.savedConfig.RouterModelDir != customRouterDir {
		t.Fatalf("expected custom local router config to remain, got %#v", m.savedConfig)
	}
	if status := m.routerStatus(); !strings.Contains(status, "router: local dir="+customRouterDir) {
		t.Fatalf("expected local router status, got %q", status)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected config load, got %v", err)
	}
	if loaded.RouterMode != "local" || loaded.RouterModelDir != customRouterDir {
		t.Fatalf("expected custom local router config to remain persisted, got %#v", loaded)
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

func TestStreamLineTracksRuntimePermissionRequests(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"permission_requested","run_id":"run-1","request_id":"req-1","kind":"tool_execution","agent_id":"worker","parent_agent_id":"planner","tool_call_id":"call-1","tool":"write_file","permission":"local_files_write","approval_risk":"write","approval_mode":"ask_before_write","summary":"worker requested write_file"}}`)
	if len(updated.pendingPermissionID) != 1 || updated.pendingPermissionID[0] != "req-1" {
		t.Fatalf("expected pending permission id, got %#v", updated.pendingPermissionID)
	}
	request, ok := updated.currentPendingPermission()
	if !ok || request.RequestID != "req-1" || request.AgentID != "worker" || request.ParentAgentID != "planner" || request.Tool != "write_file" {
		t.Fatalf("expected pending permission details, got %#v ok=%v", request, ok)
	}

	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"permission_decided","run_id":"run-1","request_id":"req-1","kind":"tool_execution","decision":"deny","summary":"permission denied"}}`)
	if len(updated.pendingPermissionID) != 0 || len(updated.pendingPermissions) != 0 {
		t.Fatalf("expected permission to clear after decision, got ids=%#v map=%#v", updated.pendingPermissionID, updated.pendingPermissions)
	}
}

func TestStreamLineTracksPlannerReviewRequests(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"planner_review_requested","run_id":"run-1","request_id":"review-1","planner_id":"planner","reason":"needs workers","delegated_agent_ids":["worker-a"],"proposed_agents":[{"id":"worker-a","input":"do part a","depends_on":[]}],"summary":"planner requested review"}}`)
	if len(updated.pendingPlannerReviewID) != 1 || updated.pendingPlannerReviewID[0] != "review-1" {
		t.Fatalf("expected pending planner review id, got %#v", updated.pendingPlannerReviewID)
	}
	request, ok := updated.currentPendingPlannerReview()
	if !ok || request.RequestID != "review-1" || request.PlannerID != "planner" || request.ProposedAgents[0].ID != "worker-a" {
		t.Fatalf("expected planner review details, got %#v ok=%v", request, ok)
	}

	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"planner_review_decided","run_id":"run-1","request_id":"review-1","planner_id":"planner","decision":"approve","summary":"planner review approve"}}`)
	if len(updated.pendingPlannerReviewID) != 0 || len(updated.pendingPlannerReviews) != 0 {
		t.Fatalf("expected planner review to clear after decision, got ids=%#v map=%#v", updated.pendingPlannerReviewID, updated.pendingPlannerReviews)
	}
}

func TestPlannerReviewSelectorCanDeclineWithKeyboard(t *testing.T) {
	stdin := &closeBuffer{}
	m := model{
		running: true,
		view:    viewChat,
		input:   textinput.New(),
		stream:  &streamSession{stdin: stdin, persistent: true},
		pendingPlannerReviews: map[string]eventSummary{
			"review-1": {
				RequestID:         "review-1",
				PlannerID:         "planner",
				Reason:            "needs workers",
				DelegatedAgentIDs: []string{"worker-a"},
				ProposedAgents:    []plannerAgent{{ID: "worker-a", Input: "do part a"}},
			},
		},
		pendingPlannerReviewID: []string{"review-1"},
	}

	view := stripANSI(m.pendingPlannerReviewView())
	if !strings.Contains(view, "> Approve plan") || !strings.Contains(view, "Request revision") || !strings.Contains(view, "worker-a") {
		t.Fatalf("expected selectable planner review options, got %q", view)
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	result := updated.(model)
	if cmd == nil {
		t.Fatal("expected planner review decision command")
	}
	if len(result.pendingPlannerReviewID) != 0 || len(result.pendingPlannerReviews) != 0 {
		t.Fatalf("expected pending planner review to clear, got ids=%#v map=%#v", result.pendingPlannerReviewID, result.pendingPlannerReviews)
	}

	msg := cmd()
	decision, ok := msg.(plannerReviewDecisionMsg)
	if !ok {
		t.Fatalf("expected planner review decision message, got %#v", msg)
	}
	if decision.Err != nil || decision.RequestID != "review-1" || decision.Decision != "decline" {
		t.Fatalf("unexpected decision result: %#v", decision)
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdin.String())), &payload); err != nil {
		t.Fatalf("expected JSONL payload, got %q: %v", stdin.String(), err)
	}
	if payload["type"] != "planner_review_decision" || payload["request_id"] != "review-1" || payload["decision"] != "decline" {
		t.Fatalf("unexpected planner review decision payload: %#v", payload)
	}
}

func TestPlannerReviewTypedFeedbackRequestsRevision(t *testing.T) {
	stdin := &closeBuffer{}
	input := textinput.New()
	input.SetValue("split into one worker only")
	m := model{
		running: true,
		view:    viewChat,
		input:   input,
		stream:  &streamSession{stdin: stdin, persistent: true},
		pendingPlannerReviews: map[string]eventSummary{
			"review-1": {RequestID: "review-1", PlannerID: "planner"},
		},
		pendingPlannerReviewID: []string{"review-1"},
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)
	if cmd == nil {
		t.Fatal("expected planner review revision command")
	}
	if len(result.queuedMessages) != 0 {
		t.Fatalf("expected feedback to revise planner instead of queueing, got %#v", result.queuedMessages)
	}
	if result.input.Value() != "" {
		t.Fatalf("expected input to clear, got %q", result.input.Value())
	}

	msg := cmd()
	decision, ok := msg.(plannerReviewDecisionMsg)
	if !ok {
		t.Fatalf("expected planner review decision message, got %#v", msg)
	}
	if decision.Err != nil || decision.RequestID != "review-1" || decision.Decision != "revise" {
		t.Fatalf("unexpected decision result: %#v", decision)
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdin.String())), &payload); err != nil {
		t.Fatalf("expected JSONL payload, got %q: %v", stdin.String(), err)
	}
	if payload["type"] != "planner_review_decision" || payload["request_id"] != "review-1" || payload["decision"] != "revise" || payload["feedback"] != "split into one worker only" {
		t.Fatalf("unexpected planner review decision payload: %#v", payload)
	}
}

func TestRuntimePermissionSelectorCanChooseDenyWithKeyboard(t *testing.T) {
	stdin := &closeBuffer{}
	m := model{
		running: true,
		view:    viewChat,
		input:   textinput.New(),
		stream:  &streamSession{stdin: stdin, persistent: true},
		pendingPermissions: map[string]eventSummary{
			"req-1": {
				RequestID:    "req-1",
				Kind:         "tool_execution",
				AgentID:      "worker",
				Tool:         "create_dir",
				ApprovalRisk: "write",
			},
		},
		pendingPermissionID: []string{"req-1"},
	}

	view := stripANSI(m.pendingRuntimePermissionView())
	if !strings.Contains(view, "> Approve once") || !strings.Contains(view, "  Deny") {
		t.Fatalf("expected selectable runtime permission options, got %q", view)
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	result := updated.(model)
	if result.pendingPermissionChoice != 1 {
		t.Fatalf("expected deny option to be selected, got %d", result.pendingPermissionChoice)
	}

	updated, cmd = result.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result = updated.(model)
	if cmd == nil {
		t.Fatal("expected permission decision command")
	}
	if len(result.pendingPermissionID) != 0 || len(result.pendingPermissions) != 0 {
		t.Fatalf("expected pending permission to clear, got ids=%#v map=%#v", result.pendingPermissionID, result.pendingPermissions)
	}

	msg := cmd()
	decision, ok := msg.(permissionDecisionMsg)
	if !ok {
		t.Fatalf("expected permission decision message, got %#v", msg)
	}
	if decision.Err != nil || decision.RequestID != "req-1" || decision.Decision != "deny" {
		t.Fatalf("unexpected decision result: %#v", decision)
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdin.String())), &payload); err != nil {
		t.Fatalf("expected JSONL payload, got %q: %v", stdin.String(), err)
	}
	if payload["type"] != "permission_decision" || payload["request_id"] != "req-1" || payload["decision"] != "deny" {
		t.Fatalf("unexpected permission decision payload: %#v", payload)
	}
}

func TestRuntimePermissionSlashApproveDoesNotQueueMessage(t *testing.T) {
	stdin := &closeBuffer{}
	input := textinput.New()
	input.SetValue("/a")
	m := model{
		running: true,
		view:    viewChat,
		input:   input,
		stream:  &streamSession{stdin: stdin, persistent: true},
		pendingPermissions: map[string]eventSummary{
			"req-1": {
				RequestID:    "req-1",
				Kind:         "tool_execution",
				AgentID:      "worker",
				Tool:         "create_dir",
				ApprovalRisk: "write",
			},
		},
		pendingPermissionID: []string{"req-1"},
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	result := updated.(model)
	if cmd == nil {
		t.Fatal("expected permission decision command")
	}
	if len(result.queuedMessages) != 0 {
		t.Fatalf("expected /a to approve permission instead of queueing, got %#v", result.queuedMessages)
	}
	if result.input.Value() != "" {
		t.Fatalf("expected input to clear, got %q", result.input.Value())
	}

	msg := cmd()
	decision, ok := msg.(permissionDecisionMsg)
	if !ok {
		t.Fatalf("expected permission decision message, got %#v", msg)
	}
	if decision.Err != nil || decision.RequestID != "req-1" || decision.Decision != "approve" {
		t.Fatalf("unexpected decision result: %#v", decision)
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdin.String())), &payload); err != nil {
		t.Fatalf("expected JSONL payload, got %q: %v", stdin.String(), err)
	}
	if payload["type"] != "permission_decision" || payload["request_id"] != "req-1" || payload["decision"] != "approve" {
		t.Fatalf("unexpected permission decision payload: %#v", payload)
	}
}

func TestSendPermissionDecisionCommandWritesJSONL(t *testing.T) {
	stdin := &closeBuffer{}
	session := &streamSession{stdin: stdin}

	msg := sendPermissionDecisionCommand(session, "req-1", "approve", "TUI approve")()
	decision, ok := msg.(permissionDecisionMsg)
	if !ok {
		t.Fatalf("expected permission decision message, got %#v", msg)
	}
	if decision.Err != nil || decision.RequestID != "req-1" || decision.Decision != "approve" {
		t.Fatalf("unexpected decision result: %#v", decision)
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdin.String())), &payload); err != nil {
		t.Fatalf("expected JSONL payload, got %q: %v", stdin.String(), err)
	}
	if payload["type"] != "permission_decision" || payload["request_id"] != "req-1" || payload["decision"] != "approve" || payload["reason"] != "TUI approve" {
		t.Fatalf("unexpected permission decision payload: %#v", payload)
	}
}

func TestSendPlannerReviewDecisionCommandWritesJSONL(t *testing.T) {
	stdin := &closeBuffer{}
	session := &streamSession{stdin: stdin}

	msg := sendPlannerReviewDecisionCommand(session, "review-1", "revise", "make it smaller", "TUI revise")()
	decision, ok := msg.(plannerReviewDecisionMsg)
	if !ok {
		t.Fatalf("expected planner review decision message, got %#v", msg)
	}
	if decision.Err != nil || decision.RequestID != "review-1" || decision.Decision != "revise" {
		t.Fatalf("unexpected decision result: %#v", decision)
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdin.String())), &payload); err != nil {
		t.Fatalf("expected JSONL payload, got %q: %v", stdin.String(), err)
	}
	if payload["type"] != "planner_review_decision" || payload["request_id"] != "review-1" || payload["decision"] != "revise" || payload["feedback"] != "make it smaller" || payload["reason"] != "TUI revise" {
		t.Fatalf("unexpected planner review decision payload: %#v", payload)
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
			"queued": {
				ID:            "queued",
				ParentAgentID: "planner",
				Status:        "pending",
			},
		},
		agentOrder: []string{"planner", "worker", "failed", "timed", "queued"},
	}

	view := m.agentChecklistView()
	for _, expected := range []string{"[-] planner", "[v] worker", "[x] failed", "[x] timed", "[-] queued"} {
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

func TestJSONLSummaryAccumulatesSessionUsageOncePerRun(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-1","status":"completed","final_output":"done","results":{},"usage":{"agents":1,"input_tokens":3,"output_tokens":4,"total_tokens":7},"events":[]}}`)
	updated, _ = updated.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-2","status":"completed","final_output":"done","results":{},"usage":{"agents":1,"input_tokens":5,"output_tokens":6,"total_tokens":11},"events":[]}}`)
	updated, _ = updated.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-1","status":"completed","final_output":"done again","results":{},"usage":{"agents":1,"input_tokens":3,"output_tokens":4,"total_tokens":7},"events":[]}}`)

	if updated.sessionUsage.TotalTokens != 18 {
		t.Fatalf("expected deduplicated session token total, got %#v", updated.sessionUsage)
	}
	if updated.sessionUsage.InputTokens != 8 || updated.sessionUsage.OutputTokens != 10 {
		t.Fatalf("expected input/output token totals, got %#v", updated.sessionUsage)
	}
	if !strings.Contains(updated.statusLine(), "session_tokens=18") {
		t.Fatalf("expected token total in status line, got %q", updated.statusLine())
	}
}

func TestJSONLProviderUsageEventsAccumulateSessionUsageWithoutSummaryDoubleCount(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"provider_request_finished","run_id":"run-1","agent_id":"assistant","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"provider_request_finished","run_id":"run-1","agent_id":"assistant","usage":{"input_tokens":20,"output_tokens":7,"total_tokens":27}}}`)
	updated, _ = updated.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-1","status":"completed","final_output":"done","results":{},"usage":{"agents":1,"input_tokens":30,"output_tokens":12,"total_tokens":42},"events":[]}}`)

	if updated.sessionUsage.TotalTokens != 42 {
		t.Fatalf("expected live usage total without summary double count, got %#v", updated.sessionUsage)
	}
	if updated.sessionUsage.InputTokens != 30 || updated.sessionUsage.OutputTokens != 12 {
		t.Fatalf("expected live input/output totals, got %#v", updated.sessionUsage)
	}
}

func TestJSONLSummaryAppliesChecklist(t *testing.T) {
	m := model{agents: map[string]agentState{}}

	updated, _ := m.handleStreamLine(`{"type":"summary","summary":{"run_id":"run-1","status":"completed","final_output":"done","results":{},"checklist":[{"id":"agent:planner","kind":"agent","label":"planner","status":"done","latest_summary":"planner finished"},{"id":"tool:worker:call-1","kind":"tool","label":"worker read README.md","parent_id":"agent:worker","status":"done","latest_summary":"worker read README.md"}],"usage":{"agents":1},"events":[]}}`)

	if len(updated.workOrder) != 2 {
		t.Fatalf("expected checklist rows, got %#v", updated.workOrder)
	}
	view := updated.workChecklistView()
	if !strings.Contains(view, "[v] planner") || !strings.Contains(view, "worker read README.md") {
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

func TestJSONLAssistantDeltaUpdatesStreamWithoutLiveFeedNoise(t *testing.T) {
	m := model{agents: map[string]agentState{}, eventAutoScroll: true}

	updated, _ := m.handleStreamLine(`{"type":"event","event":{"type":"assistant_delta","run_id":"run-1","agent_id":"assistant","attempt":1,"delta":"hel","summary":"assistant streamed text","details":{"attempt":1},"at":"2026-04-25T10:00:00Z"}}`)
	updated, _ = updated.handleStreamLine(`{"type":"event","event":{"type":"assistant_delta","run_id":"run-1","agent_id":"assistant","attempt":1,"delta":"lo","summary":"assistant streamed text","details":{"attempt":1},"at":"2026-04-25T10:00:01Z"}}`)

	if updated.liveAssistant != "hello" {
		t.Fatalf("expected live assistant draft, got %q", updated.liveAssistant)
	}
	if updated.agents["assistant"].StreamOutput != "hello" {
		t.Fatalf("expected agent stream draft, got %#v", updated.agents["assistant"])
	}
	if updated.agents["assistant"].Output != "" {
		t.Fatalf("expected final output to stay empty until summary, got %#v", updated.agents["assistant"])
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

func TestLiveActivityViewShowsOnlyLatestEvent(t *testing.T) {
	m := model{running: true, streamFrame: 1, eventAutoScroll: true}
	m.eventLog = []eventSummary{
		{
			Type:    "provider_request_started",
			AgentID: "assistant",
			Summary: "old provider request",
		},
		{
			Type:    "tool_call_finished",
			AgentID: "worker",
			Tool:    "read_file",
			Status:  "ok",
			Summary: "latest worker read README.md",
		},
	}
	m.clampEventScroll()

	view := m.liveActivityView()
	if !strings.Contains(view, "latest worker read README.md") {
		t.Fatalf("expected latest event summary in live view, got %q", view)
	}
	if strings.Contains(view, "old provider request") {
		t.Fatalf("expected old event to be hidden in live view, got %q", view)
	}
	if strings.Contains(view, "Up/Down scroll") {
		t.Fatalf("expected live view without scroll hint, got %q", view)
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
		Provider:         "openrouter",
		OpenAIModel:      "gpt-4o-mini",
		OpenRouterModel:  "openai/gpt-4o-mini",
		Theme:            "matrix",
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

	if loaded.Theme != "matrix" {
		t.Fatalf("unexpected theme: %q", loaded.Theme)
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

func containsArg(args []string, key string) bool {
	for _, arg := range args {
		if arg == key {
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
