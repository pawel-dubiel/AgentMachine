package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
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
	RunID         string                      `json:"run_id"`
	Status        string                      `json:"status"`
	Error         string                      `json:"error"`
	FinalOutput   string                      `json:"final_output"`
	WorkflowRoute workflowRoute               `json:"workflow_route"`
	Results       map[string]runResultSummary `json:"results"`
	Skills        []skillSummary              `json:"skills"`
	Usage         usageSummary                `json:"usage"`
	Events        []eventSummary              `json:"events"`
}

type skillSummary struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Reason      string `json:"reason"`
}

type runResultSummary struct {
	Status   string          `json:"status"`
	Output   string          `json:"output"`
	Decision plannerDecision `json:"decision"`
	Error    string          `json:"error"`
	Attempt  int             `json:"attempt"`
}

type plannerDecision struct {
	Mode              string   `json:"mode"`
	Reason            string   `json:"reason"`
	DelegatedAgentIDs []string `json:"delegated_agent_ids"`
}

type workflowRoute struct {
	Requested    string `json:"requested"`
	Selected     string `json:"selected"`
	Reason       string `json:"reason"`
	ToolIntent   string `json:"tool_intent"`
	ToolsExposed bool   `json:"tools_exposed"`
}

type usageSummary struct {
	Agents       int     `json:"agents"`
	InputTokens  int     `json:"input_tokens"`
	OutputTokens int     `json:"output_tokens"`
	TotalTokens  int     `json:"total_tokens"`
	CostUSD      float64 `json:"cost_usd"`
}

type eventSummary struct {
	Type          string         `json:"type"`
	RunID         string         `json:"run_id"`
	AgentID       string         `json:"agent_id"`
	ParentAgentID string         `json:"parent_agent_id"`
	Status        string         `json:"status"`
	Attempt       int            `json:"attempt"`
	NextAttempt   int            `json:"next_attempt"`
	Round         int            `json:"round"`
	ToolCallID    string         `json:"tool_call_id"`
	Tool          string         `json:"tool"`
	DurationMS    *int           `json:"duration_ms"`
	Reason        string         `json:"reason"`
	Summary       string         `json:"summary"`
	Delta         string         `json:"delta"`
	Details       map[string]any `json:"details"`
	At            string         `json:"at"`
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

type streamTickMsg struct{}

type skillsCommandMsg struct {
	Output string
	Err    error
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
	Decision      plannerDecision
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
	workflowChat    runWorkflow = "chat"
	workflowBasic   runWorkflow = "basic"
	workflowAgentic runWorkflow = "agentic"
	workflowAuto    runWorkflow = "auto"
)

const (
	defaultRunTimeoutMS  = "120000"
	defaultChatSteps     = "1"
	defaultBasicSteps    = "2"
	defaultAgenticSteps  = "6"
	defaultHTTPTimeoutMS = "120000"
	liveEventWindowSize  = 8
)

type runConfig struct {
	Task              string
	Workflow          runWorkflow
	Provider          provider
	APIKey            string
	Model             string
	InputPrice        string
	OutputPrice       string
	HTTPTimeout       string
	RunTimeout        string
	ToolHarness       string
	ToolRoot          string
	ToolTimeout       string
	ToolMaxRounds     string
	ToolApproval      string
	TestCommands      []string
	MCPConfig         string
	SkillsMode        string
	SkillsDir         string
	SkillNames        []string
	AllowSkillScripts bool
	LogFile           string
}

type savedConfig struct {
	OpenAIAPIKey      string   `json:"openai_api_key,omitempty"`
	OpenRouterAPIKey  string   `json:"openrouter_api_key,omitempty"`
	Workflow          string   `json:"workflow,omitempty"`
	Provider          string   `json:"provider,omitempty"`
	OpenAIModel       string   `json:"openai_model,omitempty"`
	OpenRouterModel   string   `json:"openrouter_model,omitempty"`
	ToolHarness       string   `json:"tool_harness,omitempty"`
	ToolRoot          string   `json:"tool_root,omitempty"`
	ToolTimeout       string   `json:"tool_timeout_ms,omitempty"`
	ToolMaxRounds     string   `json:"tool_max_rounds,omitempty"`
	ToolApproval      string   `json:"tool_approval_mode,omitempty"`
	TestCommands      []string `json:"test_commands,omitempty"`
	MCPConfig         string   `json:"mcp_config,omitempty"`
	SkillsMode        string   `json:"skills_mode,omitempty"`
	SkillsDir         string   `json:"skills_dir,omitempty"`
	SkillNames        []string `json:"skill_names,omitempty"`
	AllowSkillScripts bool     `json:"allow_skill_scripts,omitempty"`
}

type chatMessage struct {
	Role string
	Text string
}

type queuedMessage struct {
	ID        int
	Text      string
	CreatedAt string
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
	queuedMessages     []queuedMessage
	nextQueueID        int
	view               viewMode
	selectedAgent      string
	selectedAgentIndex int
	running            bool
	activeConfig       runConfig
	lastSummary        summary
	agents             map[string]agentState
	agentOrder         []string
	eventLog           []eventSummary
	eventScroll        int
	eventAutoScroll    bool
	streamFrame        int
	liveAssistant      string
	raw                string
	stream             *streamSession
	pendingToolTask    string
	pendingToolRoot    string
	pendingToolHarness string
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
			{Role: "system", Text: "Open Setup and select a provider before running AgentMachine."},
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

func streamTickCommand() tea.Cmd {
	return tea.Tick(180*time.Millisecond, func(time.Time) tea.Msg {
		return streamTickMsg{}
	})
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
			if m.running && m.view == viewChat {
				m.scrollEvents(-1)
				return m, nil
			}
			if m.view == viewAgents {
				m.moveAgentSelection(-1)
				return m, nil
			}
			if msg.String() == "up" && !m.running && m.canUseInputHistory() {
				m.previousHistory()
				return m, nil
			}
		case "down", "j":
			if m.running && m.view == viewChat {
				m.scrollEvents(1)
				return m, nil
			}
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
			return m.submitInput()
		case "pgup":
			if m.running && m.view == viewChat {
				m.scrollEvents(-5)
				return m, nil
			}
		case "pgdown":
			if m.running && m.view == viewChat {
				m.scrollEvents(5)
				return m, nil
			}
		case "home":
			if m.running && m.view == viewChat {
				m.eventScroll = 0
				m.eventAutoScroll = false
				return m, nil
			}
		case "end":
			if m.running && m.view == viewChat {
				m.eventAutoScroll = true
				m.clampEventScroll()
				return m, nil
			}
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
		return m.startNextQueuedRun()

	case streamStartedMsg:
		m.stream = msg.Session
		return m, tea.Batch(readStreamCommand(msg.Session), streamTickCommand())

	case streamTickMsg:
		if !m.running {
			return m, nil
		}
		m.streamFrame++
		return m, streamTickCommand()

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
		return m.startNextQueuedRun()

	case skillsCommandMsg:
		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "skills command failed:\n" + msg.Err.Error()})
		} else {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: strings.TrimSpace(msg.Output)})
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

	if m.view != viewAgents && m.view != viewAgentDetail && !m.modelPickerOpen {
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

	if m.running {
		m.queueMessage(text)
		return m, nil
	}

	return m.startRun(text)
}

func (m *model) queueMessage(text string) {
	if m.nextQueueID == 0 {
		m.nextQueueID = 1
	}
	item := queuedMessage{
		ID:        m.nextQueueID,
		Text:      text,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	m.nextQueueID++
	m.queuedMessages = append(m.queuedMessages, item)
	m.messages = append(m.messages, chatMessage{Role: "system", Text: fmt.Sprintf("queued message %d", len(m.queuedMessages))})
}

func (m model) startNextQueuedRun() (tea.Model, tea.Cmd) {
	if m.running || len(m.queuedMessages) == 0 {
		return m, nil
	}

	next := m.queuedMessages[0]
	m.queuedMessages = m.queuedMessages[1:]
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "starting queued message: " + compactQueueText(next.Text)})
	return m.startRun(next.Text)
}

func (m model) startRun(task string) (tea.Model, tea.Cmd) {
	if !m.providerSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider in Setup before running"})
		m.view = viewSetup
		return m, nil
	}

	permissionTask := m.taskWithConversationContext(task)
	if prompt, root, harness, needsPermission := m.toolPermissionPrompt(permissionTask); needsPermission {
		m.pendingToolTask = task
		m.pendingToolRoot = root
		m.pendingToolHarness = harness
		m.messages = append(m.messages, chatMessage{Role: "system", Text: prompt})
		m.view = viewChat
		return m, nil
	}

	runTask := permissionTask
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
	m.eventLog = nil
	m.eventScroll = 0
	m.eventAutoScroll = true
	m.streamFrame = 0
	m.liveAssistant = ""
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
		if strings.TrimSpace(result.Decision.Mode) != "" {
			lines = append(lines, id+" decision: "+decisionSummaryText(result.Decision))
		}
		switch {
		case strings.TrimSpace(result.Output) != "":
			lines = append(lines, id+": "+result.Output)
		case strings.TrimSpace(result.Error) != "":
			lines = append(lines, id+" error: "+result.Error)
		}
	}

	if len(lines) == 0 {
		return summaryFallbackHeading(summary) + " Open /agents and inspect agent details."
	}

	return summaryFallbackHeading(summary) + " Agent outputs:\n" + strings.Join(lines, "\n")
}

func decisionSummaryText(decision plannerDecision) string {
	text := emptyAsNone(decision.Mode)
	if strings.TrimSpace(decision.Reason) != "" {
		text += " - " + decision.Reason
	}
	return text
}

func summaryFallbackHeading(summary summary) string {
	switch summary.Status {
	case "timeout":
		return "Run timed out before a final response."
	case "failed":
		return "Run failed before a final response."
	default:
		return "Run completed without a final response."
	}
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

	if m.running && name != "queue" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "command unavailable while a run is active; queue a message or use /queue"})
		return m, nil
	}

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
	case "skills":
		return m.handleSkillsCommand(args)
	case "test-command":
		return m.handleTestCommand(args)
	case "mcp-config":
		return m.handleMCPConfigCommand(args)
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
	case "queue":
		return m.handleQueueCommand(args)
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

func (m model) handleQueueCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 || args[0] == "list" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: queueListText(m.queuedMessages)})
		return m, nil
	}

	switch args[0] {
	case "edit":
		if len(args) < 3 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /queue edit <index> <new message>"})
			return m, nil
		}
		index, err := queueIndex(args[1], len(m.queuedMessages))
		if err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		m.queuedMessages[index].Text = strings.Join(args[2:], " ")
		m.messages = append(m.messages, chatMessage{Role: "system", Text: fmt.Sprintf("updated queued message %d", index+1)})
		return m, nil
	case "remove":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /queue remove <index>"})
			return m, nil
		}
		index, err := queueIndex(args[1], len(m.queuedMessages))
		if err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		removed := m.queuedMessages[index]
		m.queuedMessages = append(m.queuedMessages[:index], m.queuedMessages[index+1:]...)
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "removed queued message: " + compactQueueText(removed.Text)})
		return m, nil
	case "clear":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /queue clear"})
			return m, nil
		}
		count := len(m.queuedMessages)
		m.queuedMessages = nil
		m.messages = append(m.messages, chatMessage{Role: "system", Text: fmt.Sprintf("cleared %d queued message(s)", count)})
		return m, nil
	case "run":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /queue run <index>"})
			return m, nil
		}
		index, err := queueIndex(args[1], len(m.queuedMessages))
		if err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		item := m.queuedMessages[index]
		m.queuedMessages = append(m.queuedMessages[:index], m.queuedMessages[index+1:]...)
		if m.running {
			m.queuedMessages = append([]queuedMessage{item}, m.queuedMessages...)
			m.messages = append(m.messages, chatMessage{Role: "system", Text: fmt.Sprintf("queued message %d will run next", index+1)})
			return m, nil
		}
		return m.startRun(item.Text)
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /queue [list]|edit <index> <message>|remove <index>|clear|run <index>"})
		return m, nil
	}
}

func queueIndex(value string, total int) (int, error) {
	if total == 0 {
		return 0, errors.New("queue is empty")
	}
	index, err := strconv.Atoi(value)
	if err != nil || index < 1 || index > total {
		return 0, fmt.Errorf("queue index must be between 1 and %d", total)
	}
	return index - 1, nil
}

func queueListText(queue []queuedMessage) string {
	if len(queue) == 0 {
		return "queue is empty"
	}
	lines := []string{"Queued messages:"}
	for index, item := range queue {
		lines = append(lines, fmt.Sprintf("%d. %s", index+1, compactQueueText(item.Text)))
	}
	return strings.Join(lines, "\n")
}

func compactQueueText(text string) string {
	text = strings.Join(strings.Fields(text), " ")
	if len(text) <= 96 {
		return text
	}
	return text[:96] + "..."
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

	harness := m.pendingToolHarness
	if harness == "" {
		harness = "local-files"
	}

	m.savedConfig.ToolHarness = harness
	m.savedConfig.ToolRoot = root
	m.savedConfig.ToolTimeout = "1000"
	m.savedConfig.ToolMaxRounds = "6"
	m.savedConfig.ToolApproval = approval

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	task := m.pendingToolTask
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.pendingToolHarness = ""
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "allowed " + harness + " tools root=" + root + " approval=" + approval})
	return m.startRun(task)
}

func (m model) handleDenyToolsCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /deny-tools"})
		return m, nil
	}
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.pendingToolHarness = ""
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool request denied; no run started"})
	return m, nil
}

func (m model) handleWorkflowCommand(args []string) (tea.Model, tea.Cmd) {
	_ = args
	m.view = viewChat
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "TUI uses progressive auto mode; each run requests auto and records the selected workflow"})
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
		m.savedConfig.TestCommands = nil
		m.savedConfig.MCPConfig = ""
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
		if len(m.savedConfig.TestCommands) > 0 && (args[0] != "code-edit" || args[4] != "full-access") {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "saved test commands require /tools code-edit <root> <timeout-ms> <max-rounds> full-access"})
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

func (m model) handleTestCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /test-command add <command>|list|clear"})
		return m, nil
	}

	switch args[0] {
	case "add":
		command := strings.TrimSpace(strings.Join(args[1:], " "))
		if command == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "test command must not be empty"})
			return m, nil
		}
		for _, existing := range m.savedConfig.TestCommands {
			if existing == command {
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "test command already exists: " + command})
				return m, nil
			}
		}
		m.savedConfig.TestCommands = append(m.savedConfig.TestCommands, command)
	case "list":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /test-command list"})
			return m, nil
		}
		if len(m.savedConfig.TestCommands) == 0 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "test commands: none"})
			return m, nil
		}
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "test commands:\n" + strings.Join(m.savedConfig.TestCommands, "\n")})
		return m, nil
	case "clear":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /test-command clear"})
			return m, nil
		}
		m.savedConfig.TestCommands = nil
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /test-command add <command>|list|clear"})
		return m, nil
	}

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.toolsStatus()})
	return m, nil
}

func (m model) handleMCPConfigCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /mcp-config <path>|off"})
		return m, nil
	}

	if args[0] == "off" {
		m.savedConfig.MCPConfig = ""
	} else {
		path := strings.TrimSpace(args[0])
		if path == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "MCP config path must not be empty"})
			return m, nil
		}
		m.savedConfig.MCPConfig = path
	}

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.toolsStatus()})
	return m, nil
}

func (m model) handleSkillsCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.skillsStatus()})
		return m, nil
	}

	previousConfig := m.savedConfig

	switch args[0] {
	case "off":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills off"})
			return m, nil
		}
		m.savedConfig.SkillsMode = ""
		m.savedConfig.SkillsDir = ""
		m.savedConfig.SkillNames = nil
		m.savedConfig.AllowSkillScripts = false
	case "auto":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills auto <skills-dir>"})
			return m, nil
		}
		if strings.TrimSpace(args[1]) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "skills dir must not be empty"})
			return m, nil
		}
		m.savedConfig.SkillsMode = "auto"
		m.savedConfig.SkillsDir = args[1]
		m.savedConfig.SkillNames = nil
	case "dir":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills dir <skills-dir>"})
			return m, nil
		}
		m.savedConfig.SkillsDir = args[1]
	case "add":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills add <name>"})
			return m, nil
		}
		if strings.TrimSpace(m.savedConfig.SkillsDir) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "set /skills dir <skills-dir> before adding explicit skills"})
			return m, nil
		}
		if !validSkillName(args[1]) {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "invalid skill name: " + args[1]})
			return m, nil
		}
		for _, existing := range m.savedConfig.SkillNames {
			if existing == args[1] {
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "skill already selected: " + args[1]})
				return m, nil
			}
		}
		m.savedConfig.SkillsMode = ""
		m.savedConfig.SkillNames = append(m.savedConfig.SkillNames, args[1])
	case "remove":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills remove <name>"})
			return m, nil
		}
		m.savedConfig.SkillNames = removeString(m.savedConfig.SkillNames, args[1])
	case "clear":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills clear"})
			return m, nil
		}
		m.savedConfig.SkillNames = nil
	case "scripts":
		if len(args) != 2 || (args[1] != "on" && args[1] != "off") {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills scripts on|off"})
			return m, nil
		}
		m.savedConfig.AllowSkillScripts = args[1] == "on"
	case "list":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills list"})
			return m, nil
		}
		return m, m.skillsCLICommand("list")
	case "search":
		if len(args) < 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills search <query> [downloads|trending|updated|stars]"})
			return m, nil
		}
		sort := "downloads"
		queryParts := args[1:]
		if len(args) > 2 && validClawHubSort(args[len(args)-1]) {
			sort = args[len(args)-1]
			queryParts = args[1 : len(args)-1]
		}
		query := strings.Join(queryParts, " ")
		return m, m.skillsCLINoDirCommand("search", query, "--source", "clawhub", "--sort", sort, "--limit", "20")
	case "show":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills show <name|clawhub:slug>"})
			return m, nil
		}
		if strings.HasPrefix(args[1], "clawhub:") {
			return m, m.skillsCLINoDirCommand("show", args[1])
		}
		return m, m.skillsCLICommand("show", args[1])
	case "install":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills install <name|clawhub:slug>"})
			return m, nil
		}
		return m, m.skillsCLICommand("install", args[1])
	case "update":
		if len(args) > 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills update [clawhub:slug|slug|--all]"})
			return m, nil
		}
		target := "--all"
		if len(args) == 2 {
			target = args[1]
			if target != "--all" && !strings.HasPrefix(target, "clawhub:") {
				target = "clawhub:" + target
			}
		}
		return m, m.skillsCLICommand("update", target)
	case "create":
		if len(args) < 3 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills create <name> <description>"})
			return m, nil
		}
		return m, m.skillsCLICommand("create", args[1], "--description", strings.Join(args[2:], " "))
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills off|auto|dir|add|remove|clear|scripts|list|search|show|install|update|create"})
		return m, nil
	}

	if err := validateSkillsConfig(runConfig{
		SkillsMode:        m.savedConfig.SkillsMode,
		SkillsDir:         m.savedConfig.SkillsDir,
		SkillNames:        m.savedConfig.SkillNames,
		AllowSkillScripts: m.savedConfig.AllowSkillScripts,
	}); err != nil {
		m.savedConfig = previousConfig
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.skillsStatus()})
	return m, nil
}

func (m model) skillsCLICommand(args ...string) tea.Cmd {
	cliArgs, err := buildSkillsCLIArgs(args, m.savedConfig.SkillsDir, true)
	if err != nil {
		return func() tea.Msg {
			return skillsCommandMsg{Err: err}
		}
	}
	return runSkillsCLICommand(cliArgs)
}

func (m model) skillsCLINoDirCommand(args ...string) tea.Cmd {
	cliArgs, err := buildSkillsCLIArgs(args, "", false)
	if err != nil {
		return func() tea.Msg {
			return skillsCommandMsg{Err: err}
		}
	}
	return runSkillsCLICommand(cliArgs)
}

func buildSkillsCLIArgs(args []string, skillsDir string, requireDir bool) ([]string, error) {
	if requireDir && strings.TrimSpace(skillsDir) == "" {
		return nil, errors.New("set /skills dir <skills-dir> before running skills commands")
	}
	cliArgs := append([]string{}, args...)
	if requireDir {
		cliArgs = append(cliArgs, "--skills-dir", skillsDir)
	}
	cliArgs = append(cliArgs, "--json")
	return cliArgs, nil
}

func validClawHubSort(value string) bool {
	switch value {
	case "downloads", "trending", "updated", "stars":
		return true
	default:
		return false
	}
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
	m.eventLog = append(m.eventLog, event)
	if event.Type == "assistant_delta" && event.Delta != "" {
		m.appendAgentDelta(event)
		if userFacingStreamAgent(event.AgentID) {
			m.liveAssistant += event.Delta
		}
	}
	if m.eventAutoScroll {
		m.clampEventScroll()
	}

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
	case "provider_request_started", "assistant_delta":
		if agent.Status == "" {
			agent.Status = "running"
		}
	}

	agent.Events = append(agent.Events, event)
	m.agents[event.AgentID] = agent
}

func (m *model) appendAgentDelta(event eventSummary) {
	if event.AgentID == "" {
		return
	}
	agent := m.agents[event.AgentID]
	if agent.ID == "" {
		agent.ID = event.AgentID
		m.agentOrder = append(m.agentOrder, event.AgentID)
	}
	agent.Output += event.Delta
	m.agents[event.AgentID] = agent
}

func userFacingStreamAgent(agentID string) bool {
	return agentID == "assistant" || agentID == "finalizer"
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
		agent.Decision = result.Decision
		agent.Error = result.Error
		m.agents[id] = agent
	}
}

func (m model) runConfig(task string) runConfig {
	config := runConfig{
		Task:              task,
		Workflow:          workflowAuto,
		Provider:          m.provider,
		APIKey:            m.apiKey(),
		Model:             m.modelID(),
		ToolHarness:       m.savedConfig.ToolHarness,
		ToolRoot:          m.savedConfig.ToolRoot,
		ToolTimeout:       m.savedConfig.ToolTimeout,
		ToolMaxRounds:     m.savedConfig.ToolMaxRounds,
		ToolApproval:      m.savedConfig.ToolApproval,
		TestCommands:      append([]string(nil), m.savedConfig.TestCommands...),
		MCPConfig:         m.savedConfig.MCPConfig,
		SkillsMode:        m.savedConfig.SkillsMode,
		SkillsDir:         m.savedConfig.SkillsDir,
		SkillNames:        append([]string(nil), m.savedConfig.SkillNames...),
		AllowSkillScripts: m.savedConfig.AllowSkillScripts,
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
	if err := validateSkillsConfig(config); err != nil {
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

func validateSkillsConfig(config runConfig) error {
	mode := strings.TrimSpace(config.SkillsMode)
	if mode == "" {
		mode = "off"
	}
	switch mode {
	case "off":
		if len(config.SkillNames) > 0 {
			if strings.TrimSpace(config.SkillsDir) == "" {
				return errors.New("skills dir must not be empty when explicit skills are selected")
			}
			return validateSkillNames(config.SkillNames)
		}
		if config.AllowSkillScripts {
			return errors.New("skill scripts require enabled skills")
		}
		return nil
	case "auto":
		if strings.TrimSpace(config.SkillsDir) == "" {
			return errors.New("skills dir must not be empty for auto skills")
		}
		if len(config.SkillNames) > 0 {
			return errors.New("skills auto cannot be combined with explicit skill names")
		}
		return nil
	default:
		return fmt.Errorf("unsupported skills mode: %s", config.SkillsMode)
	}
}

func validateSkillNames(names []string) error {
	seen := map[string]bool{}
	for _, name := range names {
		if !validSkillName(name) {
			return fmt.Errorf("invalid skill name: %s", name)
		}
		if seen[name] {
			return fmt.Errorf("duplicate skill name: %s", name)
		}
		seen[name] = true
	}
	return nil
}

func validSkillName(name string) bool {
	if name == "" {
		return false
	}
	for i, r := range name {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-'
		if !ok {
			return false
		}
		if i == 0 && !((r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}

func validateToolConfig(config runConfig) error {
	switch config.ToolHarness {
	case "":
		if config.ToolRoot != "" || len(config.TestCommands) != 0 {
			return errors.New("tool root and test commands require a selected filesystem tool harness")
		}
		if strings.TrimSpace(config.MCPConfig) == "" {
			if config.ToolTimeout != "" || config.ToolMaxRounds != "" || config.ToolApproval != "" {
				return errors.New("tool timeout, max rounds, and approval mode require a selected tool harness or MCP config")
			}
			return nil
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
	case "local-files", "code-edit":
		if strings.TrimSpace(config.MCPConfig) == "" && config.MCPConfig != "" {
			return errors.New("MCP config path must not be empty")
		}
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
		if len(config.TestCommands) > 0 {
			if config.ToolHarness != "code-edit" {
				return errors.New("test commands require code-edit tool harness")
			}
			if config.ToolApproval != "full-access" {
				return errors.New("test commands require full-access approval mode")
			}
			if err := validateTestCommands(config.TestCommands); err != nil {
				return err
			}
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

func validateTestCommands(commands []string) error {
	seen := map[string]bool{}
	for _, command := range commands {
		command = strings.TrimSpace(command)
		if command == "" {
			return errors.New("test command must not be empty")
		}
		if seen[command] {
			return fmt.Errorf("duplicate test command: %s", command)
		}
		seen[command] = true
	}
	return nil
}

func (m model) toolPermissionPrompt(task string) (string, string, string, bool) {
	requiredHarness := requiredWriteHarness(task)
	if requiredHarness == "" {
		return "", "", "", false
	}

	root := inferredToolRoot(task)
	if root == "" {
		return "", "", "", false
	}

	switch {
	case m.savedConfig.ToolHarness == requiredHarness:
		if !pathInsideRoot(root, m.savedConfig.ToolRoot) {
			return toolPermissionText(
				"requested filesystem location is outside the active tool root",
				requiredHarness,
				root,
				m.savedConfig.ToolRoot,
			), root, requiredHarness, true
		}
		if m.savedConfig.ToolApproval != "auto-approved-safe" && m.savedConfig.ToolApproval != "full-access" {
			return toolPermissionText(
				"active tool approval mode cannot perform writes without an interactive approval bridge",
				requiredHarness,
				root,
				m.savedConfig.ToolRoot,
			), root, requiredHarness, true
		}
		return "", "", "", false
	case m.savedConfig.ToolHarness == "":
		return toolPermissionText("filesystem tools are off", requiredHarness, root, ""), root, requiredHarness, true
	default:
		return toolPermissionText("active tool harness cannot perform this filesystem action", requiredHarness, root, m.savedConfig.ToolRoot), root, requiredHarness, true
	}
}

func toolPermissionText(reason string, harness string, root string, activeRoot string) string {
	lines := []string{
		"filesystem permission required: " + reason,
		"required harness: " + harness,
		"requested root: " + root,
	}
	if strings.TrimSpace(activeRoot) != "" {
		lines = append(lines, "active root: "+activeRoot)
	}
	lines = append(lines,
		"Run /allow-tools to enable "+harness+" for this root and retry now.",
		"Run /yolo-tools to enable "+harness+" full-access for this root and retry now.",
		"Run /deny-tools to decline.",
	)
	return strings.Join(lines, "\n")
}

func requiredWriteHarness(task string) string {
	switch {
	case codeWriteIntent(task):
		return "code-edit"
	case filesystemWriteIntent(task):
		return "local-files"
	default:
		return ""
	}
}

func codeWriteIntent(task string) bool {
	text := strings.ToLower(task)
	codeVerb := containsAny(text, []string{
		"rewrite", "fix", "patch", "edit", "update", "change", "repair",
	})
	codeNoun := containsAny(text, []string{
		"code", "script", "app", "python", ".py", ".js", ".ts", ".go", ".ex", ".exs", "weather_app.py",
	})
	return codeVerb && codeNoun
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
	case "chat":
		return workflowChat, nil
	case "basic":
		return workflowBasic, nil
	case "agentic":
		return workflowAgentic, nil
	case "auto":
		return workflowAuto, nil
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
		if strings.TrimSpace(m.savedConfig.MCPConfig) != "" {
			return "tools: mcp config=" + m.savedConfig.MCPConfig
		}
		return "tools: off"
	case "local-files", "code-edit":
		status := "tools: " + m.savedConfig.ToolHarness + " root=" + emptyAsNone(m.savedConfig.ToolRoot) + " timeout_ms=" + emptyAsNone(m.savedConfig.ToolTimeout) + " max_rounds=" + emptyAsNone(m.savedConfig.ToolMaxRounds) + " approval=" + emptyAsNone(m.savedConfig.ToolApproval) + " test_commands=" + fmt.Sprintf("%d", len(m.savedConfig.TestCommands))
		if strings.TrimSpace(m.savedConfig.MCPConfig) != "" {
			status += " mcp_config=" + m.savedConfig.MCPConfig
		}
		return status
	default:
		return "tools: unsupported " + m.savedConfig.ToolHarness
	}
}

func runningStatus(config runConfig) string {
	return "running " + config.Provider.Label() + " / " + config.Model + " / mode " + runWorkflowStatus(config.Workflow) + " / " + runToolsStatus(config) + " / " + runSkillsStatus(config) + " / log=" + emptyAsNone(config.LogFile) + "..."
}

func runWorkflowStatus(workflow runWorkflow) string {
	switch workflow {
	case workflowAuto:
		return "progressive-auto"
	case workflowChat, workflowBasic, workflowAgentic:
		return string(workflow)
	default:
		return emptyAsNone(string(workflow))
	}
}

func runToolsStatus(config runConfig) string {
	switch config.ToolHarness {
	case "":
		if strings.TrimSpace(config.MCPConfig) != "" {
			return "tools mcp config=" + config.MCPConfig
		}
		return "tools off"
	case "local-files", "code-edit":
		status := "tools " + config.ToolHarness + " root=" + emptyAsNone(config.ToolRoot) + " timeout_ms=" + emptyAsNone(config.ToolTimeout) + " max_rounds=" + emptyAsNone(config.ToolMaxRounds)
		if strings.TrimSpace(config.MCPConfig) != "" {
			status += " mcp_config=" + config.MCPConfig
		}
		return status
	default:
		return "tools unsupported " + config.ToolHarness
	}
}

func (m model) skillsEnabled() bool {
	return strings.TrimSpace(m.savedConfig.SkillsMode) == "auto" || len(m.savedConfig.SkillNames) > 0
}

func (m model) skillsModeLabel() string {
	if strings.TrimSpace(m.savedConfig.SkillsMode) == "auto" {
		return "auto"
	}
	if len(m.savedConfig.SkillNames) > 0 {
		return fmt.Sprintf("%d explicit", len(m.savedConfig.SkillNames))
	}
	return "off"
}

func (m model) skillsStatus() string {
	status := "skills: " + m.skillsModeLabel()
	if strings.TrimSpace(m.savedConfig.SkillsDir) != "" {
		status += " dir=" + m.savedConfig.SkillsDir
	}
	if len(m.savedConfig.SkillNames) > 0 {
		status += " selected=" + strings.Join(m.savedConfig.SkillNames, ",")
	}
	if m.savedConfig.AllowSkillScripts {
		status += " scripts=on"
	}
	return status
}

func runSkillsStatus(config runConfig) string {
	switch {
	case config.SkillsMode == "auto":
		return "skills auto dir=" + emptyAsNone(config.SkillsDir)
	case len(config.SkillNames) > 0:
		return "skills selected=" + strings.Join(config.SkillNames, ",") + " dir=" + emptyAsNone(config.SkillsDir)
	default:
		return "skills off"
	}
}

func (m *model) applySavedSettings() error {
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
			TestCommands:  m.savedConfig.TestCommands,
			MCPConfig:     m.savedConfig.MCPConfig,
		}); err != nil {
			return fmt.Errorf("invalid saved tools in TUI config: %w", err)
		}
	}

	if strings.TrimSpace(m.savedConfig.MCPConfig) != "" && strings.TrimSpace(m.savedConfig.ToolHarness) == "" {
		if err := validateToolConfig(runConfig{
			Workflow:      workflowBasic,
			Provider:      providerEcho,
			ToolTimeout:   m.savedConfig.ToolTimeout,
			ToolMaxRounds: m.savedConfig.ToolMaxRounds,
			ToolApproval:  m.savedConfig.ToolApproval,
			MCPConfig:     m.savedConfig.MCPConfig,
		}); err != nil {
			return fmt.Errorf("invalid saved MCP config in TUI config: %w", err)
		}
	}

	if err := validateSkillsConfig(runConfig{
		SkillsMode:        m.savedConfig.SkillsMode,
		SkillsDir:         m.savedConfig.SkillsDir,
		SkillNames:        m.savedConfig.SkillNames,
		AllowSkillScripts: m.savedConfig.AllowSkillScripts,
	}); err != nil {
		return fmt.Errorf("invalid saved skills in TUI config: %w", err)
	}

	if m.providerSet {
		m.view = viewChat
		m.messages = []chatMessage{
			{Role: "system", Text: "Loaded saved TUI setup. Use /setup to change it."},
		}
	}

	return nil
}

func removeString(values []string, value string) []string {
	filtered := make([]string, 0, len(values))
	for _, current := range values {
		if current != value {
			filtered = append(filtered, current)
		}
	}
	return filtered
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
	decision := ""
	if strings.TrimSpace(agent.Decision.Mode) != "" {
		decision = "  decision " + agent.Decision.Mode
	}
	return fmt.Sprintf("%s%s  %s  attempt %d%s", indent, agent.ID, status, attempt, decision)
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

func (m *model) scrollEvents(delta int) {
	m.eventAutoScroll = false
	m.eventScroll += delta
	m.clampEventScroll()
}

func (m *model) clampEventScroll() {
	maxScroll := maxEventScroll(len(m.eventLog), liveEventWindowSize)
	if m.eventAutoScroll {
		m.eventScroll = maxScroll
		return
	}
	if m.eventScroll < 0 {
		m.eventScroll = 0
	}
	if m.eventScroll > maxScroll {
		m.eventScroll = maxScroll
	}
}

func maxEventScroll(total int, window int) int {
	if total <= window {
		return 0
	}
	return total - window
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
