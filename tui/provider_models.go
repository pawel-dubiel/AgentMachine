package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	openAIModelsURL     = "https://api.openai.com/v1/models"
	openRouterModelsURL = "https://openrouter.ai/api/v1/models"
)

var openAIPricingByModel = map[string]modelPricing{
	"gpt-4.1":       {InputPerMillion: 2.00, OutputPerMillion: 8.00},
	"gpt-4.1-mini":  {InputPerMillion: 0.40, OutputPerMillion: 1.60},
	"gpt-4.1-nano":  {InputPerMillion: 0.10, OutputPerMillion: 0.40},
	"gpt-4o":        {InputPerMillion: 2.50, OutputPerMillion: 10.00},
	"gpt-4o-mini":   {InputPerMillion: 0.15, OutputPerMillion: 0.60},
	"gpt-5.4":       {InputPerMillion: 2.50, OutputPerMillion: 15.00},
	"gpt-5.4-mini":  {InputPerMillion: 0.75, OutputPerMillion: 4.50},
	"gpt-5.4-nano":  {InputPerMillion: 0.20, OutputPerMillion: 1.25},
	"gpt-5.2":       {InputPerMillion: 1.75, OutputPerMillion: 14.00},
	"gpt-5.2-codex": {InputPerMillion: 1.75, OutputPerMillion: 14.00},
}

var providerModelLookup = fetchProviderModelOptions
var openRouterPricingLookup = fetchOpenRouterPricing

type modelPricing struct {
	InputPerMillion  float64
	OutputPerMillion float64
}

type modelOption struct {
	ID      string
	Pricing modelPricing
}

type modelListMsg struct {
	Provider provider
	Models   []modelOption
	Err      error
}

type openRouterModelsResponse struct {
	Data []openRouterModel `json:"data"`
}

type openRouterModel struct {
	ID      string            `json:"id"`
	Pricing openRouterPricing `json:"pricing"`
}

type openRouterPricing struct {
	Prompt     string `json:"prompt"`
	Completion string `json:"completion"`
}

type openAIModelsResponse struct {
	Data []openAIModel `json:"data"`
}

type openAIModel struct {
	ID string `json:"id"`
}

func loadModelsCommand(provider provider, apiKey string) tea.Cmd {
	return func() tea.Msg {
		models, err := providerModelLookup(provider, apiKey)
		return modelListMsg{Provider: provider, Models: models, Err: err}
	}
}

func fetchProviderModelOptions(provider provider, apiKey string) ([]modelOption, error) {
	switch provider {
	case providerOpenAI:
		return fetchOpenAIModelOptions(apiKey)
	case providerOpenRouter:
		return fetchOpenRouterModelOptions()
	default:
		return nil, fmt.Errorf("unsupported provider for model loading: %s", provider)
	}
}

func fetchOpenAIModelOptions(apiKey string) ([]modelOption, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, errors.New("OPENAI_API_KEY must not be empty to load OpenAI models")
	}

	request, err := http.NewRequest(http.MethodGet, openAIModelsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to build OpenAI models request: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)

	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch OpenAI models: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, fmt.Errorf("failed to fetch OpenAI models: HTTP %d", response.StatusCode)
	}

	var payload openAIModelsResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("failed to parse OpenAI models: %w", err)
	}

	options := openAIModelOptions(payload.Data)
	if len(options) == 0 {
		return nil, errors.New("OpenAI returned no models with known TUI pricing profiles")
	}
	return options, nil
}

func openAIModelOptions(models []openAIModel) []modelOption {
	options := make([]modelOption, 0, len(models))
	for _, model := range models {
		pricing, ok := openAIPricingByModel[model.ID]
		if ok {
			options = append(options, modelOption{ID: model.ID, Pricing: pricing})
		}
	}
	sortModelOptions(options)
	return options
}

func fetchOpenRouterModelOptions() ([]modelOption, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Get(openRouterModelsURL)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch OpenRouter models: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, fmt.Errorf("failed to fetch OpenRouter models: HTTP %d", response.StatusCode)
	}

	var payload openRouterModelsResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("failed to parse OpenRouter models: %w", err)
	}

	options := make([]modelOption, 0, len(payload.Data))
	for _, model := range payload.Data {
		pricing, err := openRouterModelPricing(model)
		if err == nil {
			options = append(options, modelOption{ID: model.ID, Pricing: pricing})
		}
	}
	sortModelOptions(options)
	if len(options) == 0 {
		return nil, errors.New("OpenRouter returned no models with usable pricing")
	}
	return options, nil
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

func fetchOpenRouterPricing(model string) (modelPricing, error) {
	if strings.TrimSpace(model) == "" {
		return modelPricing{}, errors.New("model must not be empty for remote providers")
	}

	models, err := fetchOpenRouterModelOptions()
	if err != nil {
		return modelPricing{}, err
	}
	for _, candidate := range models {
		if candidate.ID == model {
			return candidate.Pricing, nil
		}
	}
	return modelPricing{}, fmt.Errorf("no OpenRouter pricing found for model %q", model)
}

func openRouterModelPricing(model openRouterModel) (modelPricing, error) {
	inputPerToken, err := strconv.ParseFloat(model.Pricing.Prompt, 64)
	if err != nil {
		return modelPricing{}, fmt.Errorf("invalid OpenRouter prompt price for model %q", model.ID)
	}

	outputPerToken, err := strconv.ParseFloat(model.Pricing.Completion, 64)
	if err != nil {
		return modelPricing{}, fmt.Errorf("invalid OpenRouter completion price for model %q", model.ID)
	}

	return modelPricing{
		InputPerMillion:  inputPerToken * 1_000_000,
		OutputPerMillion: outputPerToken * 1_000_000,
	}, nil
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
