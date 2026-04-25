package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

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

type streamSession struct {
	cmd     *exec.Cmd
	scanner *bufio.Scanner
	stderr  *bytes.Buffer
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

const (
	defaultRunTimeoutMS  = "30000"
	defaultHTTPTimeoutMS = "25000"
	openAIModelsURL      = "https://api.openai.com/v1/models"
	openRouterModelsURL  = "https://openrouter.ai/api/v1/models"
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

type runConfig struct {
	Task        string
	Provider    provider
	APIKey      string
	Model       string
	InputPrice  string
	OutputPrice string
	HTTPTimeout string
}

type modelPricing struct {
	InputPerMillion  float64
	OutputPerMillion float64
}

type modelOption struct {
	ID      string
	Pricing modelPricing
}

type savedConfig struct {
	OpenAIAPIKey     string `json:"openai_api_key,omitempty"`
	OpenRouterAPIKey string `json:"openrouter_api_key,omitempty"`
}

type modelListMsg struct {
	Provider provider
	Models   []modelOption
	Err      error
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
	provider           provider
	providerSet        bool
	savedConfig        savedConfig
	configPath         string
	modelOptions       []modelOption
	modelIndex         int
	selectedModel      string
	modelStatus        string
	messages           []chatMessage
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
			{Role: "system", Text: "Open Setup and select a provider before running AgentMachine."},
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
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
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
		case "down", "j":
			if m.view == viewAgents {
				m.moveAgentSelection(1)
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
			m.modelStatus = "model load failed: " + msg.Err.Error()
			m.messages = append(m.messages, chatMessage{Role: "system", Text: m.modelStatus})
			return m, nil
		}

		m.modelOptions = msg.Models
		m.modelIndex = selectedModelIndex(msg.Models, m.selectedModel)
		if len(msg.Models) > 0 {
			m.selectedModel = msg.Models[m.modelIndex].ID
		}
		m.modelStatus = fmt.Sprintf("loaded %d models", len(msg.Models))
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.modelStatus + " for " + m.provider.Label()})
		return m, nil
	}

	if !m.running && m.view != viewAgents && m.view != viewAgentDetail {
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

	m.input.SetValue("")

	if strings.HasPrefix(text, "/") {
		return m.handleCommand(text)
	}

	return m.startRun(text)
}

func (m model) startRun(task string) (tea.Model, tea.Cmd) {
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
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "model: " + emptyAsNone(m.selectedModel)})
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

func (m model) loadModelsCommand() tea.Cmd {
	if m.provider == providerEcho {
		return nil
	}
	return loadModelsCommand(m.provider, m.apiKey())
}

func (m model) View() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("AgentMachine TUI"))
	b.WriteString("\n")
	b.WriteString(hintStyle.Render(m.statusLine()))
	b.WriteString("\n\n")

	switch m.view {
	case viewSetup:
		b.WriteString(m.setupView())
	case viewSettings:
		b.WriteString(m.setupView())
	case viewAgents:
		b.WriteString(m.agentsView())
	case viewAgentDetail:
		b.WriteString(m.agentDetailView())
	case viewHelp:
		b.WriteString(m.helpView())
	default:
		b.WriteString(m.chatView())
	}

	b.WriteString("\n\n")
	if m.running {
		b.WriteString(hintStyle.Render("Running. Tab navigates; Agents shows live agent state."))
	} else {
		b.WriteString("> ")
		b.WriteString(m.input.View())
		b.WriteString("\n")
		b.WriteString(hintStyle.Render("Type a message or /help. Tab changes view. Esc goes back."))
	}
	return b.String()
}

func (m model) statusLine() string {
	parts := []string{"view=" + m.viewName()}
	if !m.providerSet {
		parts = append(parts, "provider=missing")
		return strings.Join(parts, " | ")
	}
	parts = append(parts, "provider="+string(m.provider))
	if m.provider != providerEcho {
		parts = append(parts, "model="+emptyAsNone(m.selectedModel))
		parts = append(parts, apiKeyName(m.provider)+"="+keyStatus(m.apiKey()))
	}
	if m.running {
		parts = append(parts, "run=running")
	}
	if m.modelStatus != "" {
		parts = append(parts, "models="+m.modelStatus)
	}
	return strings.Join(parts, " | ")
}

func (m model) chatView() string {
	if len(m.messages) == 0 {
		return hintStyle.Render("No messages yet.")
	}

	start := len(m.messages) - 14
	if start < 0 {
		start = 0
	}

	var b strings.Builder
	for _, message := range m.messages[start:] {
		b.WriteString(labelStyle.Render(message.Role))
		b.WriteString(": ")
		if message.Role == "assistant" && strings.HasPrefix(message.Text, "Run failed:") {
			b.WriteString(errorStyle.Render(message.Text))
		} else {
			b.WriteString(message.Text)
		}
		b.WriteString("\n\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func (m model) setupView() string {
	providerValue := "(missing)"
	if m.providerSet {
		providerValue = string(m.provider)
	}

	return strings.Join([]string{
		labelStyle.Render("Setup"),
		"provider: " + providerValue,
		"model: " + emptyAsNone(m.modelID()),
		"key: " + keyStatus(m.apiKey()),
		"config: " + m.configPath,
		"run timeout ms: " + defaultRunTimeoutMS,
		"HTTP timeout ms: " + defaultHTTPTimeoutMS,
		"",
		"Commands",
		"/provider echo|openai|openrouter",
		"/key <api-key>",
		"/models reload",
		"/model <id|next|prev>",
		"/back",
	}, "\n")
}

func (m model) agentsView() string {
	if len(m.agentOrder) == 0 {
		return "No agents yet. Send a message after setup."
	}

	lines := []string{labelStyle.Render("Agents")}
	visible := m.visibleAgentIDs()
	for index, id := range visible {
		agent := m.agents[id]
		prefix := "  "
		if index == m.selectedAgentIndex {
			prefix = "> "
		}
		lines = append(lines, prefix+m.agentTreeLine(agent))
	}
	lines = append(lines, "", "Enter opens selected agent. Use /agent <id>, Tab, Esc, or /back.")
	return strings.Join(lines, "\n")
}

func (m model) agentDetailView() string {
	agent, ok := m.agents[m.selectedAgent]
	if !ok {
		return "No selected agent. Use /agents."
	}

	duration := "(none)"
	if agent.DurationMS != nil {
		duration = fmt.Sprintf("%dms", *agent.DurationMS)
	}

	return strings.Join([]string{
		labelStyle.Render("Agent " + m.selectedAgent),
		"status: " + emptyAsNone(agent.Status),
		fmt.Sprintf("attempt: %d", agent.Attempt),
		"parent: " + emptyAsNone(agent.ParentAgentID),
		"started: " + emptyAsNone(agent.StartedAt),
		"finished: " + emptyAsNone(agent.FinishedAt),
		"duration: " + duration,
		"",
		labelStyle.Render("Output"),
		emptyAsNone(agent.Output),
		"",
		labelStyle.Render("Error"),
		emptyAsNone(agent.Error),
		"",
		labelStyle.Render("Events"),
		agentEventLines(agent.Events),
		"",
		"Esc or /back",
	}, "\n")
}

func (m model) helpView() string {
	return helpText()
}

func runCommand(config runConfig) tea.Cmd {
	return func() tea.Msg {
		summary, raw, err := runAgentMachine(config)
		return runResultMsg{Summary: summary, Raw: raw, Err: err}
	}
}

func startStreamingCommand(config runConfig) tea.Cmd {
	return func() tea.Msg {
		session, err := startAgentMachineStream(config)
		if err != nil {
			return streamDoneMsg{Err: err}
		}
		return streamStartedMsg{Session: session}
	}
}

func readStreamCommand(session *streamSession) tea.Cmd {
	return func() tea.Msg {
		if session.scanner.Scan() {
			return streamLineMsg{Session: session, Line: session.scanner.Text()}
		}
		if err := session.scanner.Err(); err != nil {
			return streamDoneMsg{Session: session, Err: err}
		}
		err := session.cmd.Wait()
		if err != nil {
			stderr := strings.TrimSpace(session.stderr.String())
			if stderr != "" {
				return streamDoneMsg{Session: session, Err: fmt.Errorf("mix command failed: %w\n%s", err, stderr)}
			}
			return streamDoneMsg{Session: session, Err: fmt.Errorf("mix command failed: %w", err)}
		}
		return streamDoneMsg{Session: session}
	}
}

func startAgentMachineStream(config runConfig) (*streamSession, error) {
	args := buildRunArgs(config)
	cmd := exec.Command("mix", args...)
	cmd.Dir = projectRoot()
	cmd.Env = commandEnv(os.Environ(), config)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open AgentMachine stdout: %w", err)
	}
	stderr := &bytes.Buffer{}
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start AgentMachine: %w", err)
	}

	scanner := newLineScanner(stdout)
	return &streamSession{cmd: cmd, scanner: scanner, stderr: stderr}, nil
}

func newLineScanner(reader io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	return scanner
}

func runAgentMachine(config runConfig) (summary, string, error) {
	args := buildRunArgs(config)
	cmd := exec.Command("mix", args...)
	cmd.Dir = projectRoot()
	cmd.Env = commandEnv(os.Environ(), config)

	output, err := cmd.CombinedOutput()
	raw := strings.TrimSpace(string(output))
	if err != nil {
		return summary{}, raw, fmt.Errorf("mix command failed: %w", err)
	}

	parsed, parseErr := parseSummary(raw)
	if parseErr != nil {
		return summary{}, raw, parseErr
	}
	if parsed.Status == "failed" {
		return parsed, raw, fmt.Errorf("AgentMachine run failed: %s", summaryError(parsed))
	}

	return parsed, raw, nil
}

func buildRunArgs(config runConfig) []string {
	args := []string{
		"agent_machine.run",
		"--provider", string(config.Provider),
		"--timeout-ms", defaultRunTimeoutMS,
		"--max-steps", "2",
		"--max-attempts", "1",
		"--jsonl",
	}

	if config.Provider != providerEcho {
		args = append(args,
			"--model", config.Model,
			"--http-timeout-ms", config.HTTPTimeout,
			"--input-price-per-million", config.InputPrice,
			"--output-price-per-million", config.OutputPrice,
		)
	}

	return append(args, config.Task)
}

func validateConfig(config runConfig) error {
	if config.Task == "" {
		return errors.New("task must not be empty")
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

func formatPrice(value float64) string {
	return strconv.FormatFloat(value, 'f', -1, 64)
}

func commandEnv(base []string, config runConfig) []string {
	keyName := apiKeyName(config.Provider)
	if keyName == "" {
		return base
	}
	env := removeEnv(base, keyName)
	return append(env, keyName+"="+config.APIKey)
}

func removeEnv(env []string, name string) []string {
	prefix := name + "="
	filtered := make([]string, 0, len(env))
	for _, value := range env {
		if !strings.HasPrefix(value, prefix) {
			filtered = append(filtered, value)
		}
	}
	return filtered
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

func tuiConfigPath() (string, error) {
	if path := strings.TrimSpace(os.Getenv("AGENT_MACHINE_TUI_CONFIG")); path != "" {
		return path, nil
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("failed to locate user config directory: %w", err)
	}
	return filepath.Join(configDir, "agent-machine", "tui-config.json"), nil
}

func loadSavedConfig(path string) (savedConfig, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return savedConfig{}, nil
	}
	if err != nil {
		return savedConfig{}, fmt.Errorf("failed to read TUI config %s: %w", path, err)
	}

	var config savedConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return savedConfig{}, fmt.Errorf("failed to parse TUI config %s: %w", path, err)
	}
	return config, nil
}

func saveSavedConfig(path string, config savedConfig) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("failed to create TUI config directory: %w", err)
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to encode TUI config: %w", err)
	}

	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("failed to write TUI config %s: %w", path, err)
	}

	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("failed to restrict TUI config permissions %s: %w", path, err)
	}
	return nil
}

func parseSummary(raw string) (summary, error) {
	var parsed summary
	jsonLine := lastJSONLine(raw)
	if jsonLine == "" {
		return summary{}, errors.New("AgentMachine output did not contain a JSON summary")
	}

	if err := json.Unmarshal([]byte(jsonLine), &parsed); err != nil {
		return summary{}, fmt.Errorf("failed to parse AgentMachine JSON output: %w", err)
	}
	if parsed.RunID == "" {
		envelope, ok, err := parseJSONLLine(jsonLine)
		if err != nil {
			return summary{}, err
		}
		if ok && envelope.Type == "summary" {
			return envelope.Summary, nil
		}
	}
	return parsed, nil
}

func parseJSONLLine(line string) (jsonlEnvelope, bool, error) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || !strings.HasPrefix(trimmed, "{") {
		return jsonlEnvelope{}, false, nil
	}

	var envelope jsonlEnvelope
	if err := json.Unmarshal([]byte(trimmed), &envelope); err != nil {
		return jsonlEnvelope{}, false, fmt.Errorf("failed to parse AgentMachine JSONL line: %w", err)
	}
	if envelope.Type == "" {
		return jsonlEnvelope{}, false, nil
	}
	return envelope, true, nil
}

func lastJSONLine(raw string) string {
	lines := strings.Split(strings.TrimSpace(raw), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if strings.HasPrefix(line, "{") && strings.HasSuffix(line, "}") {
			return line
		}
	}
	return ""
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

func projectRoot() string {
	if root := os.Getenv("AGENT_MACHINE_ROOT"); root != "" {
		return root
	}

	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}

	if fileExists(filepath.Join(cwd, "mix.exs")) {
		return cwd
	}

	parent := filepath.Clean(filepath.Join(cwd, ".."))
	if fileExists(filepath.Join(parent, "mix.exs")) {
		return parent
	}
	return cwd
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func sortedResultIDs(results map[string]runResultSummary) []string {
	ids := make([]string, 0, len(results))
	for id := range results {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
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

func agentEventLines(events []eventSummary) string {
	if len(events) == 0 {
		return "(none)"
	}
	lines := make([]string, 0, len(events))
	for _, event := range events {
		label := event.Type
		if event.Status != "" {
			label += " " + event.Status
		}
		if event.Reason != "" {
			label += " " + event.Reason
		}
		lines = append(lines, label)
	}
	return strings.Join(lines, "\n")
}

func modelListText(models []modelOption, selected int) string {
	lines := []string{"models:"}
	limit := len(models)
	if limit > 12 {
		limit = 12
	}

	for index := 0; index < limit; index++ {
		prefix := "  "
		if index == selected {
			prefix = "* "
		}
		lines = append(lines, prefix+models[index].ID)
	}
	if len(models) > limit {
		lines = append(lines, fmt.Sprintf("... %d more", len(models)-limit))
	}
	return strings.Join(lines, "\n")
}

func helpText() string {
	return strings.Join([]string{
		labelStyle.Render("Help"),
		"",
		"Keys:",
		"Tab / Shift+Tab: switch views",
		"Esc: back",
		"Enter: submit or open selected agent",
		"Ctrl+A / Ctrl+E / Ctrl+U / Ctrl+K / Ctrl+W: edit input",
		"Ctrl+C: quit",
		"",
		"Commands:",
		"/setup",
		"/provider echo|openai|openrouter",
		"/key <api-key>",
		"/models reload",
		"/models",
		"/model <id|next|prev>",
		"/settings",
		"/agents",
		"/agent <id>",
		"/back",
		"/clear",
		"/quit",
	}, "\n")
}

func emptyAsNone(value string) string {
	if strings.TrimSpace(value) == "" {
		return "(none)"
	}
	return value
}

func emptyAs(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func emptyAsUnknown(value string) string {
	if strings.TrimSpace(value) == "" {
		return "unknown error"
	}
	return value
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
