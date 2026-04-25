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
		HTTPTimeout: "25000",
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
		"--http-timeout-ms", "25000",
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

func TestValidateConfigRequiresOpenRouterKey(t *testing.T) {
	err := validateConfig(runConfig{
		Task:        "review this project",
		Workflow:    workflowBasic,
		Provider:    providerOpenRouter,
		APIKey:      "",
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.60",
		HTTPTimeout: "25000",
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
		HTTPTimeout: "25000",
	})

	if err != nil {
		t.Fatalf("expected valid config, got %v", err)
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

func TestModelCommandSelectsLoadedModel(t *testing.T) {
	m := model{
		provider:    providerOpenRouter,
		providerSet: true,
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
