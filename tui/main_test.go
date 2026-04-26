package main

import (
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
		"--timeout-ms", defaultRunTimeoutMS,
		"--max-steps", defaultAgenticSteps,
		"--max-attempts", "1",
		"--jsonl",
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
		ToolRoot:      "/Users/pawel/mywiki",
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
		"--model", "qwen/qwen3.5-flash-02-23",
		"--http-timeout-ms", "120000",
		"--input-price-per-million", "0.01",
		"--output-price-per-million", "0.01",
		"--tool-harness", "local-files",
		"--tool-timeout-ms", "1000",
		"--tool-max-rounds", "2",
		"--tool-approval-mode", "auto-approved-safe",
		"--tool-root", "/Users/pawel/mywiki",
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
		Provider: providerOpenRouter,
		Model:    "qwen/qwen3.5-flash-02-23",
	})

	if !strings.Contains(withoutTools, "tools off") {
		t.Fatalf("expected tools off in running status, got %q", withoutTools)
	}

	withTools := runningStatus(runConfig{
		Provider:    providerOpenRouter,
		Model:       "qwen/qwen3.5-flash-02-23",
		ToolHarness: "local-files",
		ToolRoot:    "/Users/pawel",
	})

	if !strings.Contains(withTools, "tools local-files root=/Users/pawel") {
		t.Fatalf("expected tool root in running status, got %q", withTools)
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
		ToolRoot:      "/Users/pawel/project",
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
		"--model", "qwen/qwen3.5-flash-02-23",
		"--http-timeout-ms", "120000",
		"--input-price-per-million", "0.01",
		"--output-price-per-million", "0.01",
		"--tool-harness", "code-edit",
		"--tool-timeout-ms", "1000",
		"--tool-max-rounds", "2",
		"--tool-approval-mode", "full-access",
		"--tool-root", "/Users/pawel/project",
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
		ToolRoot:    "/Users/pawel/mywiki",
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
		ToolRoot:      "/Users/pawel/project",
		ToolTimeout:   "1000",
		ToolMaxRounds: "2",
		ToolApproval:  "full-access",
	})

	if err != nil {
		t.Fatalf("expected valid code-edit config, got %v", err)
	}
}

func TestValidateConfigRequiresToolApprovalMode(t *testing.T) {
	err := validateConfig(runConfig{
		Task:          "edit code",
		Workflow:      workflowBasic,
		Provider:      providerEcho,
		ToolHarness:   "code-edit",
		ToolRoot:      "/Users/pawel/project",
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

	if !strings.Contains(lines, "call-1 write_file round=1 ok") {
		t.Fatalf("expected rendered tool event, got %q", lines)
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
	m.workflow = workflowBasic
	m.workflowSet = true
	m.savedConfig.OpenRouterAPIKey = "test-key"
	m.selectedModel = "openai/gpt-4o-mini"
	m.modelOptions = []modelOption{
		{ID: "openai/gpt-4o-mini", Pricing: modelPricing{InputPerMillion: 0.15, OutputPerMillion: 0.60}},
	}

	config := m.runConfig("review this project")

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

func TestInitialModelRequiresSetupBeforeRun(t *testing.T) {
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
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "select a workflow") {
		t.Fatalf("unexpected message: %#v", result.messages[len(result.messages)-1])
	}
}

func TestWorkflowCommandSwitchesSessionWorkflow(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/workflow agentic")
	result := updated.(model)

	if result.workflow != workflowAgentic {
		t.Fatalf("unexpected workflow: %q", result.workflow)
	}
	if !result.workflowSet {
		t.Fatal("expected workflow to be explicit")
	}
}

func TestWorkflowCommandPersistsSelectedWorkflow(t *testing.T) {
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
	if loaded.Workflow != "agentic" {
		t.Fatalf("expected workflow to persist, got %q", loaded.Workflow)
	}
}

func TestToolsCommandPersistsLocalFileHarness(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools local-files /Users/pawel/mywiki 1000 2 auto-approved-safe")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "local-files" {
		t.Fatalf("expected local-files harness, got %q", result.savedConfig.ToolHarness)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolRoot != "/Users/pawel/mywiki" || loaded.ToolTimeout != "1000" || loaded.ToolMaxRounds != "2" || loaded.ToolApproval != "auto-approved-safe" {
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

	updated, _ := m.handleCommand("/tools code-edit /Users/pawel/project 1000 2 full-access")
	result := updated.(model)

	if result.savedConfig.ToolHarness != "code-edit" {
		t.Fatalf("expected code-edit harness, got %q", result.savedConfig.ToolHarness)
	}

	loaded, err := loadSavedConfig(configPath)
	if err != nil {
		t.Fatalf("expected saved config to load, got %v", err)
	}
	if loaded.ToolHarness != "code-edit" || loaded.ToolRoot != "/Users/pawel/project" || loaded.ToolTimeout != "1000" || loaded.ToolMaxRounds != "2" || loaded.ToolApproval != "full-access" {
		t.Fatalf("unexpected saved tool config: %#v", loaded)
	}
}

func TestToolsCommandRejectsInvalidApprovalMode(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.json")
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", configPath)

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}

	updated, _ := m.handleCommand("/tools code-edit /Users/pawel/project 1000 2 maybe")
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
		ToolRoot:      "/Users/pawel/mywiki",
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
	last := result.messages[len(result.messages)-1].Text
	if !strings.Contains(last, "filesystem permission required") || !strings.Contains(last, "/allow-tools") || !strings.Contains(last, "/deny-tools") {
		t.Fatalf("expected permission prompt, got %q", last)
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
	if result.pendingToolTask != "" || result.pendingToolRoot != "" {
		t.Fatalf("expected pending tool request to be cleared, got task=%q root=%q", result.pendingToolTask, result.pendingToolRoot)
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

func TestDenyToolsClearsPendingFilesystemRun(t *testing.T) {
	m := model{
		pendingToolTask: "create directory testmme in my home folder",
		pendingToolRoot: "/Users/pawel",
	}

	updated, cmd := m.handleCommand("/deny-tools")
	result := updated.(model)

	if cmd != nil {
		t.Fatal("expected no command after denying tools")
	}
	if result.pendingToolTask != "" || result.pendingToolRoot != "" {
		t.Fatalf("expected pending request to clear, got task=%q root=%q", result.pendingToolTask, result.pendingToolRoot)
	}
	if !strings.Contains(result.messages[len(result.messages)-1].Text, "denied") {
		t.Fatalf("expected denied message, got %#v", result.messages)
	}
}

func TestStartRunIncludesRecentConversationContext(t *testing.T) {
	m := model{
		workflow:    workflowBasic,
		workflowSet: true,
		provider:    providerEcho,
		providerSet: true,
		savedConfig: savedConfig{
			ToolHarness:   "local-files",
			ToolRoot:      "/Users/pawel",
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
	}

	selected := recentConversationMessages(messages, 6)

	if len(selected) != 2 || selected[0].Text != "one" || selected[1].Text != "two" {
		t.Fatalf("unexpected selected messages: %#v", selected)
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
			ToolRoot:      "/Users/pawel/mywiki",
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
		Workflow:        "agentic",
		Provider:        "openrouter",
		OpenRouterModel: "openai/gpt-4o-mini",
		ToolHarness:     "local-files",
		ToolRoot:        "/Users/pawel/mywiki",
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

	if !m.workflowSet || m.workflow != workflowAgentic {
		t.Fatalf("expected saved workflow, got set=%v workflow=%q", m.workflowSet, m.workflow)
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
		ToolRoot:         "/Users/pawel/mywiki",
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
	if loaded.ToolRoot != "/Users/pawel/mywiki" {
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

func textInputForTest() textinput.Model {
	input := textinput.New()
	input.Focus()
	return input
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
