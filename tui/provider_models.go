package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

var providerModelLookup = fetchProviderModelOptions

type modelPricing struct {
	InputPerMillion  float64
	OutputPerMillion float64
}

type modelOption struct {
	ID                  string
	Pricing             modelPricing
	ContextWindowTokens int
}

type modelListMsg struct {
	Provider provider
	Models   []modelOption
	Err      error
}

type providerModelsResponse struct {
	Provider string                 `json:"provider"`
	Models   []providerModelPayload `json:"models"`
}

type providerModelPayload struct {
	ID                  string                  `json:"id"`
	Pricing             *providerPricingPayload `json:"pricing"`
	ContextWindowTokens *int                    `json:"context_window_tokens"`
}

type providerPricingPayload struct {
	InputPerMillion  float64 `json:"input_per_million"`
	OutputPerMillion float64 `json:"output_per_million"`
}

func loadModelsCommand(config runConfig) tea.Cmd {
	return func() tea.Msg {
		models, err := providerModelLookup(config)
		return modelListMsg{Provider: config.Provider, Models: models, Err: err}
	}
}

func fetchProviderModelOptions(config runConfig) ([]modelOption, error) {
	if config.Provider == providerEcho {
		return nil, errors.New("echo does not load remote models")
	}
	if err := validateProviderSetup(config); err != nil {
		return nil, err
	}

	root, err := projectRoot()
	if err != nil {
		return nil, err
	}

	args := []string{"agent_machine.providers", "models", "--json", "--provider", string(config.Provider)}
	for _, key := range sortedStringMapKeys(config.ProviderOptions) {
		value := config.ProviderOptions[key]
		args = append(args, "--provider-option", key+"="+value)
	}

	cmd := exec.Command("mix", args...)
	cmd.Dir = root
	cmd.Env = commandEnv(os.Environ(), config)

	output, err := cmd.CombinedOutput()
	raw := strings.TrimSpace(string(output))
	if err != nil {
		if raw != "" {
			return nil, fmt.Errorf("mix command failed: %w\n%s", err, raw)
		}
		return nil, fmt.Errorf("mix command failed: %w", err)
	}

	var payload providerModelsResponse
	if err := json.Unmarshal([]byte(lastJSONLine(raw)), &payload); err != nil {
		return nil, fmt.Errorf("failed to parse provider model list: %w", err)
	}
	options := providerModelOptions(payload.Models)
	if len(options) == 0 {
		return nil, fmt.Errorf("%s returned no models with usable pricing", config.Provider.Label())
	}
	return options, nil
}

func providerModelOptions(models []providerModelPayload) []modelOption {
	options := make([]modelOption, 0, len(models))
	for _, model := range models {
		if strings.TrimSpace(model.ID) == "" || model.Pricing == nil {
			continue
		}
		option := modelOption{
			ID: model.ID,
			Pricing: modelPricing{
				InputPerMillion:  model.Pricing.InputPerMillion,
				OutputPerMillion: model.Pricing.OutputPerMillion,
			},
		}
		if model.ContextWindowTokens != nil {
			option.ContextWindowTokens = *model.ContextWindowTokens
		}
		options = append(options, option)
	}
	sortModelOptions(options)
	return options
}

func sortModelOptions(options []modelOption) {
	sort.Slice(options, func(left int, right int) bool {
		return options[left].ID < options[right].ID
	})
}

func selectedModelIndex(models []modelOption, selected string) int {
	for index, model := range models {
		if model.ID == selected {
			return index
		}
	}
	return 0
}

func validateNonNegativeFloat(value string, label string) error {
	if value == "" {
		return fmt.Errorf("%s must not be empty", label)
	}

	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil || parsed < 0 {
		return fmt.Errorf("%s must be a non-negative number", label)
	}
	return nil
}

func validatePositiveInt(value string, label string) error {
	if value == "" {
		return fmt.Errorf("%s must not be empty", label)
	}

	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return fmt.Errorf("%s must be a positive integer", label)
	}
	return nil
}

func formatPrice(value float64) string {
	return strconv.FormatFloat(value, 'f', -1, 64)
}
