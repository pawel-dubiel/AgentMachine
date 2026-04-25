package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type summary struct {
	RunID       string                      `json:"run_id"`
	Status      string                      `json:"status"`
	Error       string                      `json:"error"`
	FinalOutput string                      `json:"final_output"`
	Results     map[string]runResultSummary `json:"results"`
	Usage       usageSummary                `json:"usage"`
	Events      []eventSummary              `json:"events"`
}

type runResultSummary struct {
	Status  string `json:"status"`
	Output  string `json:"output"`
	Error   string `json:"error"`
	Attempt int    `json:"attempt"`
}

type usageSummary struct {
	Agents       int     `json:"agents"`
	InputTokens  int     `json:"input_tokens"`
	OutputTokens int     `json:"output_tokens"`
	TotalTokens  int     `json:"total_tokens"`
	CostUSD      float64 `json:"cost_usd"`
}

type eventSummary struct {
	Type          string `json:"type"`
	RunID         string `json:"run_id"`
	AgentID       string `json:"agent_id"`
	ParentAgentID string `json:"parent_agent_id"`
	Status        string `json:"status"`
	Attempt       int    `json:"attempt"`
	NextAttempt   int    `json:"next_attempt"`
	DurationMS    *int   `json:"duration_ms"`
	Reason        string `json:"reason"`
	At            string `json:"at"`
}

type runResultMsg struct {
	Summary summary
	Raw     string
	Err     error
}

type streamStartedMsg struct {
	Session *streamSession
}

type streamLineMsg struct {
	Session *streamSession
	Line    string
}

type streamDoneMsg struct {
	Session *streamSession
	Err     error
}

type jsonlEnvelope struct {
	Type    string          `json:"type"`
	Event   eventSummary    `json:"event"`
	Summary summary         `json:"summary"`
	Raw     json.RawMessage `json:"-"`
}

type agentState struct {
	ID            string
	ParentAgentID string
	Status        string
	Attempt       int
	Output        string
	Error         string
	StartedAt     string
	FinishedAt    string
	DurationMS    *int
	Events        []eventSummary
}

type provider string

const (
	providerEcho       provider = "echo"
	providerOpenAI     provider = "openai"
	providerOpenRouter provider = "openrouter"
)

var providers = []provider{providerEcho, providerOpenAI, providerOpenRouter}

type runWorkflow string

const (
	workflowBasic   runWorkflow = "basic"
	workflowAgentic runWorkflow = "agentic"
)

const (
	defaultRunTimeoutMS  = "30000"
	defaultBasicSteps    = "2"
	defaultAgenticSteps  = "6"
	defaultHTTPTimeoutMS = "25000"
)

type runConfig struct {
	Task        string
	Workflow    runWorkflow
	Provider    provider
	APIKey      string
	Model       string
	InputPrice  string
	OutputPrice string
	HTTPTimeout string
}

type savedConfig struct {
	OpenAIAPIKey     string `json:"openai_api_key,omitempty"`
	OpenRouterAPIKey string `json:"openrouter_api_key,omitempty"`
}

type chatMessage struct {
	Role string
	Text string
}

type viewMode int

const (
	viewChat viewMode = iota
	viewSetup
	viewSettings
	viewAgents
	viewAgentDetail
	viewHelp
)

type model struct {
	input              textinput.Model
	workflow           runWorkflow
	workflowSet        bool
	provider           provider
	providerSet        bool
	savedConfig        savedConfig
	configPath         string
	modelOptions       []modelOption
	modelIndex         int
	selectedModel      string
	modelStatus        string
	modelPickerOpen    bool
	modelPickerIndex   int
	modelPickerPending bool
	modelPickerQuery   string
	messages           []chatMessage
	inputHistory       []string
	historyIndex       int
	historyDraft       string
	view               viewMode
	selectedAgent      string
	selectedAgentIndex int
	running            bool
	activeConfig       runConfig
	lastSummary        summary
	agents             map[string]agentState
	agentOrder         []string
	raw                string
	stream             *streamSession
}

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("63"))
	labelStyle = lipgloss.NewStyle().Bold(true)
	errorStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
	hintStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

func initialModel() (model, error) {
	configPath, err := tuiConfigPath()
	if err != nil {
		return model{}, err
	}

	savedConfig, err := loadSavedConfig(configPath)
	if err != nil {
		return model{}, err
	}

	input := textinput.New()
	input.Placeholder = "Message or /help"
	input.CharLimit = 1000
	input.Width = 96
	input.Focus()

	return model{
		input:       input,
		savedConfig: savedConfig,
		configPath:  configPath,
		messages: []chatMessage{
			{Role: "system", Text: "Open Setup and select a workflow and provider before running AgentMachine."},
		},
		view:   viewSetup,
		agents: map[string]agentState{},
	}, nil
}

func (m model) Init() tea.Cmd {
	return textinput.Blink
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return m, tea.Quit
		}

		if m.modelPickerOpen {
			switch msg.String() {
			case "esc":
				m.modelPickerOpen = false
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "model picker canceled"})
				return m, nil
			case "up":
				m.moveModelPicker(-1)
				return m, nil
			case "down":
				m.moveModelPicker(1)
				return m, nil
			case "enter":
				return m.selectModelFromPicker()
			case "backspace", "ctrl+h":
				m.removeLastModelPickerQueryRune()
				return m, nil
			case "delete", "ctrl+u":
				m.setModelPickerQuery("")
				return m, nil
			}
			if len(msg.Runes) > 0 {
				m.setModelPickerQuery(m.modelPickerQuery + string(msg.Runes))
				return m, nil
			}
			return m, nil
		}

		switch msg.String() {
		case "tab":
			m.nextView()
			return m, nil
		case "shift+tab":
			m.previousView()
			return m, nil
		case "esc":
			m.back()
			return m, nil
		case "up", "k":
			if m.view == viewAgents {
				m.moveAgentSelection(-1)
				return m, nil
			}
			if msg.String() == "up" && !m.running && m.canUseInputHistory() {
				m.previousHistory()
				return m, nil
			}
		case "down", "j":
			if m.view == viewAgents {
				m.moveAgentSelection(1)
				return m, nil
			}
			if msg.String() == "down" && !m.running && m.canUseInputHistory() {
				m.nextHistory()
				return m, nil
			}
		case "enter":
			if m.view == viewAgents {
				return m.openSelectedAgent()
			}
			if m.view == viewAgentDetail {
				m.back()
				return m, nil
			}
			if !m.running {
				return m.submitInput()
			}
			return m, nil
		}

	case runResultMsg:
		m.running = false
		m.lastSummary = msg.Summary
		m.raw = msg.Raw
		m.view = viewChat

		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\n" + msg.Err.Error()})
		} else {
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: emptyAsNone(msg.Summary.FinalOutput)})
		}
		return m, nil

	case streamStartedMsg:
		m.stream = msg.Session
		return m, readStreamCommand(msg.Session)

	case streamLineMsg:
		if msg.Session != m.stream {
			return m, nil
		}
		var cmd tea.Cmd
		m, cmd = m.handleStreamLine(msg.Line)
		if cmd != nil {
			return m, cmd
		}
		return m, readStreamCommand(msg.Session)

	case streamDoneMsg:
		if msg.Session != m.stream {
			return m, nil
		}
		m.stream = nil
		m.running = false
		m.view = viewChat
		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\n" + msg.Err.Error()})
		} else if strings.TrimSpace(m.lastSummary.FinalOutput) != "" || m.lastSummary.Status != "" {
			if m.lastSummary.Status == "failed" {
				m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\n" + summaryError(m.lastSummary)})
			} else {
				m.messages = append(m.messages, chatMessage{Role: "assistant", Text: emptyAsNone(m.lastSummary.FinalOutput)})
			}
		} else {
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\nAgentMachine stream ended without a summary"})
		}
		return m, nil

	case modelListMsg:
		if msg.Provider != m.provider {
			return m, nil
		}

		if msg.Err != nil {
			m.modelOptions = nil
			m.modelIndex = 0
			m.modelPickerIndex = 0
			m.modelPickerOpen = false
			m.modelPickerPending = false
			m.modelPickerQuery = ""
			m.modelStatus = "model load failed: " + msg.Err.Error()
			m.messages = append(m.messages, chatMessage{Role: "system", Text: m.modelStatus})
			return m, nil
		}

		m.modelOptions = msg.Models
		m.modelIndex = selectedModelIndex(msg.Models, m.selectedModel)
		if len(msg.Models) > 0 {
			m.selectedModel = msg.Models[m.modelIndex].ID
			m.modelPickerIndex = m.modelIndex
		}
		m.modelStatus = fmt.Sprintf("loaded %d models", len(msg.Models))
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.modelStatus + " for " + m.provider.Label()})
		if m.modelPickerPending {
			m.modelPickerOpen = len(m.modelOptions) > 0
			m.modelPickerPending = false
		}
		return m, nil
	}

	if !m.running && m.view != viewAgents && m.view != viewAgentDetail && !m.modelPickerOpen {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}

	return m, nil
}

func (m model) submitInput() (tea.Model, tea.Cmd) {
	text := strings.TrimSpace(m.input.Value())
	if text == "" {
		return m, nil
	}

	m.rememberInput(text)
	m.input.SetValue("")
	m.historyIndex = len(m.inputHistory)
	m.historyDraft = ""

	if strings.HasPrefix(text, "/") {
		return m.handleCommand(text)
	}

	return m.startRun(text)
}

func (m model) startRun(task string) (tea.Model, tea.Cmd) {
	if !m.workflowSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a workflow in Setup before running"})
		m.view = viewSetup
		return m, nil
	}

	if !m.providerSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider in Setup before running"})
		m.view = viewSetup
		return m, nil
	}

	config, err := resolveConfig(m.runConfig(task))
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		m.view = viewSetup
		return m, nil
	}

	if err := validateConfig(config); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		m.view = viewSetup
		return m, nil
	}

	m.rememberAPIKey(config.Provider, config.APIKey)
	if config.Provider != providerEcho {
		if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
	}

	m.messages = append(m.messages,
		chatMessage{Role: "user", Text: task},
		chatMessage{Role: "system", Text: "running " + config.Provider.Label() + " / " + config.Model + "..."},
	)
	m.running = true
	m.view = viewChat
	m.activeConfig = config
	m.lastSummary = summary{}
	m.raw = ""
	m.agents = map[string]agentState{}
	m.agentOrder = nil
	m.selectedAgent = ""
	m.selectedAgentIndex = 0
	return m, startStreamingCommand(config)
}

func (m model) handleCommand(command string) (tea.Model, tea.Cmd) {
	parts := strings.Fields(command)
	name := strings.TrimPrefix(parts[0], "/")
	args := parts[1:]

	switch name {
	case "help":
		m.view = viewHelp
	case "setup":
		m.view = viewSetup
	case "workflow":
		return m.handleWorkflowCommand(args)
	case "provider":
		return m.handleProviderCommand(args)
	case "key":
		return m.handleKeyCommand(args)
	case "models":
		return m.handleModelsCommand(args)
	case "model":
		return m.handleModelCommand(args)
	case "settings":
		m.view = viewSetup
	case "agents":
		m.view = viewAgents
	case "agent":
		return m.handleAgentCommand(args)
	case "back":
		m.back()
	case "clear":
		m.messages = nil
		m.view = viewChat
	case "quit", "q":
		return m, tea.Quit
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown command: /" + name})
	}

	return m, nil
}

func (m model) handleWorkflowCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		if !m.workflowSet {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "workflow: (missing)"})
			return m, nil
		}
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "workflow: " + string(m.workflow)})
		return m, nil
	}
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /workflow basic|agentic"})
		return m, nil
	}

	nextWorkflow, err := parseWorkflow(args[0])
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.workflow = nextWorkflow
	m.workflowSet = true
	m.view = viewChat
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "workflow set to " + string(m.workflow)})
	return m, nil
}

func (m model) handleProviderCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider: " + string(m.provider)})
		return m, nil
	}
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /provider echo|openai|openrouter"})
		return m, nil
	}

	nextProvider, err := parseProvider(args[0])
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.provider = nextProvider
	m.providerSet = true
	m.modelOptions = nil
	m.modelIndex = 0
	m.selectedModel = ""
	m.modelStatus = ""
	m.modelPickerOpen = false
	m.modelPickerPending = false
	m.modelPickerQuery = ""
	m.view = viewChat
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider set to " + m.provider.Label()})

	if m.provider != providerEcho {
		return m, m.loadModelsCommand()
	}
	return m, nil
}

func (m model) handleKeyCommand(args []string) (tea.Model, tea.Cmd) {
	if !m.providerSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider before saving an API key"})
		m.view = viewSetup
		return m, nil
	}
	if m.provider == providerEcho {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "Echo does not use an API key"})
		return m, nil
	}
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /key <api-key>"})
		return m, nil
	}

	m.rememberAPIKey(m.provider, strings.Join(args, " "))
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.messages = append(m.messages, chatMessage{Role: "system", Text: "saved " + apiKeyName(m.provider)})
	return m, m.loadModelsCommand()
}

func (m model) handleModelsCommand(args []string) (tea.Model, tea.Cmd) {
	if !m.providerSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider before loading models"})
		m.view = viewSetup
		return m, nil
	}
	if m.provider == providerEcho {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "Echo has one built-in model: echo"})
		return m, nil
	}

	if len(args) > 0 && args[0] == "reload" {
		m.modelStatus = "loading models..."
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "loading models for " + m.provider.Label() + "..."})
		return m, m.loadModelsCommand()
	}

	if len(m.modelOptions) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no models loaded; use /models reload"})
		return m, nil
	}

	m.messages = append(m.messages, chatMessage{Role: "system", Text: modelListText(m.modelOptions, m.modelIndex)})
	return m, nil
}

func (m model) handleModelCommand(args []string) (tea.Model, tea.Cmd) {
	if !m.providerSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider before choosing a model"})
		m.view = viewSetup
		return m, nil
	}
	if m.provider == providerEcho {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "model: echo"})
		return m, nil
	}
	if len(args) == 0 {
		if len(m.modelOptions) == 0 {
			m.modelPickerPending = true
			m.modelPickerQuery = ""
			m.modelStatus = "loading models..."
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "loading models for " + m.provider.Label() + "..."})
			return m, m.loadModelsCommand()
		}
		m.view = viewChat
		m.modelPickerOpen = true
		m.modelPickerIndex = m.modelIndex
		m.modelPickerQuery = ""
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "open model picker, use Up/Down and Enter to select"})
		return m, nil
	}
	if len(m.modelOptions) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "load models first with /models reload"})
		return m, nil
	}

	switch args[0] {
	case "next":
		m.changeModel(1)
	case "prev", "previous":
		m.changeModel(-1)
	default:
		index := selectedModelIndex(m.modelOptions, args[0])
		if m.modelOptions[index].ID != args[0] {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown loaded model: " + args[0]})
			return m, nil
		}
		m.modelIndex = index
		m.selectedModel = m.modelOptions[index].ID
	}

	m.messages = append(m.messages, chatMessage{Role: "system", Text: "model set to " + m.selectedModel})
	return m, nil
}

func (m model) selectModelFromPicker() (tea.Model, tea.Cmd) {
	if len(m.modelOptions) == 0 {
		m.modelPickerOpen = false
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no models available"})
		return m, nil
	}
	if len(m.filteredModelIndexes()) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no model matches " + m.modelPickerQuery})
		return m, nil
	}
	if m.modelPickerIndex < 0 || m.modelPickerIndex >= len(m.modelOptions) {
		m.modelPickerIndex = 0
	}
	m.modelIndex = m.modelPickerIndex
	m.selectedModel = m.modelOptions[m.modelIndex].ID
	m.modelPickerOpen = false
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "model set to " + m.selectedModel})
	return m, nil
}

func (m model) handleAgentCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /agent <id>"})
		return m, nil
	}
	if len(m.agents) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no run results yet"})
		return m, nil
	}
	if _, ok := m.agents[args[0]]; !ok {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown agent: " + args[0]})
		return m, nil
	}

	m.selectedAgent = args[0]
	m.view = viewAgentDetail
	return m, nil
}

func (m model) handleStreamLine(line string) (model, tea.Cmd) {
	envelope, ok, err := parseJSONLLine(line)
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if !ok {
		return m, nil
	}

	switch envelope.Type {
	case "event":
		m.applyEvent(envelope.Event)
	case "summary":
		m.lastSummary = envelope.Summary
		m.raw = line
		m.applySummaryResults(envelope.Summary)
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown JSONL message type: " + envelope.Type})
	}

	return m, nil
}

func (m *model) applyEvent(event eventSummary) {
	if event.AgentID == "" {
		return
	}

	agent := m.agents[event.AgentID]
	if agent.ID == "" {
		agent.ID = event.AgentID
		agent.ParentAgentID = event.ParentAgentID
		m.agentOrder = append(m.agentOrder, event.AgentID)
	}
	if event.ParentAgentID != "" {
		agent.ParentAgentID = event.ParentAgentID
	}
	if event.Attempt > 0 {
		agent.Attempt = event.Attempt
	}
	if event.NextAttempt > 0 {
		agent.Attempt = event.NextAttempt
	}

	switch event.Type {
	case "agent_started":
		agent.Status = "running"
		agent.StartedAt = event.At
	case "agent_finished":
		agent.Status = emptyAs(event.Status, "done")
		agent.FinishedAt = event.At
		agent.DurationMS = event.DurationMS
	case "agent_retry_scheduled":
		agent.Status = "retrying"
		agent.Error = event.Reason
	}

	agent.Events = append(agent.Events, event)
	m.agents[event.AgentID] = agent
}

func (m *model) applySummaryResults(summary summary) {
	for id, result := range summary.Results {
		agent := m.agents[id]
		if agent.ID == "" {
			agent.ID = id
			m.agentOrder = append(m.agentOrder, id)
		}
		agent.Status = result.Status
		agent.Attempt = result.Attempt
		agent.Output = result.Output
		agent.Error = result.Error
		m.agents[id] = agent
	}
}

func (m model) runConfig(task string) runConfig {
	config := runConfig{
		Task:     task,
		Workflow: m.workflow,
		Provider: m.provider,
		APIKey:   m.apiKey(),
		Model:    m.modelID(),
	}

	if pricing, ok := m.selectedModelPricing(config.Model); ok {
		config.InputPrice = formatPrice(pricing.InputPerMillion)
		config.OutputPrice = formatPrice(pricing.OutputPerMillion)
		config.HTTPTimeout = defaultHTTPTimeoutMS
	}

	return config
}

func (m model) modelID() string {
	if !m.providerSet {
		return ""
	}
	if m.provider == providerEcho {
		return "echo"
	}
	return strings.TrimSpace(m.selectedModel)
}

func (m model) apiKey() string {
	if !m.providerSet {
		return ""
	}
	return m.savedConfig.apiKeyFor(m.provider)
}

func (m model) selectedModelPricing(modelID string) (modelPricing, bool) {
	for _, option := range m.modelOptions {
		if option.ID == modelID {
			return option.Pricing, true
		}
	}
	return modelPricing{}, false
}

func (m *model) rememberAPIKey(provider provider, apiKey string) {
	switch provider {
	case providerOpenAI:
		m.savedConfig.OpenAIAPIKey = apiKey
	case providerOpenRouter:
		m.savedConfig.OpenRouterAPIKey = apiKey
	}
}

func (m *model) changeModel(delta int) {
	if len(m.modelOptions) == 0 {
		return
	}
	m.modelIndex = (m.modelIndex + delta + len(m.modelOptions)) % len(m.modelOptions)
	m.selectedModel = m.modelOptions[m.modelIndex].ID
}

func (m *model) moveModelPicker(delta int) {
	indexes := m.filteredModelIndexes()
	if len(indexes) == 0 {
		m.modelPickerIndex = 0
		return
	}
	position := 0
	for index, modelIndex := range indexes {
		if modelIndex == m.modelPickerIndex {
			position = index
			break
		}
	}
	position = (position + delta + len(indexes)) % len(indexes)
	m.modelPickerIndex = indexes[position]
}

func (m *model) setModelPickerQuery(query string) {
	m.modelPickerQuery = query
	m.ensureModelPickerSelectionVisible()
}

func (m *model) removeLastModelPickerQueryRune() {
	runes := []rune(m.modelPickerQuery)
	if len(runes) == 0 {
		return
	}
	m.setModelPickerQuery(string(runes[:len(runes)-1]))
}

func (m *model) ensureModelPickerSelectionVisible() {
	indexes := m.filteredModelIndexes()
	if len(indexes) == 0 {
		m.modelPickerIndex = 0
		return
	}
	for _, index := range indexes {
		if index == m.modelPickerIndex {
			return
		}
	}
	m.modelPickerIndex = indexes[0]
}

func (m model) filteredModelIndexes() []int {
	query := strings.ToLower(strings.TrimSpace(m.modelPickerQuery))
	indexes := make([]int, 0, len(m.modelOptions))
	for index, option := range m.modelOptions {
		if query == "" || strings.Contains(strings.ToLower(option.ID), query) {
			indexes = append(indexes, index)
		}
	}
	return indexes
}

func (m model) loadModelsCommand() tea.Cmd {
	if m.provider == providerEcho {
		return nil
	}
	return loadModelsCommand(m.provider, m.apiKey())
}

func validateConfig(config runConfig) error {
	if config.Task == "" {
		return errors.New("task must not be empty")
	}
	if config.Workflow == "" {
		return errors.New("workflow must not be empty")
	}
	if _, err := parseWorkflow(string(config.Workflow)); err != nil {
		return err
	}

	switch config.Provider {
	case providerEcho:
		return nil
	case providerOpenAI, providerOpenRouter:
		if config.Model == "" {
			return errors.New("model must not be empty for remote providers")
		}
		if config.APIKey == "" {
			return fmt.Errorf("%s must not be empty", apiKeyName(config.Provider))
		}
		if config.InputPrice == "" {
			return fmt.Errorf("input pricing is missing for model %q", config.Model)
		}
		if config.OutputPrice == "" {
			return fmt.Errorf("output pricing is missing for model %q", config.Model)
		}
		if config.HTTPTimeout == "" {
			return errors.New("HTTP timeout is missing")
		}
		if err := validateNonNegativeFloat(config.InputPrice, "input price per million"); err != nil {
			return err
		}
		if err := validateNonNegativeFloat(config.OutputPrice, "output price per million"); err != nil {
			return err
		}
		if err := validatePositiveInt(config.HTTPTimeout, "HTTP timeout ms"); err != nil {
			return err
		}
		return nil
	default:
		return fmt.Errorf("unsupported provider: %s", config.Provider)
	}
}

func resolveConfig(config runConfig) (runConfig, error) {
	switch config.Provider {
	case providerEcho:
		config.Model = "echo"
		config.InputPrice = "0"
		config.OutputPrice = "0"
		config.HTTPTimeout = defaultHTTPTimeoutMS
		return config, nil
	case providerOpenAI:
		if err := requireRemoteIdentity(config); err != nil {
			return runConfig{}, err
		}
		if hasResolvedRuntimeOptions(config) {
			return config, nil
		}
		pricing, ok := openAIPricingByModel[config.Model]
		if !ok {
			return runConfig{}, fmt.Errorf("no OpenAI pricing profile for model %q", config.Model)
		}
		return applyResolvedPricing(config, pricing), nil
	case providerOpenRouter:
		if err := requireRemoteIdentity(config); err != nil {
			return runConfig{}, err
		}
		if hasResolvedRuntimeOptions(config) {
			return config, nil
		}
		pricing, err := openRouterPricingLookup(config.Model)
		if err != nil {
			return runConfig{}, err
		}
		return applyResolvedPricing(config, pricing), nil
	default:
		return runConfig{}, fmt.Errorf("unsupported provider: %s", config.Provider)
	}
}

func hasResolvedRuntimeOptions(config runConfig) bool {
	return config.InputPrice != "" && config.OutputPrice != "" && config.HTTPTimeout != ""
}

func requireRemoteIdentity(config runConfig) error {
	if config.Model == "" {
		return errors.New("model must not be empty for remote providers")
	}
	if config.APIKey == "" {
		return fmt.Errorf("%s must not be empty", apiKeyName(config.Provider))
	}
	return nil
}

func applyResolvedPricing(config runConfig, pricing modelPricing) runConfig {
	config.InputPrice = formatPrice(pricing.InputPerMillion)
	config.OutputPrice = formatPrice(pricing.OutputPerMillion)
	config.HTTPTimeout = defaultHTTPTimeoutMS
	return config
}

func parseProvider(value string) (provider, error) {
	switch strings.ToLower(value) {
	case "echo":
		return providerEcho, nil
	case "openai", "chatgpt", "gpt":
		return providerOpenAI, nil
	case "openrouter":
		return providerOpenRouter, nil
	default:
		return "", fmt.Errorf("unsupported provider: %s", value)
	}
}

func parseWorkflow(value string) (runWorkflow, error) {
	switch strings.ToLower(value) {
	case "basic":
		return workflowBasic, nil
	case "agentic":
		return workflowAgentic, nil
	default:
		return "", fmt.Errorf("unsupported workflow: %s", value)
	}
}

func (p provider) Label() string {
	switch p {
	case providerEcho:
		return "Echo"
	case providerOpenAI:
		return "OpenAI"
	case providerOpenRouter:
		return "OpenRouter"
	default:
		return string(p)
	}
}

func apiKeyName(provider provider) string {
	switch provider {
	case providerOpenAI:
		return "OPENAI_API_KEY"
	case providerOpenRouter:
		return "OPENROUTER_API_KEY"
	default:
		return ""
	}
}

func keyStatus(apiKey string) string {
	if strings.TrimSpace(apiKey) == "" {
		return "missing"
	}
	return "saved"
}

func (config savedConfig) apiKeyFor(provider provider) string {
	switch provider {
	case providerOpenAI:
		return config.OpenAIAPIKey
	case providerOpenRouter:
		return config.OpenRouterAPIKey
	default:
		return ""
	}
}

func summaryError(summary summary) string {
	if strings.TrimSpace(summary.Error) != "" {
		return summary.Error
	}

	errorsByAgent := make([]string, 0, len(summary.Results))
	for agentID, result := range summary.Results {
		if result.Status == "error" {
			errorsByAgent = append(errorsByAgent, agentID+": "+emptyAsUnknown(result.Error))
		}
	}
	sort.Strings(errorsByAgent)
	if len(errorsByAgent) == 0 {
		return "unknown error"
	}
	return strings.Join(errorsByAgent, "\n")
}

func (m model) visibleAgentIDs() []string {
	seen := map[string]bool{}
	ordered := make([]string, 0, len(m.agentOrder))

	var appendWithChildren func(string)
	appendWithChildren = func(id string) {
		if seen[id] {
			return
		}
		seen[id] = true
		ordered = append(ordered, id)
		for _, childID := range m.agentOrder {
			if m.agents[childID].ParentAgentID == id {
				appendWithChildren(childID)
			}
		}
	}

	for _, id := range m.agentOrder {
		if m.agents[id].ParentAgentID == "" {
			appendWithChildren(id)
		}
	}
	for _, id := range m.agentOrder {
		appendWithChildren(id)
	}
	return ordered
}

func (m model) agentTreeLine(agent agentState) string {
	depth := m.agentDepth(agent.ID)
	indent := strings.Repeat("  ", depth)
	status := emptyAs(agent.Status, "pending")
	attempt := agent.Attempt
	if attempt == 0 {
		attempt = 1
	}
	return fmt.Sprintf("%s%s  %s  attempt %d", indent, agent.ID, status, attempt)
}

func (m model) agentDepth(id string) int {
	depth := 0
	parentID := m.agents[id].ParentAgentID
	for parentID != "" {
		depth++
		parentID = m.agents[parentID].ParentAgentID
	}
	return depth
}

func (m *model) moveAgentSelection(delta int) {
	visible := m.visibleAgentIDs()
	if len(visible) == 0 {
		m.selectedAgentIndex = 0
		return
	}
	m.selectedAgentIndex = (m.selectedAgentIndex + delta + len(visible)) % len(visible)
}

func (m model) canUseInputHistory() bool {
	return m.view != viewAgents && m.view != viewAgentDetail
}

func (m *model) rememberInput(value string) {
	if strings.TrimSpace(value) == "" {
		return
	}
	if len(m.inputHistory) > 0 && m.inputHistory[len(m.inputHistory)-1] == value {
		return
	}
	m.inputHistory = append(m.inputHistory, value)
}

func (m *model) previousHistory() {
	if len(m.inputHistory) == 0 {
		return
	}
	if m.historyIndex == len(m.inputHistory) {
		m.historyDraft = m.input.Value()
	}
	if m.historyIndex > 0 {
		m.historyIndex--
	}
	m.input.SetValue(m.inputHistory[m.historyIndex])
	m.input.CursorEnd()
}

func (m *model) nextHistory() {
	if len(m.inputHistory) == 0 {
		return
	}
	if m.historyIndex < len(m.inputHistory) {
		m.historyIndex++
	}
	if m.historyIndex == len(m.inputHistory) {
		m.input.SetValue(m.historyDraft)
	} else {
		m.input.SetValue(m.inputHistory[m.historyIndex])
	}
	m.input.CursorEnd()
}

func (m model) openSelectedAgent() (tea.Model, tea.Cmd) {
	visible := m.visibleAgentIDs()
	if len(visible) == 0 {
		return m, nil
	}
	if m.selectedAgentIndex >= len(visible) {
		m.selectedAgentIndex = len(visible) - 1
	}
	m.selectedAgent = visible[m.selectedAgentIndex]
	m.view = viewAgentDetail
	return m, nil
}

func (m *model) nextView() {
	switch m.view {
	case viewSetup:
		m.view = viewChat
	case viewChat:
		m.view = viewAgents
	case viewAgents:
		m.view = viewHelp
	default:
		m.view = viewSetup
	}
}

func (m *model) previousView() {
	switch m.view {
	case viewSetup:
		m.view = viewHelp
	case viewHelp:
		m.view = viewAgents
	case viewAgents:
		m.view = viewChat
	default:
		m.view = viewSetup
	}
}

func (m *model) back() {
	switch m.view {
	case viewAgentDetail:
		m.view = viewAgents
	case viewAgents, viewHelp, viewSetup, viewSettings:
		m.view = viewChat
	default:
		m.view = viewChat
	}
	if m.view != viewAgentDetail {
		m.selectedAgent = ""
	}
}

func (m model) viewName() string {
	switch m.view {
	case viewSetup:
		return "setup"
	case viewSettings:
		return "setup"
	case viewAgents:
		return "agents"
	case viewAgentDetail:
		return "agent"
	case viewHelp:
		return "help"
	default:
		return "chat"
	}
}

func main() {
	model, err := initialModel()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	program := tea.NewProgram(model)
	if _, err := program.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
