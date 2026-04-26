package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
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
	Round         int    `json:"round"`
	ToolCallID    string `json:"tool_call_id"`
	Tool          string `json:"tool"`
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
	defaultRunTimeoutMS  = "120000"
	defaultBasicSteps    = "2"
	defaultAgenticSteps  = "6"
	defaultHTTPTimeoutMS = "120000"
)

type runConfig struct {
	Task          string
	Workflow      runWorkflow
	Provider      provider
	APIKey        string
	Model         string
	InputPrice    string
	OutputPrice   string
	HTTPTimeout   string
	ToolHarness   string
	ToolRoot      string
	ToolTimeout   string
	ToolMaxRounds string
	ToolApproval  string
	LogFile       string
}

type savedConfig struct {
	OpenAIAPIKey     string `json:"openai_api_key,omitempty"`
	OpenRouterAPIKey string `json:"openrouter_api_key,omitempty"`
	Workflow         string `json:"workflow,omitempty"`
	Provider         string `json:"provider,omitempty"`
	OpenAIModel      string `json:"openai_model,omitempty"`
	OpenRouterModel  string `json:"openrouter_model,omitempty"`
	ToolHarness      string `json:"tool_harness,omitempty"`
	ToolRoot         string `json:"tool_root,omitempty"`
	ToolTimeout      string `json:"tool_timeout_ms,omitempty"`
	ToolMaxRounds    string `json:"tool_max_rounds,omitempty"`
	ToolApproval     string `json:"tool_approval_mode,omitempty"`
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
	pendingToolTask    string
	pendingToolRoot    string
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

	m := model{
		input:       input,
		savedConfig: savedConfig,
		configPath:  configPath,
		messages: []chatMessage{
			{Role: "system", Text: "Open Setup and select a workflow and provider before running AgentMachine."},
		},
		view:   viewSetup,
		agents: map[string]agentState{},
	}

	if err := m.applySavedSettings(); err != nil {
		return model{}, err
	}

	return m, nil
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
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: summaryDisplayText(msg.Summary)})
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
				m.messages = append(m.messages, chatMessage{Role: "assistant", Text: summaryDisplayText(m.lastSummary)})
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

	if prompt, root, needsPermission := m.toolPermissionPrompt(task); needsPermission {
		m.pendingToolTask = task
		m.pendingToolRoot = root
		m.messages = append(m.messages, chatMessage{Role: "system", Text: prompt})
		m.view = viewChat
		return m, nil
	}

	runTask := m.taskWithConversationContext(task)
	config, err := resolveConfig(m.runConfig(runTask))
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		m.view = viewSetup
		return m, nil
	}
	config.LogFile = nextRunLogPath(m.configPath)

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
		chatMessage{Role: "system", Text: runningStatus(config)},
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

func (m model) taskWithConversationContext(task string) string {
	history := recentConversationMessages(m.messages, 6)
	if len(history) == 0 {
		return task
	}

	lines := []string{"Conversation context:"}
	for _, message := range history {
		lines = append(lines, message.Role+": "+compactContextText(message.Text))
	}
	lines = append(lines, "", "Current user request:", task)
	return strings.Join(lines, "\n")
}

func nextRunLogPath(configPath string) string {
	return filepath.Join(
		filepath.Dir(configPath),
		"logs",
		time.Now().UTC().Format("20060102T150405.000000000Z")+".jsonl",
	)
}

func recentConversationMessages(messages []chatMessage, limit int) []chatMessage {
	selected := make([]chatMessage, 0, limit)
	for i := len(messages) - 1; i >= 0 && len(selected) < limit; i-- {
		message := messages[i]
		if message.Role != "user" && message.Role != "assistant" {
			continue
		}
		if strings.TrimSpace(message.Text) == "" {
			continue
		}
		selected = append(selected, message)
	}
	for left, right := 0, len(selected)-1; left < right; left, right = left+1, right-1 {
		selected[left], selected[right] = selected[right], selected[left]
	}
	return selected
}

func compactContextText(text string) string {
	text = strings.Join(strings.Fields(text), " ")
	if len(text) <= 500 {
		return text
	}
	return text[:500] + "..."
}

func summaryDisplayText(summary summary) string {
	if strings.TrimSpace(summary.FinalOutput) != "" {
		return summary.FinalOutput
	}

	lines := make([]string, 0, len(summary.Results)+1)
	for _, id := range sortedResultIDs(summary.Results) {
		result := summary.Results[id]
		switch {
		case strings.TrimSpace(result.Output) != "":
			lines = append(lines, id+": "+result.Output)
		case strings.TrimSpace(result.Error) != "":
			lines = append(lines, id+" error: "+result.Error)
		}
	}

	if len(lines) == 0 {
		return "Run completed without a final response. Open /agents and inspect agent details."
	}

	return "Run completed without a final response. Agent outputs:\n" + strings.Join(lines, "\n")
}

func sortedResultIDs(results map[string]runResultSummary) []string {
	ids := make([]string, 0, len(results))
	for id := range results {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
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
	case "tools":
		return m.handleToolsCommand(args)
	case "allow-tools":
		return m.handleAllowToolsCommand(args, "auto-approved-safe")
	case "yolo-tools":
		return m.handleAllowToolsCommand(args, "full-access")
	case "deny-tools":
		return m.handleDenyToolsCommand(args)
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

func (m model) handleAllowToolsCommand(args []string, fallbackApproval string) (tea.Model, tea.Cmd) {
	if m.pendingToolTask == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no pending tool request"})
		return m, nil
	}
	if len(args) > 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /allow-tools [auto-approved-safe|full-access]"})
		return m, nil
	}

	approval := fallbackApproval
	if len(args) == 1 {
		approval = args[0]
	}
	if approval != "auto-approved-safe" && approval != "full-access" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "write tool approval must be auto-approved-safe or full-access"})
		return m, nil
	}

	root := m.pendingToolRoot
	if root == "" {
		var err error
		root, err = os.UserHomeDir()
		if err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "could not resolve home directory: " + err.Error()})
			return m, nil
		}
	}

	m.savedConfig.ToolHarness = "local-files"
	m.savedConfig.ToolRoot = root
	m.savedConfig.ToolTimeout = "1000"
	m.savedConfig.ToolMaxRounds = "4"
	m.savedConfig.ToolApproval = approval

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	task := m.pendingToolTask
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "allowed local-files tools root=" + root + " approval=" + approval})
	return m.startRun(task)
}

func (m model) handleDenyToolsCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /deny-tools"})
		return m, nil
	}
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool request denied; no run started"})
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
	m.savedConfig.Workflow = string(nextWorkflow)
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
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
	m.savedConfig.Provider = string(nextProvider)
	m.savedConfig.rememberModel(nextProvider, "")
	m.modelOptions = nil
	m.modelIndex = 0
	m.selectedModel = ""
	m.modelStatus = ""
	m.modelPickerOpen = false
	m.modelPickerPending = false
	m.modelPickerQuery = ""
	m.view = viewChat
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider set to " + m.provider.Label()})
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

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

func (m model) handleToolsCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.toolsStatus()})
		return m, nil
	}

	switch args[0] {
	case "off":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /tools off"})
			return m, nil
		}
		m.savedConfig.ToolHarness = ""
		m.savedConfig.ToolRoot = ""
		m.savedConfig.ToolTimeout = ""
		m.savedConfig.ToolMaxRounds = ""
		m.savedConfig.ToolApproval = ""
	case "local-files", "code-edit":
		if len(args) != 5 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /tools " + args[0] + " <root> <timeout-ms> <max-rounds> <approval-mode>"})
			return m, nil
		}
		if strings.TrimSpace(args[1]) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool root must not be empty"})
			return m, nil
		}
		if err := validatePositiveInt(args[2], "tool timeout ms"); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		if err := validatePositiveInt(args[3], "tool max rounds"); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		if err := validateToolApprovalMode(args[4]); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		m.savedConfig.ToolHarness = args[0]
		m.savedConfig.ToolRoot = args[1]
		m.savedConfig.ToolTimeout = args[2]
		m.savedConfig.ToolMaxRounds = args[3]
		m.savedConfig.ToolApproval = args[4]
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /tools off|local-files|code-edit <root> <timeout-ms> <max-rounds> <approval-mode>"})
		return m, nil
	}

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.toolsStatus()})
	return m, nil
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

	m.savedConfig.rememberModel(m.provider, m.selectedModel)
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
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
	m.savedConfig.rememberModel(m.provider, m.selectedModel)
	m.modelPickerOpen = false
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
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
		Task:          task,
		Workflow:      m.workflow,
		Provider:      m.provider,
		APIKey:        m.apiKey(),
		Model:         m.modelID(),
		ToolHarness:   m.savedConfig.ToolHarness,
		ToolRoot:      m.savedConfig.ToolRoot,
		ToolTimeout:   m.savedConfig.ToolTimeout,
		ToolMaxRounds: m.savedConfig.ToolMaxRounds,
		ToolApproval:  m.savedConfig.ToolApproval,
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
	if err := validateToolConfig(config); err != nil {
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

func validateToolConfig(config runConfig) error {
	switch config.ToolHarness {
	case "":
		if config.ToolRoot != "" || config.ToolTimeout != "" || config.ToolMaxRounds != "" || config.ToolApproval != "" {
			return errors.New("tool root, timeout, max rounds, and approval mode require a selected tool harness")
		}
		return nil
	case "local-files", "code-edit":
		if strings.TrimSpace(config.ToolRoot) == "" {
			return errors.New("tool root must not be empty for " + config.ToolHarness)
		}
		if err := validatePositiveInt(config.ToolTimeout, "tool timeout ms"); err != nil {
			return err
		}
		if err := validatePositiveInt(config.ToolMaxRounds, "tool max rounds"); err != nil {
			return err
		}
		if err := validateToolApprovalMode(config.ToolApproval); err != nil {
			return err
		}
		return nil
	default:
		return fmt.Errorf("unsupported tool harness: %s", config.ToolHarness)
	}
}

func validateToolApprovalMode(mode string) error {
	switch mode {
	case "read-only", "ask-before-write", "auto-approved-safe", "full-access":
		return nil
	case "":
		return errors.New("tool approval mode is missing")
	default:
		return fmt.Errorf("unsupported tool approval mode: %s", mode)
	}
}

func (m model) toolPermissionPrompt(task string) (string, string, bool) {
	if !filesystemWriteIntent(task) {
		return "", "", false
	}

	root := inferredToolRoot(task)
	if root == "" {
		return "", "", false
	}

	switch m.savedConfig.ToolHarness {
	case "local-files":
		if !pathInsideRoot(root, m.savedConfig.ToolRoot) {
			return toolPermissionText(
				"requested filesystem location is outside the active tool root",
				root,
				m.savedConfig.ToolRoot,
			), root, true
		}
		if m.savedConfig.ToolApproval != "auto-approved-safe" && m.savedConfig.ToolApproval != "full-access" {
			return toolPermissionText(
				"active tool approval mode cannot perform writes without an interactive approval bridge",
				root,
				m.savedConfig.ToolRoot,
			), root, true
		}
		return "", "", false
	case "":
		return toolPermissionText("filesystem tools are off", root, ""), root, true
	default:
		return toolPermissionText("active tool harness cannot perform this filesystem action", root, m.savedConfig.ToolRoot), root, true
	}
}

func toolPermissionText(reason string, root string, activeRoot string) string {
	lines := []string{
		"filesystem permission required: " + reason,
		"requested root: " + root,
	}
	if strings.TrimSpace(activeRoot) != "" {
		lines = append(lines, "active root: "+activeRoot)
	}
	lines = append(lines,
		"Run /allow-tools to enable local-files for this root and retry now.",
		"Run /yolo-tools to enable full-access for this root and retry now.",
		"Run /deny-tools to decline.",
	)
	return strings.Join(lines, "\n")
}

func filesystemWriteIntent(task string) bool {
	text := strings.ToLower(task)
	writeVerb := containsAny(text, []string{
		"create", "make", "write", "append", "replace", "edit", "update", "delete", "remove", "rename",
	})
	fileNoun := containsAny(text, []string{
		"file", "folder", "directory", "dir", "path", "home", "~/", "/users/", "/tmp/",
	})
	return writeVerb && fileNoun
}

func inferredToolRoot(task string) string {
	text := strings.ToLower(task)
	if strings.Contains(text, "home folder") ||
		strings.Contains(text, "home directory") ||
		strings.Contains(text, "my home") ||
		strings.Contains(text, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return home
		}
	}

	if path := firstAbsolutePath(task); path != "" {
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			return path
		}
		if parent := filepath.Dir(path); parent != "." && parent != "/" {
			return parent
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return home
}

func firstAbsolutePath(text string) string {
	for _, field := range strings.Fields(text) {
		candidate := strings.Trim(field, ".,;:()[]{}\"'")
		if strings.HasPrefix(candidate, "/") {
			return filepath.Clean(candidate)
		}
	}
	return ""
}

func containsAny(text string, needles []string) bool {
	for _, needle := range needles {
		if strings.Contains(text, needle) {
			return true
		}
	}
	return false
}

func pathInsideRoot(path string, root string) bool {
	path = filepath.Clean(strings.TrimSpace(path))
	root = filepath.Clean(strings.TrimSpace(root))
	if path == "" || root == "" {
		return false
	}
	return path == root || strings.HasPrefix(path, root+string(os.PathSeparator))
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

func (m model) toolsStatus() string {
	switch m.savedConfig.ToolHarness {
	case "":
		return "tools: off"
	case "local-files", "code-edit":
		return "tools: " + m.savedConfig.ToolHarness + " root=" + emptyAsNone(m.savedConfig.ToolRoot) + " timeout_ms=" + emptyAsNone(m.savedConfig.ToolTimeout) + " max_rounds=" + emptyAsNone(m.savedConfig.ToolMaxRounds) + " approval=" + emptyAsNone(m.savedConfig.ToolApproval)
	default:
		return "tools: unsupported " + m.savedConfig.ToolHarness
	}
}

func runningStatus(config runConfig) string {
	return "running " + config.Provider.Label() + " / " + config.Model + " / " + runToolsStatus(config) + " / log=" + emptyAsNone(config.LogFile) + "..."
}

func runToolsStatus(config runConfig) string {
	switch config.ToolHarness {
	case "":
		return "tools off"
	case "local-files", "code-edit":
		return "tools " + config.ToolHarness + " root=" + emptyAsNone(config.ToolRoot)
	default:
		return "tools unsupported " + config.ToolHarness
	}
}

func (m *model) applySavedSettings() error {
	if strings.TrimSpace(m.savedConfig.Workflow) != "" {
		workflow, err := parseWorkflow(m.savedConfig.Workflow)
		if err != nil {
			return fmt.Errorf("invalid saved workflow in TUI config: %w", err)
		}
		m.workflow = workflow
		m.workflowSet = true
	}

	if strings.TrimSpace(m.savedConfig.Provider) != "" {
		provider, err := parseProvider(m.savedConfig.Provider)
		if err != nil {
			return fmt.Errorf("invalid saved provider in TUI config: %w", err)
		}
		m.provider = provider
		m.providerSet = true
		m.selectedModel = m.savedConfig.modelFor(provider)
	}

	if strings.TrimSpace(m.savedConfig.ToolHarness) != "" {
		if err := validateToolConfig(runConfig{
			Workflow:      workflowBasic,
			Provider:      providerEcho,
			ToolHarness:   m.savedConfig.ToolHarness,
			ToolRoot:      m.savedConfig.ToolRoot,
			ToolTimeout:   m.savedConfig.ToolTimeout,
			ToolMaxRounds: m.savedConfig.ToolMaxRounds,
			ToolApproval:  m.savedConfig.ToolApproval,
		}); err != nil {
			return fmt.Errorf("invalid saved tools in TUI config: %w", err)
		}
	}

	if m.workflowSet && m.providerSet {
		m.view = viewChat
		m.messages = []chatMessage{
			{Role: "system", Text: "Loaded saved TUI setup. Use /setup to change it."},
		}
	}

	return nil
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

func (config savedConfig) modelFor(provider provider) string {
	switch provider {
	case providerOpenAI:
		return config.OpenAIModel
	case providerOpenRouter:
		return config.OpenRouterModel
	default:
		return ""
	}
}

func (config *savedConfig) rememberModel(provider provider, model string) {
	switch provider {
	case providerOpenAI:
		config.OpenAIModel = model
	case providerOpenRouter:
		config.OpenRouterModel = model
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
