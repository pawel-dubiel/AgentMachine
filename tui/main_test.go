package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildRunArgsIncludesExplicitRuntimeOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:     "review this project",
		Provider: providerEcho,
	})

	expected := []string{
		"agent_machine.run",
		"--provider", "echo",
		"--timeout-ms", defaultRunTimeoutMS,
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

func TestBuildRunArgsIncludesOpenRouterOptions(t *testing.T) {
	args := buildRunArgs(runConfig{
		Task:        "review this project",
		Provider:    providerOpenRouter,
		Model:       "openai/gpt-4o-mini",
		InputPrice:  "0.15",
		OutputPrice: "0.60",
		HTTPTimeout: "25000",
	})

	expected := []string{
		"agent_machine.run",
		"--provider", "openrouter",
		"--timeout-ms", defaultRunTimeoutMS,
		"--max-steps", "2",
		"--max-attempts", "1",
		"--json",
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

	if result.selectedModel != "" {
		t.Fatalf("expected selected model to reset, got %q", result.selectedModel)
	}
}

func TestModelCommandSelectsLoadedModel(t *testing.T) {
	m := model{
		provider: providerOpenRouter,
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
		lastSummary: summary{
			Results: map[string]runResultSummary{
				"assistant": {Status: "error", Error: "provider rejected request", Attempt: 1},
			},
		},
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

func TestModelsReloadCommandStartsModelLoadingForRemoteProvider(t *testing.T) {
	t.Setenv("AGENT_MACHINE_TUI_CONFIG", filepath.Join(t.TempDir(), "config.json"))

	m, err := initialModel()
	if err != nil {
		t.Fatalf("expected initial model, got %v", err)
	}
	m.provider = providerOpenRouter

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
