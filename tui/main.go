package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

const pendingHarnessMCPBrowser = "mcp-browser"

type summary struct {
	RunID              string                      `json:"run_id"`
	Status             string                      `json:"status"`
	Error              string                      `json:"error"`
	FinalOutput        string                      `json:"final_output"`
	ExecutionStrategy  workflowRoute               `json:"execution_strategy"`
	WorkflowRoute      workflowRoute               `json:"workflow_route"`
	Results            map[string]runResultSummary `json:"results"`
	Skills             []skillSummary              `json:"skills"`
	Checklist          []workItem                  `json:"checklist"`
	Usage              usageSummary                `json:"usage"`
	AgenticPersistence agenticPersistenceSummary   `json:"agentic_persistence"`
	Events             []eventSummary              `json:"events"`
	CapabilityRequired capabilityRequired          `json:"capability_required"`
}

type agenticPersistenceSummary struct {
	Enabled       bool `json:"enabled"`
	Rounds        *int `json:"rounds"`
	ContinueCount int  `json:"continue_count"`
	Completed     bool `json:"completed"`
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
	Requested        string   `json:"requested"`
	Selected         string   `json:"selected"`
	Reason           string   `json:"reason"`
	ToolIntent       string   `json:"tool_intent"`
	Strategy         string   `json:"strategy"`
	ToolsExposed     bool     `json:"tools_exposed"`
	Classifier       string   `json:"classifier"`
	ClassifierModel  string   `json:"classifier_model"`
	Confidence       *float64 `json:"confidence"`
	ClassifiedIntent string   `json:"classified_intent"`
}

type capabilityRequired struct {
	Reason                string   `json:"reason"`
	Intent                string   `json:"intent"`
	Message               string   `json:"message"`
	RequiredHarness       string   `json:"required_harness"`
	RequiredHarnesses     []string `json:"required_harnesses"`
	RequiredApprovalModes []string `json:"required_approval_modes"`
	RequiredMCPTool       string   `json:"required_mcp_tool"`
	RequestedRoot         string   `json:"requested_root"`
	Detail                string   `json:"detail"`
}

func (request capabilityRequired) empty() bool {
	return strings.TrimSpace(request.Reason) == "" &&
		strings.TrimSpace(request.Intent) == "" &&
		strings.TrimSpace(request.RequiredHarness) == "" &&
		len(request.RequiredHarnesses) == 0 &&
		strings.TrimSpace(request.RequiredMCPTool) == ""
}

type usageSummary struct {
	Agents       int     `json:"agents"`
	InputTokens  int     `json:"input_tokens"`
	OutputTokens int     `json:"output_tokens"`
	TotalTokens  int     `json:"total_tokens"`
	CostUSD      float64 `json:"cost_usd"`
}

type compactSummary struct {
	Status       string       `json:"status"`
	Summary      string       `json:"summary"`
	CoveredItems []string     `json:"covered_items"`
	Usage        usageSummary `json:"usage"`
}

type eventSummary struct {
	Type                  string         `json:"type"`
	RunID                 string         `json:"run_id"`
	AgentID               string         `json:"agent_id"`
	PlannerID             string         `json:"planner_id"`
	ParentAgentID         string         `json:"parent_agent_id"`
	DelegatedAgentIDs     []string       `json:"delegated_agent_ids"`
	ProposedAgents        []plannerAgent `json:"proposed_agents"`
	RequestID             string         `json:"request_id"`
	Kind                  string         `json:"kind"`
	Status                string         `json:"status"`
	Decision              string         `json:"decision"`
	Attempt               int            `json:"attempt"`
	NextAttempt           int            `json:"next_attempt"`
	Round                 int            `json:"round"`
	ContinueCount         int            `json:"continue_count"`
	Mode                  string         `json:"mode"`
	ReviewerID            string         `json:"reviewer_id"`
	RevisionCount         int            `json:"revision_count"`
	MaxRevisions          int            `json:"max_revisions"`
	ToolCallID            string         `json:"tool_call_id"`
	Tool                  string         `json:"tool"`
	Permission            string         `json:"permission"`
	ApprovalRisk          string         `json:"approval_risk"`
	ApprovalMode          string         `json:"approval_mode"`
	Capability            string         `json:"capability"`
	Intent                string         `json:"intent"`
	Strategy              string         `json:"strategy"`
	Selected              string         `json:"selected"`
	RequiredHarness       string         `json:"required_harness"`
	RequiredHarnesses     []string       `json:"required_harnesses"`
	RequiredApprovalModes []string       `json:"required_approval_modes"`
	RequiredMCPTool       string         `json:"required_mcp_tool"`
	RequestedRoot         string         `json:"requested_root"`
	RequestedTool         string         `json:"requested_tool"`
	RequestedCommand      string         `json:"requested_command"`
	DurationMS            *int           `json:"duration_ms"`
	Reason                string         `json:"reason"`
	PlannerOutput         string         `json:"planner_output"`
	Summary               string         `json:"summary"`
	Commentary            string         `json:"commentary"`
	Source                string         `json:"source"`
	EvidenceCount         int            `json:"evidence_count"`
	AgentIDs              []string       `json:"agent_ids"`
	ToolCallIDs           []string       `json:"tool_call_ids"`
	Delta                 string         `json:"delta"`
	Measurement           string         `json:"measurement"`
	UsedTokens            int            `json:"used_tokens"`
	ContextWindow         int            `json:"context_window_tokens"`
	ReservedOutput        int            `json:"reserved_output_tokens"`
	AvailableTokens       *int           `json:"available_tokens"`
	UsedPercent           *float64       `json:"used_percent"`
	RemainingPercent      *float64       `json:"remaining_percent"`
	Breakdown             map[string]int `json:"breakdown"`
	Usage                 usageSummary   `json:"usage"`
	InputSummary          map[string]any `json:"input_summary"`
	ResultSummary         map[string]any `json:"result_summary"`
	Details               map[string]any `json:"details"`
	At                    string         `json:"at"`
}

type plannerAgent struct {
	ID           string   `json:"id"`
	Input        string   `json:"input"`
	Instructions string   `json:"instructions"`
	DependsOn    []string `json:"depends_on"`
}

type workItem struct {
	ID            string `json:"id"`
	Kind          string `json:"kind"`
	Label         string `json:"label"`
	ParentID      string `json:"parent_id"`
	Status        string `json:"status"`
	StartedAt     string `json:"started_at"`
	FinishedAt    string `json:"finished_at"`
	DurationMS    *int   `json:"duration_ms"`
	LatestSummary string `json:"latest_summary"`
}

type runResultMsg struct {
	Summary summary
	Raw     string
	Err     error
}

type streamStartedMsg struct {
	Session *streamSession
}

type sessionUserMessageSentMsg struct {
	Session *streamSession
	Err     error
}

type streamLineMsg struct {
	Session *streamSession
	Line    string
}

type permissionDecisionMsg struct {
	RequestID string
	Decision  string
	Err       error
}

type plannerReviewDecisionMsg struct {
	RequestID string
	Decision  string
	Err       error
}

type streamDoneMsg struct {
	Session *streamSession
	Err     error
}

type streamTickMsg struct{}

type skillsCommandMsg struct {
	Action string
	Output string
	Err    error
}

type skillCatalogEntry struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Root        string `json:"root"`
}

type skillListResult struct {
	Skills []skillCatalogEntry `json:"skills"`
}

type compactResultMsg struct {
	Summary compactSummary
	Raw     string
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
	StreamOutput  string
	StreamChunks  int
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

var providers = []provider{
	providerEcho,
	"alibaba",
	"alibaba_cn",
	"anthropic",
	providerOpenAI,
	"google",
	"google_vertex",
	"amazon_bedrock",
	"azure",
	"groq",
	"xai",
	providerOpenRouter,
	"cerebras",
	"meta",
	"zai",
	"zai_coder",
	"zenmux",
	"venice",
	"vllm",
}

type providerField struct {
	Name  string
	Label string
	Env   string
}

type providerSetup struct {
	Label        string
	SecretFields []providerField
	OptionFields []providerField
}

var providerSetups = map[provider]providerSetup{
	providerEcho:       {Label: "Echo"},
	"alibaba":          {Label: "Alibaba Cloud Bailian", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_ALIBABA_API_KEY"}}},
	"alibaba_cn":       {Label: "Alibaba Cloud Bailian China", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_ALIBABA_CN_API_KEY"}}},
	"anthropic":        {Label: "Anthropic", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_ANTHROPIC_API_KEY"}}},
	providerOpenAI:     {Label: "OpenAI", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "OPENAI_API_KEY"}}},
	"google":           {Label: "Google Gemini", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_GOOGLE_API_KEY"}}},
	"google_vertex":    {Label: "Google Vertex AI", SecretFields: []providerField{{Name: "access_token", Label: "Access token", Env: "AGENT_MACHINE_GOOGLE_VERTEX_ACCESS_TOKEN"}}, OptionFields: []providerField{{Name: "project_id", Label: "Project ID"}, {Name: "region", Label: "Region"}}},
	"amazon_bedrock":   {Label: "Amazon Bedrock", SecretFields: []providerField{{Name: "access_key_id", Label: "Access key ID", Env: "AGENT_MACHINE_AMAZON_BEDROCK_ACCESS_KEY_ID"}, {Name: "secret_access_key", Label: "Secret access key", Env: "AGENT_MACHINE_AMAZON_BEDROCK_SECRET_ACCESS_KEY"}}, OptionFields: []providerField{{Name: "region", Label: "Region"}}},
	"azure":            {Label: "Azure OpenAI", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_AZURE_API_KEY"}}, OptionFields: []providerField{{Name: "base_url", Label: "Azure OpenAI base URL"}, {Name: "deployment", Label: "Deployment"}, {Name: "api_version", Label: "API version"}}},
	"groq":             {Label: "Groq", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_GROQ_API_KEY"}}},
	"xai":              {Label: "xAI", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_XAI_API_KEY"}}},
	providerOpenRouter: {Label: "OpenRouter", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "OPENROUTER_API_KEY"}}},
	"cerebras":         {Label: "Cerebras", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_CEREBRAS_API_KEY"}}},
	"meta":             {Label: "Meta Llama", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_META_API_KEY"}}},
	"zai":              {Label: "Z.AI", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_ZAI_API_KEY"}}},
	"zai_coder":        {Label: "Z.AI Coder", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_ZAI_CODER_API_KEY"}}},
	"zenmux":           {Label: "Zenmux", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_ZENMUX_API_KEY"}}},
	"venice":           {Label: "Venice", SecretFields: []providerField{{Name: "api_key", Label: "API key", Env: "AGENT_MACHINE_VENICE_API_KEY"}}},
	"vllm":             {Label: "vLLM", SecretFields: []providerField{{Name: "api_key", Label: "API key or placeholder token", Env: "AGENT_MACHINE_VLLM_API_KEY"}}, OptionFields: []providerField{{Name: "base_url", Label: "Base URL"}}},
}

type runWorkflow string

const (
	workflowAgentic runWorkflow = "agentic"
)

const (
	defaultRunTimeoutMS            = "120000"
	defaultAgenticRunTimeoutMS     = "240000"
	defaultChatSteps               = "1"
	defaultBasicSteps              = "2"
	defaultAgenticSteps            = "6"
	defaultHTTPTimeoutMS           = "120000"
	defaultRouterTimeoutMS         = "5000"
	defaultRouterConfidence        = "0.75"
	defaultRouterModelDirName      = "mdeberta-v3-base-xnli-multilingual-nli-2mil7"
	defaultSessionToolMaxRounds    = "16"
	defaultFilesystemToolTimeout   = "120000"
	defaultFilesystemToolMaxRounds = "16"
	liveEventWindowSize            = 8
)

type runConfig struct {
	Task                      string
	Workflow                  runWorkflow
	Provider                  provider
	APIKey                    string
	ProviderSecrets           map[string]string
	ProviderOptions           map[string]string
	Model                     string
	InputPrice                string
	OutputPrice               string
	HTTPTimeout               string
	RunTimeout                string
	MaxSteps                  string
	AgenticPersistenceRounds  string
	PlannerReviewMaxRevisions string
	ToolHarness               string
	ToolRoot                  string
	ToolTimeout               string
	ToolMaxRounds             string
	ToolApproval              string
	TestCommands              []string
	MCPConfig                 string
	RouterMode                string
	RouterModelDir            string
	RouterTimeout             string
	RouterConfidence          string
	SkillsMode                string
	SkillsDir                 string
	SkillNames                []string
	AllowSkillScripts         bool
	ContextWindow             string
	ContextWarning            string
	ContextTokenizer          string
	ReservedOutput            string
	RunContextCompact         string
	ContextCompactPct         string
	MaxContextCompact         string
	LogFile                   string
	EventLogFile              string
	EventSessionID            string
	ProgressObserver          bool
}

type savedConfig struct {
	OpenAIAPIKey               string                            `json:"openai_api_key,omitempty"`
	OpenRouterAPIKey           string                            `json:"openrouter_api_key,omitempty"`
	Provider                   string                            `json:"provider,omitempty"`
	OpenAIModel                string                            `json:"openai_model,omitempty"`
	OpenRouterModel            string                            `json:"openrouter_model,omitempty"`
	ProviderSecrets            map[string]map[string]string      `json:"provider_secrets,omitempty"`
	ProviderOptions            map[string]map[string]string      `json:"provider_options,omitempty"`
	ProviderModels             map[string]string                 `json:"provider_models,omitempty"`
	ProviderModelMetadata      map[string]map[string]modelOption `json:"provider_model_metadata,omitempty"`
	Theme                      string                            `json:"theme,omitempty"`
	ToolHarness                string                            `json:"tool_harness,omitempty"`
	ToolRoot                   string                            `json:"tool_root,omitempty"`
	ToolTimeout                string                            `json:"tool_timeout_ms,omitempty"`
	ToolMaxRounds              string                            `json:"tool_max_rounds,omitempty"`
	ToolApproval               string                            `json:"tool_approval_mode,omitempty"`
	TestCommands               []string                          `json:"test_commands,omitempty"`
	MCPConfig                  string                            `json:"mcp_config,omitempty"`
	AgenticPersistenceRounds   string                            `json:"agentic_persistence_rounds,omitempty"`
	AgenticPersistenceMaxSteps string                            `json:"agentic_persistence_max_steps,omitempty"`
	AgenticPersistenceTimeout  string                            `json:"agentic_persistence_timeout_ms,omitempty"`
	PlannerReviewMaxRevisions  string                            `json:"planner_review_max_revisions,omitempty"`
	RouterMode                 string                            `json:"router_mode,omitempty"`
	RouterModelDir             string                            `json:"router_model_dir,omitempty"`
	RouterTimeout              string                            `json:"router_timeout_ms,omitempty"`
	RouterConfidence           string                            `json:"router_confidence_threshold,omitempty"`
	SkillsMode                 string                            `json:"skills_mode,omitempty"`
	SkillsDir                  string                            `json:"skills_dir,omitempty"`
	SkillNames                 []string                          `json:"skill_names,omitempty"`
	AllowSkillScripts          bool                              `json:"allow_skill_scripts,omitempty"`
	ContextWindow              string                            `json:"context_window_tokens,omitempty"`
	ContextWarning             string                            `json:"context_warning_percent,omitempty"`
	ContextTokenizer           string                            `json:"context_tokenizer_path,omitempty"`
	ReservedOutput             string                            `json:"reserved_output_tokens,omitempty"`
	RunContextCompact          string                            `json:"run_context_compaction,omitempty"`
	ContextCompactPct          string                            `json:"run_context_compact_percent,omitempty"`
	MaxContextCompact          string                            `json:"max_context_compactions,omitempty"`
	ProgressObserver           bool                              `json:"progress_observer,omitempty"`
}

type startupOptions struct {
	MCPConfig        string
	ToolTimeout      string
	ToolMaxRounds    string
	ToolApproval     string
	HasMCPConfig     bool
	HasToolTimeout   bool
	HasToolMaxRounds bool
	HasToolApproval  bool
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
	input                      textinput.Model
	provider                   provider
	providerSet                bool
	providerPickerOpen         bool
	providerPickerIndex        int
	theme                      tuiTheme
	savedConfig                savedConfig
	configPath                 string
	workingDir                 string
	modelOptions               []modelOption
	modelIndex                 int
	selectedModel              string
	pendingRunAfterModelLoad   string
	modelStatus                string
	modelPickerOpen            bool
	modelPickerIndex           int
	modelPickerPending         bool
	modelPickerQuery           string
	skillOptions               []skillCatalogEntry
	skillPickerOpen            bool
	skillPickerIndex           int
	skillPickerQuery           string
	skillStatus                string
	messages                   []chatMessage
	chatScroll                 int
	inputHistory               []string
	historyIndex               int
	historyDraft               string
	queuedMessages             []queuedMessage
	nextQueueID                int
	view                       viewMode
	selectedAgent              string
	selectedAgentIndex         int
	running                    bool
	activeConfig               runConfig
	lastSummary                summary
	sessionUsage               usageSummary
	countedSummaryRunIDs       map[string]struct{}
	liveUsageByRunID           map[string]usageSummary
	gitBranchStatus            string
	agents                     map[string]agentState
	agentOrder                 []string
	workItems                  map[string]workItem
	workOrder                  []string
	eventLog                   []eventSummary
	progressComments           []eventSummary
	latestContextBudget        *eventSummary
	eventScroll                int
	eventAutoScroll            bool
	streamFrame                int
	liveAssistant              string
	raw                        string
	stream                     *streamSession
	pendingToolTask            string
	pendingToolRoot            string
	pendingToolHarness         string
	pendingToolChoice          int
	pendingPermissions         map[string]eventSummary
	pendingPermissionID        []string
	pendingPermissionChoice    int
	pendingPlannerReviews      map[string]eventSummary
	pendingPlannerReviewID     []string
	pendingPlannerReviewChoice int
	eventSessionID             string
	eventLogFile               string
	width                      int
	height                     int
}

func initialModel() (model, error) {
	return initialModelWithArgs(nil)
}

func initialModelWithArgs(args []string) (model, error) {
	startup, err := parseStartupOptions(args)
	if err != nil {
		return model{}, err
	}

	configResolution, err := resolveTUIConfig()
	if err != nil {
		return model{}, err
	}
	configPath := configResolution.Path

	savedConfig, loadedLegacyConfig, err := loadResolvedSavedConfig(configResolution)
	if err != nil {
		return model{}, err
	}
	migratedRouterDefault := migrateLegacyLocalRouterDefault(&savedConfig, configPath)
	migratedProviderSettings := migrateLegacyProviderSettings(&savedConfig)
	migratedToolRoot, err := migrateSavedToolRootToWorkingDir(&savedConfig, configResolution.WorkingDir)
	if err != nil {
		return model{}, err
	}
	migratedMCPToolMaxRounds := migrateLegacyMCPToolMaxRounds(&savedConfig)
	if err := applyStartupOptions(&savedConfig, startup); err != nil {
		return model{}, err
	}
	if err := migrateManagedMCPConfig(configPath, &savedConfig); err != nil {
		return model{}, err
	}
	initializedSkillsDir, err := initializeDefaultSkillsDir(&savedConfig)
	if err != nil {
		return model{}, err
	}
	if startup.hasOverrides() || migratedRouterDefault || migratedProviderSettings || migratedToolRoot || migratedMCPToolMaxRounds || loadedLegacyConfig || initializedSkillsDir {
		if err := saveSavedConfig(configPath, savedConfig); err != nil {
			return model{}, err
		}
	}

	input := textinput.New()
	input.Placeholder = "Message or /help"
	input.CharLimit = 1000
	input.Width = 96
	input.Focus()

	sessionID := newSessionID()

	m := model{
		input:          input,
		savedConfig:    savedConfig,
		configPath:     configPath,
		workingDir:     configResolution.WorkingDir,
		eventSessionID: sessionID,
		eventLogFile:   sessionEventLogPath(configPath, sessionID),
		messages: []chatMessage{
			{Role: "system", Text: "Open Setup and select a provider before running AgentMachine."},
		},
		view:      viewSetup,
		agents:    map[string]agentState{},
		workItems: map[string]workItem{},
	}

	if err := m.applySavedSettings(); err != nil {
		return model{}, err
	}
	m.refreshGitBranchStatus()

	return m, nil
}

func parseStartupOptions(args []string) (startupOptions, error) {
	var options startupOptions
	if len(args) == 0 {
		return options, nil
	}

	flags := flag.NewFlagSet("agent-machine-tui", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&options.MCPConfig, "mcp-config", "", "MCP config path")
	flags.StringVar(&options.ToolTimeout, "tool-timeout-ms", "", "tool timeout in milliseconds")
	flags.StringVar(&options.ToolMaxRounds, "tool-max-rounds", "", "tool max provider/tool rounds")
	flags.StringVar(&options.ToolApproval, "tool-approval-mode", "", "tool approval mode")

	if err := flags.Parse(args); err != nil {
		return options, err
	}
	if flags.NArg() != 0 {
		return options, fmt.Errorf("unexpected TUI argument: %s", flags.Arg(0))
	}

	flags.Visit(func(flag *flag.Flag) {
		switch flag.Name {
		case "mcp-config":
			options.HasMCPConfig = true
		case "tool-timeout-ms":
			options.HasToolTimeout = true
		case "tool-max-rounds":
			options.HasToolMaxRounds = true
		case "tool-approval-mode":
			options.HasToolApproval = true
		}
	})
	return options, nil
}

func (options startupOptions) hasOverrides() bool {
	return options.HasMCPConfig ||
		options.HasToolTimeout ||
		options.HasToolMaxRounds ||
		options.HasToolApproval
}

func applyStartupOptions(config *savedConfig, options startupOptions) error {
	if !options.hasOverrides() {
		return nil
	}

	if !options.HasMCPConfig {
		return errors.New("TUI startup tool budget flags require --mcp-config")
	}
	if strings.TrimSpace(options.MCPConfig) == "" {
		return errors.New("TUI startup --mcp-config must not be empty")
	}
	if !options.HasToolTimeout || !options.HasToolMaxRounds || !options.HasToolApproval {
		return errors.New("TUI startup --mcp-config requires --tool-timeout-ms, --tool-max-rounds, and --tool-approval-mode")
	}

	config.MCPConfig = strings.TrimSpace(options.MCPConfig)
	config.ToolTimeout = options.ToolTimeout
	config.ToolMaxRounds = options.ToolMaxRounds
	config.ToolApproval = options.ToolApproval

	return validateToolConfig(runConfig{
		ToolHarness:   config.ToolHarness,
		ToolRoot:      config.ToolRoot,
		ToolTimeout:   config.ToolTimeout,
		ToolMaxRounds: config.ToolMaxRounds,
		ToolApproval:  config.ToolApproval,
		TestCommands:  config.TestCommands,
		MCPConfig:     config.MCPConfig,
	})
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
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		if msg.Width > 4 {
			m.input.Width = msg.Width - 4
		}
		m.clampChatScroll()
		return m, nil

	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return m, tea.Quit
		}

		if m.providerPickerOpen {
			switch msg.String() {
			case "esc":
				m.providerPickerOpen = false
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider picker canceled"})
				return m, nil
			case "up":
				m.moveProviderPicker(-1)
				return m, nil
			case "down":
				m.moveProviderPicker(1)
				return m, nil
			case "enter":
				return m.selectProviderFromPicker()
			}
			return m, nil
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

		if m.skillPickerOpen {
			switch msg.String() {
			case "esc":
				m.skillPickerOpen = false
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "skill picker canceled"})
				return m, nil
			case "up":
				m.moveSkillPicker(-1)
				return m, nil
			case "down":
				m.moveSkillPicker(1)
				return m, nil
			case "enter":
				return m.selectSkillFromPicker()
			case "backspace", "ctrl+h":
				m.removeLastSkillPickerQueryRune()
				return m, nil
			case "delete", "ctrl+u":
				m.setSkillPickerQuery("")
				return m, nil
			}
			if len(msg.Runes) > 0 {
				m.setSkillPickerQuery(m.skillPickerQuery + string(msg.Runes))
				return m, nil
			}
			return m, nil
		}

		if request, ok := m.currentPendingPlannerReview(); ok && m.view == viewChat {
			if strings.TrimSpace(m.input.Value()) == "" {
				switch msg.String() {
				case "up", "k":
					m.movePendingPlannerReviewChoice(-1)
					return m, nil
				case "down", "j":
					m.movePendingPlannerReviewChoice(1)
					return m, nil
				case "enter":
					return m.applyPendingPlannerReviewChoice(request)
				case "a":
					m.pendingPlannerReviewChoice = 0
					return m.applyPendingPlannerReviewChoice(request)
				case "d", "esc":
					m.pendingPlannerReviewChoice = pendingPlannerReviewDeclineChoice()
					return m.applyPendingPlannerReviewChoice(request)
				}
			}
		}

		if request, ok := m.currentPendingPermission(); ok && m.view == viewChat {
			if strings.TrimSpace(m.input.Value()) == "" {
				switch msg.String() {
				case "up", "k":
					m.movePendingPermissionChoice(-1)
					return m, nil
				case "down", "j":
					m.movePendingPermissionChoice(1)
					return m, nil
				case "enter":
					return m.applyPendingPermissionChoice(request)
				case "a":
					m.pendingPermissionChoice = 0
					return m.applyPendingPermissionChoice(request)
				case "d", "esc":
					m.pendingPermissionChoice = pendingPermissionDenyChoice()
					return m.applyPendingPermissionChoice(request)
				}
			}
		}

		if m.pendingToolTask != "" && m.view == viewChat && !m.running && strings.TrimSpace(m.input.Value()) == "" {
			switch msg.String() {
			case "up", "k":
				m.movePendingToolChoice(-1)
				return m, nil
			case "down", "j":
				m.movePendingToolChoice(1)
				return m, nil
			case "enter":
				return m.applyPendingToolChoice()
			case "a":
				m.pendingToolChoice = 0
				return m.applyPendingToolChoice()
			case "y":
				m.pendingToolChoice = pendingFullAccessChoice(m.pendingToolOptions())
				return m.applyPendingToolChoice()
			case "d", "esc":
				m.pendingToolChoice = len(m.pendingToolOptions()) - 1
				return m.applyPendingToolChoice()
			}
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
		case "ctrl+p":
			if m.view == viewChat {
				m.scrollChat(1)
				return m, nil
			}
		case "ctrl+n":
			if m.view == viewChat {
				m.scrollChat(-1)
				return m, nil
			}
		case "ctrl+b":
			if m.view == viewChat {
				m.scrollChat(m.chatPageSize())
				return m, nil
			}
		case "ctrl+f":
			if m.view == viewChat {
				m.scrollChat(-m.chatPageSize())
				return m, nil
			}
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
			if m.view == viewChat && !m.running {
				m.scrollChat(m.chatPageSize())
				return m, nil
			}
			if m.running && m.view == viewChat {
				m.scrollEvents(-5)
				return m, nil
			}
		case "pgdown":
			if m.view == viewChat && !m.running {
				m.scrollChat(-m.chatPageSize())
				return m, nil
			}
			if m.running && m.view == viewChat {
				m.scrollEvents(5)
				return m, nil
			}
		case "home":
			if m.view == viewChat && !m.running {
				m.chatScroll = m.maxChatScroll()
				return m, nil
			}
			if m.running && m.view == viewChat {
				m.eventScroll = 0
				m.eventAutoScroll = false
				return m, nil
			}
		case "end":
			if m.view == viewChat && !m.running {
				m.chatScroll = 0
				return m, nil
			}
			if m.running && m.view == viewChat {
				m.eventAutoScroll = true
				m.clampEventScroll()
				return m, nil
			}
		}

	case runResultMsg:
		m.running = false
		m.pendingPlannerReviews = nil
		m.pendingPlannerReviewID = nil
		m.pendingPlannerReviewChoice = 0
		m.pendingPermissions = nil
		m.pendingPermissionID = nil
		m.pendingPermissionChoice = 0
		m.lastSummary = msg.Summary
		m.recordSummaryUsage(msg.Summary)
		m.refreshGitBranchStatus()
		m.raw = msg.Raw
		m.view = viewChat

		if msg.Err != nil {
			if updated, handled := m.withCapabilityRequired(msg.Summary.CapabilityRequired); handled {
				return updated, nil
			}
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\n" + msg.Err.Error()})
		} else {
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: summaryDisplayText(msg.Summary)})
		}
		m.chatScroll = 0
		return m.startNextQueuedRun()

	case streamStartedMsg:
		m.stream = msg.Session
		return m, tea.Batch(readStreamCommand(msg.Session), streamTickCommand())

	case sessionUserMessageSentMsg:
		if msg.Session != m.stream {
			return m, nil
		}
		if msg.Err != nil {
			m.running = false
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\n" + msg.Err.Error()})
			m.chatScroll = 0
			return m.startNextQueuedRun()
		}
		return m, nil

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
		m.refreshGitBranchStatus()
		m.pendingPermissions = nil
		m.pendingPermissionID = nil
		m.pendingPermissionChoice = 0
		m.pendingPlannerReviews = nil
		m.pendingPlannerReviewID = nil
		m.pendingPlannerReviewChoice = 0
		m.view = viewChat
		if msg.Session != nil && msg.Session.persistent && msg.Err == nil {
			m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\nAgentMachine session ended"})
		} else if msg.Err != nil {
			if updated, handled := m.withCapabilityRequired(m.lastSummary.CapabilityRequired); handled {
				return updated, nil
			}
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
		m.chatScroll = 0
		return m.startNextQueuedRun()

	case permissionDecisionMsg:
		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "permission decision failed: " + msg.Err.Error()})
		}
		return m, nil

	case plannerReviewDecisionMsg:
		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "planner review decision failed: " + msg.Err.Error()})
		}
		return m, nil

	case skillsCommandMsg:
		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "skills command failed:\n" + msg.Err.Error()})
		} else if msg.Action == "list" {
			parsed, err := parseSkillListResult(msg.Output)
			if err != nil {
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "skills list parse failed:\n" + err.Error()})
				return m, nil
			}
			m.skillOptions = parsed.Skills
			m.skillPickerQuery = ""
			m.skillPickerIndex = selectedSkillIndex(m.skillOptions, m.savedConfig.SkillNames)
			m.skillStatus = fmt.Sprintf("loaded %d skills", len(m.skillOptions))
			if len(m.skillOptions) == 0 {
				m.skillPickerOpen = false
				m.messages = append(m.messages, chatMessage{Role: "system", Text: "no installed skills in " + emptyAsNone(m.savedConfig.SkillsDir)})
			} else {
				m.modelPickerOpen = false
				m.modelPickerPending = false
				m.view = viewChat
				m.skillPickerOpen = true
				m.messages = append(m.messages, chatMessage{Role: "system", Text: m.skillStatus})
			}
		} else {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: strings.TrimSpace(msg.Output)})
		}
		return m, nil

	case compactResultMsg:
		m.view = viewChat
		if msg.Err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "compact failed:\n" + msg.Err.Error()})
			return m, nil
		}
		m.recordUsage("", msg.Summary.Usage)
		m.messages = []chatMessage{{Role: "summary", Text: compactConversationSummaryText(msg.Summary)}}
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
			m.pendingRunAfterModelLoad = ""
			m.modelStatus = "model load failed: " + msg.Err.Error()
			m.messages = append(m.messages, chatMessage{Role: "system", Text: m.modelStatus})
			return m, nil
		}

		m.modelOptions = msg.Models
		m.modelIndex = selectedModelIndex(msg.Models, m.selectedModel)
		if len(msg.Models) > 0 {
			m.selectedModel = msg.Models[m.modelIndex].ID
			m.modelPickerIndex = m.modelIndex
			m.savedConfig.rememberModel(m.provider, m.selectedModel)
			if m.rememberSelectedModelMetadata() && strings.TrimSpace(m.configPath) != "" {
				if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
					m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
				}
			}
		}
		m.modelStatus = fmt.Sprintf("loaded %d models", len(msg.Models))
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.modelStatus + " for " + m.provider.Label()})
		if m.modelPickerPending {
			m.modelPickerOpen = len(m.modelOptions) > 0
			m.modelPickerPending = false
		}
		if strings.TrimSpace(m.pendingRunAfterModelLoad) != "" {
			task := m.pendingRunAfterModelLoad
			m.pendingRunAfterModelLoad = ""
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "starting after model metadata load"})
			return m.startRun(task)
		}
		return m, nil
	}

	if m.view != viewAgents && m.view != viewAgentDetail && !m.modelPickerOpen && !m.skillPickerOpen {
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

	if request, ok := m.currentPendingPlannerReview(); ok && m.view == viewChat {
		m.input.SetValue("")
		if decision, ok := plannerReviewDecisionFromInput(text); ok {
			return m.answerPendingPlannerReview(request, decision, "")
		}
		return m.answerPendingPlannerReview(request, "revise", text)
	}

	if request, ok := m.currentPendingPermission(); ok && m.view == viewChat {
		if decision, ok := runtimePermissionDecisionFromInput(text); ok {
			m.input.SetValue("")
			return m.answerPendingPermission(request, decision)
		}
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
	runTask := permissionTask
	config, err := resolveConfig(m.runConfig(runTask))
	if err != nil {
		if m.shouldLoadModelsForMissingPricing(err) {
			m.pendingRunAfterModelLoad = task
			m.modelStatus = "loading models..."
			m.messages = append(m.messages, chatMessage{
				Role: "system",
				Text: "pricing metadata is missing for model " + strconv.Quote(m.selectedModel) + "; loading models for " + m.provider.Label() + "...",
			})
			return m, m.loadModelsCommand()
		}
		return m.withRunPreparationError(err), nil
	}
	m.refreshGitBranchStatus()
	config.LogFile = nextRunLogPath(m.configPath)

	if err := validateConfig(config); err != nil {
		return m.withRunPreparationError(err), nil
	}
	if err := validateRunnableConfig(config); err != nil {
		return m.withRunPreparationError(err), nil
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
	m.chatScroll = 0
	previousConfig := m.activeConfig
	reuseSession := m.stream != nil && m.stream.persistent && sessionReusable(previousConfig, config)
	m.running = true
	m.view = viewChat
	m.activeConfig = config
	m.lastSummary = summary{}
	m.raw = ""
	if !reuseSession {
		m.agents = map[string]agentState{}
		m.agentOrder = nil
		m.workItems = map[string]workItem{}
		m.workOrder = nil
		m.eventLog = nil
	}
	m.progressComments = nil
	m.latestContextBudget = nil
	m.eventScroll = 0
	m.eventAutoScroll = true
	m.streamFrame = 0
	m.liveAssistant = ""
	m.selectedAgent = ""
	m.selectedAgentIndex = 0
	if reuseSession {
		return m, tea.Batch(sendSessionUserMessageCommand(m.stream, config), streamTickCommand())
	}
	if m.stream != nil && m.stream.persistent {
		closeStreamSession(m.stream)
		m.stream = nil
	}
	return m, startStreamingCommand(config)
}

func (m model) withRunPreparationError(err error) model {
	m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
	if !m.providerSet {
		m.view = viewSetup
	} else {
		m.view = viewChat
	}
	return m
}

func (m model) shouldLoadModelsForMissingPricing(err error) bool {
	return err != nil &&
		m.providerSet &&
		m.provider != providerEcho &&
		strings.TrimSpace(m.selectedModel) != "" &&
		strings.Contains(err.Error(), "pricing is missing for model")
}

func (m model) withCapabilityRequired(request capabilityRequired) (model, bool) {
	if request.empty() {
		return m, false
	}

	harness := pendingHarnessForCapability(request)
	if harness == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: capabilityRequiredText(request)})
		m.view = viewChat
		return m, true
	}

	if harness == pendingHarnessMCPBrowser {
		if strings.TrimSpace(m.savedConfig.MCPConfig) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: capabilityRequiredText(request)})
			m.view = viewChat
			return m, true
		}
		return m.withPendingToolRequest("", harness, mcpBrowserPermissionText(m.savedConfig.MCPConfig))
	}

	root := strings.TrimSpace(request.RequestedRoot)
	if root == "" {
		root = strings.TrimSpace(m.inferCapabilityRoot(request, harness))
	}
	if root == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: capabilityRootRequiredText(request, harness)})
		m.view = viewChat
		return m, true
	}

	return m.withPendingToolRequest(
		root,
		harness,
		toolPermissionText(capabilityReasonText(request), harness, root, m.savedConfig.ToolRoot),
	)
}

func (m model) withPendingToolRequest(root string, harness string, prompt string) (model, bool) {
	task := m.latestUserTask()
	if strings.TrimSpace(task) == "" {
		task = m.activeConfig.Task
	}
	m.pendingToolTask = task
	m.pendingToolRoot = root
	m.pendingToolHarness = harness
	m.pendingToolChoice = 0
	m.messages = append(m.messages, chatMessage{Role: "system", Text: prompt})
	m.view = viewChat
	return m, true
}

func pendingHarnessForCapability(request capabilityRequired) string {
	switch request.Reason {
	case "missing_browser_approval":
		if request.RequiredHarness == "mcp" && request.RequiredMCPTool == "browser_navigate" {
			return pendingHarnessMCPBrowser
		}
	case "missing_write_harness", "missing_code_edit_harness", "missing_test_code_edit_harness", "missing_test_approval":
		if request.RequiredHarness == "local-files" || request.RequiredHarness == "code-edit" {
			return request.RequiredHarness
		}
	case "insufficient_tool_timeout", "insufficient_tool_max_rounds":
		if request.RequiredHarness == "mcp" && request.RequiredMCPTool == "browser_navigate" {
			return pendingHarnessMCPBrowser
		}
		if request.RequiredHarness == "local-files" || request.RequiredHarness == "code-edit" {
			return request.RequiredHarness
		}
	}
	return ""
}

func (m model) inferCapabilityRoot(request capabilityRequired, harness string) string {
	if harness != "local-files" || request.Reason != "missing_write_harness" {
		return ""
	}

	task := strings.TrimSpace(m.latestUserTask())
	if task == "" {
		task = strings.TrimSpace(m.activeConfig.Task)
	}
	if task == "" {
		return ""
	}

	normalized := strings.ToLower(task)
	if mentionsHomeRoot(normalized) {
		home, err := os.UserHomeDir()
		if err == nil && strings.TrimSpace(home) != "" {
			return filepath.Clean(home)
		}
	}
	if mentionsWorkingDirectoryRoot(normalized) {
		return filepath.Clean(m.toolRootBaseDir())
	}
	return ""
}

func mentionsHomeRoot(text string) bool {
	return strings.Contains(text, "~/") ||
		strings.Contains(text, "home folder") ||
		strings.Contains(text, "home directory") ||
		strings.Contains(text, "my home") ||
		strings.Contains(text, "in home ")
}

func mentionsWorkingDirectoryRoot(text string) bool {
	return strings.Contains(text, "current folder") ||
		strings.Contains(text, "current directory") ||
		strings.Contains(text, "working directory") ||
		strings.Contains(text, "this folder") ||
		strings.Contains(text, "this directory") ||
		strings.Contains(text, "cwd")
}

func capabilityReasonText(request capabilityRequired) string {
	parts := []string{emptyAs(request.Reason, "capability_required")}
	if len(request.RequiredApprovalModes) > 0 {
		parts = append(parts, "approval modes: "+strings.Join(request.RequiredApprovalModes, ", "))
	}
	if strings.TrimSpace(request.Detail) != "" {
		parts = append(parts, request.Detail)
	}
	return strings.Join(parts, "; ")
}

func capabilityRequiredText(request capabilityRequired) string {
	lines := []string{
		"runtime capability required: " + emptyAs(request.Reason, "capability_required"),
	}
	if strings.TrimSpace(request.Intent) != "" {
		lines = append(lines, "intent: "+request.Intent)
	}
	if strings.TrimSpace(request.RequiredHarness) != "" {
		lines = append(lines, "required harness: "+request.RequiredHarness)
	}
	if len(request.RequiredHarnesses) > 0 {
		lines = append(lines, "required harnesses: "+strings.Join(request.RequiredHarnesses, ", "))
	}
	if len(request.RequiredApprovalModes) > 0 {
		lines = append(lines, "required approval modes: "+strings.Join(request.RequiredApprovalModes, ", "))
	}
	if strings.TrimSpace(request.RequiredMCPTool) != "" {
		lines = append(lines, "required MCP tool: "+request.RequiredMCPTool)
	}
	if strings.TrimSpace(request.Detail) != "" {
		lines = append(lines, "detail: "+request.Detail)
	}
	lines = append(lines, "Configure the required runtime capability explicitly and retry.")
	return strings.Join(lines, "\n")
}

func capabilityRootRequiredText(request capabilityRequired, harness string) string {
	lines := []string{
		"runtime capability required: " + emptyAs(request.Reason, "capability_required"),
		"required harness: " + harness,
		"tool root is required",
		"Run /tools " + harness + " <root> <timeout-ms> <max-rounds> <approval-mode> and retry.",
	}
	if len(request.RequiredApprovalModes) > 0 {
		lines = append(lines, "required approval modes: "+strings.Join(request.RequiredApprovalModes, ", "))
	}
	return strings.Join(lines, "\n")
}

func (m model) latestUserTask() string {
	for index := len(m.messages) - 1; index >= 0; index-- {
		if m.messages[index].Role == "user" && strings.TrimSpace(m.messages[index].Text) != "" {
			return m.messages[index].Text
		}
	}
	return ""
}

func (m model) taskWithConversationContext(task string) string {
	history := recentConversationMessages(m.messages, 6)
	if len(history) == 0 {
		return task
	}

	lines := []string{"Conversation context:"}
	for _, message := range history {
		if message.Role == "summary" {
			lines = append(lines, "Compacted conversation summary: "+compactContextText(stripCompactedConversationPrefix(message.Text)))
			continue
		}
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

func newSessionID() string {
	return time.Now().UTC().Format("20060102T150405.000000000Z")
}

func sessionEventLogPath(configPath string, sessionID string) string {
	return filepath.Join(filepath.Dir(configPath), "logs", "session-"+sessionID+".jsonl")
}

func recentConversationMessages(messages []chatMessage, limit int) []chatMessage {
	selected := make([]chatMessage, 0, limit)
	var latestSummary *chatMessage
	for i := len(messages) - 1; i >= 0; i-- {
		message := messages[i]
		if message.Role == "summary" && strings.TrimSpace(message.Text) != "" {
			copied := message
			latestSummary = &copied
			break
		}
	}
	for i := len(messages) - 1; i >= 0 && len(selected) < limit; i-- {
		message := messages[i]
		if message.Role != "user" {
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
	if latestSummary != nil {
		selected = append([]chatMessage{*latestSummary}, selected...)
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

func compactConversationSummaryText(summary compactSummary) string {
	return "Compacted conversation summary:\n" + strings.TrimSpace(summary.Summary)
}

func stripCompactedConversationPrefix(text string) string {
	trimmed := strings.TrimSpace(text)
	prefix := "Compacted conversation summary:"
	if strings.HasPrefix(trimmed, prefix) {
		return strings.TrimSpace(strings.TrimPrefix(trimmed, prefix))
	}
	return trimmed
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

	if m.running && name != "queue" && name != "theme" && name != "scroll" {
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
	case "router":
		return m.handleRouterCommand(args)
	case "router-timeout":
		return m.handleRouterTimeoutCommand(args)
	case "router-confidence":
		return m.handleRouterConfidenceCommand(args)
	case "router-status":
		return m.handleRouterStatusCommand(args)
	case "provider":
		return m.handleProviderCommand(args)
	case "theme":
		return m.handleThemeCommand(args)
	case "key":
		return m.handleKeyCommand(args)
	case "provider-secret":
		return m.handleProviderSecretCommand(args)
	case "provider-option":
		return m.handleProviderOptionCommand(args)
	case "compact":
		return m.handleCompactCommand(args)
	case "context":
		return m.handleContextCommand(args)
	case "progress":
		return m.handleProgressCommand(args)
	case "planner-review":
		return m.handlePlannerReviewCommand(args)
	case "agentic-persistence":
		return m.handleAgenticPersistenceCommand(args)
	case "tools":
		return m.handleToolsCommand(args)
	case "skills":
		return m.handleSkillsCommand(args)
	case "test-command":
		return m.handleTestCommand(args)
	case "mcp-config":
		return m.handleMCPConfigCommand(args)
	case "mcp":
		return m.handleMCPCommand(args)
	case "allow-tools":
		return m.handleAllowToolsCommand(args, "ask-before-write")
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
	case "send-agent":
		return m.handleSendAgentCommand(args)
	case "read-agent":
		return m.handleReadAgentCommand(args)
	case "queue":
		return m.handleQueueCommand(args)
	case "scroll":
		return m.handleScrollCommand(args)
	case "back":
		m.back()
	case "clear":
		m.messages = nil
		m.chatScroll = 0
		m.view = viewChat
	case "quit", "q":
		if m.stream != nil && m.stream.persistent {
			closeStreamSession(m.stream)
		}
		return m, tea.Quit
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown command: /" + name})
	}

	return m, nil
}

func (m model) handleThemeCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "theme: " + string(m.activeTheme()) + " (available: " + themeOptionsText() + ")"})
		return m, nil
	}
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /theme " + themeOptionsText()})
		return m, nil
	}

	theme, err := parseTUITheme(args[0])
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /theme " + themeOptionsText() + "\n" + err.Error()})
		return m, nil
	}

	m.theme = theme
	m.savedConfig.Theme = string(theme)
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "theme set to " + string(theme)})
	return m, nil
}

func (m model) handleScrollCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /scroll up|down|top|bottom"})
		return m, nil
	}
	switch args[0] {
	case "up":
		m.scrollChat(m.chatPageSize())
	case "down":
		m.scrollChat(-m.chatPageSize())
	case "top":
		m.chatScroll = m.maxChatScroll()
	case "bottom":
		m.chatScroll = 0
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /scroll up|down|top|bottom"})
	}
	return m, nil
}

func (m model) handleCompactCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /compact"})
		return m, nil
	}
	if !m.providerSet {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider before compacting conversation"})
		m.view = viewSetup
		return m, nil
	}

	messages := compactableConversationMessages(m.messages)
	if len(messages) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "conversation compaction requires user, assistant, or summary messages"})
		return m, nil
	}

	config, err := resolveConfig(m.runConfig("compact conversation"))
	if err != nil {
		return m.withRunPreparationError(err), nil
	}
	if err := validateCompactConfig(config); err != nil {
		return m.withRunPreparationError(err), nil
	}

	m.rememberAPIKey(config.Provider, config.APIKey)
	if config.Provider != providerEcho {
		if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
	}

	m.messages = append(m.messages, chatMessage{Role: "system", Text: "compacting conversation..."})
	m.view = viewChat
	return m, compactCommand(config, messages)
}

func compactableConversationMessages(messages []chatMessage) []chatMessage {
	out := make([]chatMessage, 0, len(messages))
	for _, message := range messages {
		if strings.TrimSpace(message.Text) == "" {
			continue
		}
		switch message.Role {
		case "user", "assistant", "summary":
			out = append(out, chatMessage{
				Role: message.Role,
				Text: stripCompactedConversationPrefix(message.Text),
			})
		}
	}
	return out
}

func (m model) handleContextCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 || args[0] == "status" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.contextStatus()})
		return m, nil
	}

	switch args[0] {
	case "window":
		return m.handleContextWindowCommand(args[1:])
	case "tokenizer":
		return m.handleContextTokenizerCommand(args[1:])
	case "reserve":
		return m.handleContextReserveCommand(args[1:])
	case "run-compaction":
		return m.handleRunContextCompactionCommand(args[1:])
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /context [status]|window <tokens> [warning-percent]|window off|tokenizer <path>|tokenizer off|reserve <tokens>|reserve off|run-compaction on <compact-percent> <max-compactions>|run-compaction off"})
		return m, nil
	}
}

func (m model) handleContextWindowCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 1 && args[0] == "off" {
		m.savedConfig.ContextWindow = ""
		m.savedConfig.ContextWarning = ""
		m.savedConfig.RunContextCompact = ""
		m.savedConfig.ContextCompactPct = ""
		m.savedConfig.MaxContextCompact = ""
		return m.saveContextConfig("context window cleared")
	}
	if len(args) != 1 && len(args) != 2 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /context window <tokens> [warning-percent]|off"})
		return m, nil
	}
	if err := validatePositiveInt(args[0], "context window tokens"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	warning := ""
	if len(args) == 2 {
		if err := validatePercent(args[1], "context warning percent"); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		warning = args[1]
	}

	m.savedConfig.ContextWindow = args[0]
	m.savedConfig.ContextWarning = warning
	return m.saveContextConfig("context window set to " + args[0] + " tokens")
}

func (m model) handleContextTokenizerCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 1 && args[0] == "off" {
		m.savedConfig.ContextTokenizer = ""
		return m.saveContextConfig("context tokenizer cleared")
	}
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /context tokenizer <path>|off"})
		return m, nil
	}
	path := strings.TrimSpace(args[0])
	if err := validateExistingFile(path, "context tokenizer path"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.savedConfig.ContextTokenizer = path
	return m.saveContextConfig("context tokenizer set to " + path)
}

func (m model) handleContextReserveCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 1 && args[0] == "off" {
		m.savedConfig.ReservedOutput = ""
		return m.saveContextConfig("reserved output tokens cleared")
	}
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /context reserve <tokens>|off"})
		return m, nil
	}
	if err := validatePositiveInt(args[0], "reserved output tokens"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.savedConfig.ReservedOutput = args[0]
	return m.saveContextConfig("reserved output tokens set to " + args[0])
}

func (m model) handleRunContextCompactionCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 1 && args[0] == "off" {
		m.savedConfig.RunContextCompact = ""
		m.savedConfig.ContextCompactPct = ""
		m.savedConfig.MaxContextCompact = ""
		return m.saveContextConfig("run-context compaction off")
	}
	if len(args) != 3 || args[0] != "on" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /context run-compaction on <compact-percent> <max-compactions>|off"})
		return m, nil
	}
	if err := validatePercent(args[1], "run-context compact percent"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := validatePositiveInt(args[2], "max context compactions"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.savedConfig.RunContextCompact = "on"
	m.savedConfig.ContextCompactPct = args[1]
	m.savedConfig.MaxContextCompact = args[2]
	return m.saveContextConfig("run-context compaction on at " + args[1] + "%")
}

func (m model) saveContextConfig(message string) (tea.Model, tea.Cmd) {
	if err := validateSavedContextConfig(m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: message})
	return m, nil
}

func (m model) handleProgressCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 || (len(args) == 1 && args[0] == "status") {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.progressStatus()})
		return m, nil
	}
	if len(args) != 2 || args[0] != "observer" || (args[1] != "on" && args[1] != "off") {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /progress observer on|off"})
		return m, nil
	}

	m.savedConfig.ProgressObserver = args[1] == "on"
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.progressStatus()})
	return m, nil
}

func (m model) handlePlannerReviewCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 || (len(args) == 1 && args[0] == "status") {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.plannerReviewStatus()})
		return m, nil
	}

	if len(args) == 1 && args[0] == "off" {
		m.savedConfig.PlannerReviewMaxRevisions = ""
		if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.plannerReviewStatus()})
		return m, nil
	}

	if len(args) != 2 || args[0] != "on" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /planner-review on <max-revisions>|off"})
		return m, nil
	}
	if err := validatePositiveInt(args[1], "planner review max revisions"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.savedConfig.PlannerReviewMaxRevisions = args[1]
	if err := validateSavedPlannerReviewConfig(m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.plannerReviewStatus()})
	return m, nil
}

func (m model) handleAgenticPersistenceCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.agenticPersistenceStatus()})
		return m, nil
	}

	if len(args) == 1 && args[0] == "off" {
		m.savedConfig.AgenticPersistenceRounds = ""
		m.savedConfig.AgenticPersistenceMaxSteps = ""
		m.savedConfig.AgenticPersistenceTimeout = ""
		if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.agenticPersistenceStatus()})
		return m, nil
	}

	if len(args) != 3 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /agentic-persistence <rounds> <max-steps> <timeout-ms>|off"})
		return m, nil
	}
	if err := validatePositiveInt(args[0], "agentic persistence rounds"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := validatePositiveInt(args[1], "max steps"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := validatePositiveInt(args[2], "timeout ms"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.savedConfig.AgenticPersistenceRounds = args[0]
	m.savedConfig.AgenticPersistenceMaxSteps = args[1]
	m.savedConfig.AgenticPersistenceTimeout = args[2]
	if err := validateSavedAgenticPersistenceConfig(m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.agenticPersistenceStatus()})
	return m, nil
}

func validateSavedAgenticPersistenceConfig(config savedConfig) error {
	rounds := strings.TrimSpace(config.AgenticPersistenceRounds)
	maxSteps := strings.TrimSpace(config.AgenticPersistenceMaxSteps)
	timeout := strings.TrimSpace(config.AgenticPersistenceTimeout)
	if rounds == "" && maxSteps == "" && timeout == "" {
		return nil
	}
	if rounds == "" || maxSteps == "" || timeout == "" {
		return errors.New("saved agentic persistence requires rounds, max steps, and timeout ms together")
	}
	return validateAgenticPersistenceConfig(runConfig{
		Workflow:                 workflowAgentic,
		MaxSteps:                 config.AgenticPersistenceMaxSteps,
		RunTimeout:               config.AgenticPersistenceTimeout,
		AgenticPersistenceRounds: config.AgenticPersistenceRounds,
	})
}

func (m model) agenticPersistenceStatus() string {
	if strings.TrimSpace(m.savedConfig.AgenticPersistenceRounds) == "" {
		return "agentic persistence: off"
	}
	return "agentic persistence: rounds=" + m.savedConfig.AgenticPersistenceRounds +
		" max_steps=" + m.savedConfig.AgenticPersistenceMaxSteps +
		" timeout_ms=" + m.savedConfig.AgenticPersistenceTimeout
}

func validateSavedPlannerReviewConfig(config savedConfig) error {
	if strings.TrimSpace(config.PlannerReviewMaxRevisions) == "" {
		return nil
	}
	return validatePositiveInt(config.PlannerReviewMaxRevisions, "planner review max revisions")
}

func (m model) plannerReviewStatus() string {
	if strings.TrimSpace(m.savedConfig.PlannerReviewMaxRevisions) == "" {
		return "planner review: off"
	}
	return "planner review: jsonl-stdio max_revisions=" + m.savedConfig.PlannerReviewMaxRevisions + " runtime=agentic"
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

func formatTokenCount(tokens int) string {
	return strconv.Itoa(tokens)
}

func compactWorkingDirStatus(workingDir string) string {
	trimmed := strings.TrimSpace(workingDir)
	if trimmed == "" {
		return "missing"
	}
	cleaned := filepath.Clean(trimmed)
	home := strings.TrimSpace(os.Getenv("HOME"))
	if home == "" {
		return cleaned
	}
	cleanHome := filepath.Clean(home)
	switch {
	case cleaned == cleanHome:
		return "~"
	case strings.HasPrefix(cleaned, cleanHome+string(filepath.Separator)):
		return "~" + strings.TrimPrefix(cleaned, cleanHome)
	default:
		return cleaned
	}
}

func (m model) handleAllowToolsCommand(args []string, fallbackApproval string) (tea.Model, tea.Cmd) {
	if m.pendingToolTask == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no pending tool request"})
		return m, nil
	}
	if len(args) > 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /allow-tools [ask-before-write|auto-approved-safe|full-access]"})
		return m, nil
	}

	approval := fallbackApproval
	if len(args) == 1 {
		approval = args[0]
	}
	if approval != "ask-before-write" && approval != "auto-approved-safe" && approval != "full-access" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "write tool approval must be ask-before-write, auto-approved-safe, or full-access"})
		return m, nil
	}

	if m.pendingToolHarness == pendingHarnessMCPBrowser {
		return m.handleAllowMCPBrowserToolsCommand(args, approval)
	}

	root := m.pendingToolRoot
	if root == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool root is required for pending tool request"})
		return m, nil
	}

	harness := m.pendingToolHarness
	if harness == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool harness is required for pending tool request"})
		return m, nil
	}

	m.savedConfig.ToolHarness = harness
	m.savedConfig.ToolRoot = root
	m.savedConfig.ToolTimeout = defaultFilesystemToolTimeout
	m.savedConfig.ToolMaxRounds = defaultFilesystemToolMaxRounds
	m.savedConfig.ToolApproval = approval

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	task := m.pendingToolTask
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.pendingToolHarness = ""
	m.pendingToolChoice = 0
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "allowed " + harness + " tools root=" + root + " timeout_ms=" + defaultFilesystemToolTimeout + " max_rounds=" + defaultFilesystemToolMaxRounds + " approval=" + approval})
	return m.startRun(task)
}

func (m model) handleAllowMCPBrowserToolsCommand(args []string, approval string) (tea.Model, tea.Cmd) {
	if strings.TrimSpace(m.savedConfig.MCPConfig) == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "MCP browser tools require an MCP config"})
		return m, nil
	}

	m.savedConfig.ToolHarness = ""
	m.savedConfig.ToolRoot = ""
	m.savedConfig.TestCommands = nil
	m.savedConfig.ToolTimeout = defaultMCPToolTimeout
	m.savedConfig.ToolMaxRounds = defaultMCPToolMaxRounds
	m.savedConfig.ToolApproval = approval

	if err := validateToolConfig(runConfig{
		ToolTimeout:   m.savedConfig.ToolTimeout,
		ToolMaxRounds: m.savedConfig.ToolMaxRounds,
		ToolApproval:  m.savedConfig.ToolApproval,
		MCPConfig:     m.savedConfig.MCPConfig,
	}); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	task := m.pendingToolTask
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.pendingToolHarness = ""
	m.pendingToolChoice = 0
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "allowed MCP browser tools approval=" + approval})
	return m.startRun(task)
}

type pendingToolOption struct {
	Label       string
	Description string
	Approval    string
	Deny        bool
}

func pendingToolOptions() []pendingToolOption {
	return []pendingToolOption{
		{
			Label:       "Ask each use",
			Description: "Enable required tools for this root with interactive ask-before-write approval and retry now. Budget: timeout_ms=" + defaultFilesystemToolTimeout + ", max_rounds=" + defaultFilesystemToolMaxRounds + ".",
			Approval:    "ask-before-write",
		},
		{
			Label:       "Allow writes",
			Description: "Enable required tools for this root with auto-approved-safe approval and retry now. Budget: timeout_ms=" + defaultFilesystemToolTimeout + ", max_rounds=" + defaultFilesystemToolMaxRounds + ".",
			Approval:    "auto-approved-safe",
		},
		{
			Label:       "Full access",
			Description: "Enable required tools for this root with full-access approval and retry now. Budget: timeout_ms=" + defaultFilesystemToolTimeout + ", max_rounds=" + defaultFilesystemToolMaxRounds + ".",
			Approval:    "full-access",
		},
		{
			Label:       "Deny",
			Description: "Decline this tool request; no run starts.",
			Deny:        true,
		},
	}
}

func (m model) pendingToolOptions() []pendingToolOption {
	if m.pendingToolHarness == pendingHarnessMCPBrowser {
		return []pendingToolOption{
			{
				Label:       "Ask each use",
				Description: "Enable MCP browser network tools with interactive ask-before-write approval and retry now.",
				Approval:    "ask-before-write",
			},
			{
				Label:       "Full access",
				Description: "Enable MCP browser network tools with full-access approval and retry now.",
				Approval:    "full-access",
			},
			{
				Label:       "Deny",
				Description: "Decline this browser tool request; no run starts.",
				Deny:        true,
			},
		}
	}
	return pendingToolOptions()
}

func pendingFullAccessChoice(options []pendingToolOption) int {
	for index, option := range options {
		if option.Approval == "full-access" {
			return index
		}
	}
	return 0
}

func (m *model) movePendingToolChoice(delta int) {
	options := m.pendingToolOptions()
	m.pendingToolChoice = (m.pendingToolChoice + delta + len(options)) % len(options)
}

func (m model) applyPendingToolChoice() (tea.Model, tea.Cmd) {
	options := m.pendingToolOptions()
	if m.pendingToolChoice < 0 || m.pendingToolChoice >= len(options) {
		m.pendingToolChoice = 0
	}
	option := options[m.pendingToolChoice]
	if option.Deny {
		return m.handleDenyToolsCommand(nil)
	}
	return m.handleAllowToolsCommand([]string{option.Approval}, option.Approval)
}

func (m model) handleDenyToolsCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /deny-tools"})
		return m, nil
	}
	m.pendingToolTask = ""
	m.pendingToolRoot = ""
	m.pendingToolHarness = ""
	m.pendingToolChoice = 0
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool request denied; no run started"})
	return m, nil
}

func (m *model) addPendingPermission(event eventSummary) {
	if strings.TrimSpace(event.RequestID) == "" {
		return
	}
	if m.pendingPermissions == nil {
		m.pendingPermissions = map[string]eventSummary{}
		m.pendingPermissionChoice = 0
	}
	if _, exists := m.pendingPermissions[event.RequestID]; !exists {
		m.pendingPermissionID = append(m.pendingPermissionID, event.RequestID)
	}
	m.pendingPermissions[event.RequestID] = event
}

func (m *model) removePendingPermission(requestID string) {
	if strings.TrimSpace(requestID) == "" || m.pendingPermissions == nil {
		return
	}
	delete(m.pendingPermissions, requestID)
	next := m.pendingPermissionID[:0]
	for _, id := range m.pendingPermissionID {
		if id != requestID {
			next = append(next, id)
		}
	}
	m.pendingPermissionID = next
	if len(m.pendingPermissionID) == 0 {
		m.pendingPermissionID = nil
		m.pendingPermissions = nil
		m.pendingPermissionChoice = 0
	}
}

func (m model) currentPendingPermission() (eventSummary, bool) {
	for _, id := range m.pendingPermissionID {
		if request, ok := m.pendingPermissions[id]; ok {
			return request, true
		}
	}
	return eventSummary{}, false
}

func (m model) answerPendingPermission(request eventSummary, decision string) (tea.Model, tea.Cmd) {
	if decision != "approve" && decision != "deny" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unsupported permission decision: " + decision})
		return m, nil
	}
	m.removePendingPermission(request.RequestID)
	return m, sendPermissionDecisionCommand(m.stream, request.RequestID, decision, "TUI "+decision)
}

func (m *model) addPendingPlannerReview(event eventSummary) {
	if strings.TrimSpace(event.RequestID) == "" {
		return
	}
	if m.pendingPlannerReviews == nil {
		m.pendingPlannerReviews = map[string]eventSummary{}
		m.pendingPlannerReviewChoice = 0
	}
	if _, exists := m.pendingPlannerReviews[event.RequestID]; !exists {
		m.pendingPlannerReviewID = append(m.pendingPlannerReviewID, event.RequestID)
	}
	m.pendingPlannerReviews[event.RequestID] = event
}

func (m *model) removePendingPlannerReview(requestID string) {
	if strings.TrimSpace(requestID) == "" || m.pendingPlannerReviews == nil {
		return
	}
	delete(m.pendingPlannerReviews, requestID)
	next := m.pendingPlannerReviewID[:0]
	for _, id := range m.pendingPlannerReviewID {
		if id != requestID {
			next = append(next, id)
		}
	}
	m.pendingPlannerReviewID = next
	if len(m.pendingPlannerReviewID) == 0 {
		m.pendingPlannerReviewID = nil
		m.pendingPlannerReviews = nil
		m.pendingPlannerReviewChoice = 0
	}
}

func (m model) currentPendingPlannerReview() (eventSummary, bool) {
	for _, id := range m.pendingPlannerReviewID {
		if request, ok := m.pendingPlannerReviews[id]; ok {
			return request, true
		}
	}
	return eventSummary{}, false
}

type pendingPlannerReviewOption struct {
	Label       string
	Description string
	Decision    string
}

func pendingPlannerReviewOptions() []pendingPlannerReviewOption {
	return []pendingPlannerReviewOption{
		{
			Label:       "Approve plan",
			Description: "Start the proposed workers.",
			Decision:    "approve",
		},
		{
			Label:       "Request revision",
			Description: "Type feedback, then press Enter.",
			Decision:    "revise",
		},
		{
			Label:       "Decline plan",
			Description: "Stop this run before workers start.",
			Decision:    "decline",
		},
	}
}

func pendingPlannerReviewDeclineChoice() int {
	options := pendingPlannerReviewOptions()
	for index, option := range options {
		if option.Decision == "decline" {
			return index
		}
	}
	return len(options) - 1
}

func (m *model) movePendingPlannerReviewChoice(delta int) {
	options := pendingPlannerReviewOptions()
	m.pendingPlannerReviewChoice = (m.pendingPlannerReviewChoice + delta + len(options)) % len(options)
}

func (m model) applyPendingPlannerReviewChoice(request eventSummary) (tea.Model, tea.Cmd) {
	options := pendingPlannerReviewOptions()
	if m.pendingPlannerReviewChoice < 0 || m.pendingPlannerReviewChoice >= len(options) {
		m.pendingPlannerReviewChoice = 0
	}
	option := options[m.pendingPlannerReviewChoice]
	if option.Decision == "revise" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "type revision feedback, then press Enter"})
		return m, nil
	}
	return m.answerPendingPlannerReview(request, option.Decision, "")
}

func (m model) answerPendingPlannerReview(request eventSummary, decision string, feedback string) (tea.Model, tea.Cmd) {
	if decision != "approve" && decision != "decline" && decision != "revise" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unsupported planner review decision: " + decision})
		return m, nil
	}
	if decision == "revise" && strings.TrimSpace(feedback) == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "planner review revision feedback must not be empty"})
		return m, nil
	}
	m.removePendingPlannerReview(request.RequestID)
	return m, sendPlannerReviewDecisionCommand(m.stream, request.RequestID, decision, feedback, "TUI "+decision)
}

func plannerReviewDecisionFromInput(text string) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "a", "/a", "approve", "/approve":
		return "approve", true
	case "d", "/d", "decline", "/decline", "deny", "/deny":
		return "decline", true
	default:
		return "", false
	}
}

type pendingRuntimePermissionOption struct {
	Label       string
	Description string
	Decision    string
}

func pendingRuntimePermissionOptions() []pendingRuntimePermissionOption {
	return []pendingRuntimePermissionOption{
		{
			Label:       "Approve once",
			Description: "Allow this exact runtime tool request.",
			Decision:    "approve",
		},
		{
			Label:       "Deny",
			Description: "Reject this runtime tool request.",
			Decision:    "deny",
		},
	}
}

func pendingPermissionDenyChoice() int {
	options := pendingRuntimePermissionOptions()
	for index, option := range options {
		if option.Decision == "deny" {
			return index
		}
	}
	return len(options) - 1
}

func (m *model) movePendingPermissionChoice(delta int) {
	options := pendingRuntimePermissionOptions()
	m.pendingPermissionChoice = (m.pendingPermissionChoice + delta + len(options)) % len(options)
}

func (m model) applyPendingPermissionChoice(request eventSummary) (tea.Model, tea.Cmd) {
	options := pendingRuntimePermissionOptions()
	if m.pendingPermissionChoice < 0 || m.pendingPermissionChoice >= len(options) {
		m.pendingPermissionChoice = 0
	}
	return m.answerPendingPermission(request, options[m.pendingPermissionChoice].Decision)
}

func runtimePermissionDecisionFromInput(text string) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "a", "/a", "approve", "/approve", "allow", "/allow":
		return "approve", true
	case "d", "/d", "deny", "/deny":
		return "deny", true
	default:
		return "", false
	}
}

func (m model) handleWorkflowCommand(args []string) (tea.Model, tea.Cmd) {
	_ = args
	m.view = viewChat
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "Workflow selection was removed; every run uses the agentic runtime and reports strategy direct, tool, planned, or swarm."})
	return m, nil
}

func (m model) handleRouterCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.routerStatus()})
		return m, nil
	}

	switch args[0] {
	case "deterministic":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router deterministic"})
			return m, nil
		}
		m.savedConfig.RouterMode = "deterministic"
		m.savedConfig.RouterModelDir = ""
		m.savedConfig.RouterTimeout = ""
		m.savedConfig.RouterConfidence = ""
	case "llm":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router llm"})
			return m, nil
		}
		m.savedConfig.RouterMode = "llm"
		m.savedConfig.RouterModelDir = ""
		m.savedConfig.RouterTimeout = ""
		m.savedConfig.RouterConfidence = ""
	case "local":
		if len(args) != 2 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router local <model-dir>"})
			return m, nil
		}
		if strings.TrimSpace(args[1]) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "router model dir must not be empty"})
			return m, nil
		}
		m.savedConfig.RouterMode = "local"
		m.savedConfig.RouterModelDir = args[1]
		if strings.TrimSpace(m.savedConfig.RouterTimeout) == "" {
			m.savedConfig.RouterTimeout = defaultRouterTimeoutMS
		}
		if strings.TrimSpace(m.savedConfig.RouterConfidence) == "" {
			m.savedConfig.RouterConfidence = defaultRouterConfidence
		}
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router deterministic|llm|local <model-dir>"})
		return m, nil
	}

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.routerStatus()})
	return m, nil
}

func (m model) handleRouterTimeoutCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router-timeout <ms>"})
		return m, nil
	}
	if err := validatePositiveInt(args[0], "router timeout ms"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if m.savedConfig.RouterMode != "local" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "router timeout requires /router local <model-dir>"})
		return m, nil
	}
	m.savedConfig.RouterTimeout = args[0]

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.routerStatus()})
	return m, nil
}

func (m model) handleRouterConfidenceCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router-confidence <float>"})
		return m, nil
	}
	if err := validateProbability(args[0], "router confidence"); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if m.savedConfig.RouterMode != "local" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "router confidence requires /router local <model-dir>"})
		return m, nil
	}
	m.savedConfig.RouterConfidence = args[0]

	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.routerStatus()})
	return m, nil
}

func (m model) handleRouterStatusCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /router-status"})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: m.routerStatus()})
	return m, nil
}

func (m model) handleProviderCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 {
		m.openProviderPicker()
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "open provider picker, use Up/Down and Enter to select"})
		return m, nil
	}
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /provider [<provider-id>]"})
		return m, nil
	}

	nextProvider, err := parseProvider(args[0])
	if err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	return m.applyProvider(nextProvider, true)
}

func (m *model) openProviderPicker() {
	m.providerPickerOpen = true
	m.modelPickerOpen = false
	m.skillPickerOpen = false
	m.view = viewChat
	if m.providerSet {
		m.providerPickerIndex = providerListIndex(m.provider)
	} else {
		m.providerPickerIndex = 0
	}
}

func (m model) selectProviderFromPicker() (tea.Model, tea.Cmd) {
	if len(providers) == 0 {
		m.providerPickerOpen = false
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no providers available"})
		return m, nil
	}
	if m.providerPickerIndex < 0 || m.providerPickerIndex >= len(providers) {
		m.providerPickerIndex = 0
	}
	nextProvider := providers[m.providerPickerIndex]
	resetModel := !m.providerSet || m.provider != nextProvider
	m.providerPickerOpen = false
	return m.applyProvider(nextProvider, resetModel)
}

func (m model) applyProvider(nextProvider provider, resetModel bool) (tea.Model, tea.Cmd) {
	m.provider = nextProvider
	m.providerSet = true
	m.savedConfig.Provider = string(nextProvider)
	if resetModel {
		m.savedConfig.rememberModel(nextProvider, "")
		m.modelOptions = nil
		m.modelIndex = 0
		m.selectedModel = ""
		m.modelStatus = ""
	}
	m.providerPickerOpen = false
	m.modelPickerOpen = false
	m.modelPickerPending = false
	m.modelPickerQuery = ""
	m.view = viewChat
	if resetModel {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider set to " + m.provider.Label()})
	} else {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider kept as " + m.provider.Label()})
	}
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	if resetModel && m.provider != providerEcho {
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
	if apiKeyName(m.provider) == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "provider does not have an api_key field; use /provider-secret <field> <value>"})
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

func (m model) handleProviderSecretCommand(args []string) (tea.Model, tea.Cmd) {
	if !m.providerSet || m.provider == providerEcho {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a remote provider before saving provider secrets"})
		m.view = viewSetup
		return m, nil
	}
	if len(args) < 2 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /provider-secret <field> <value>"})
		return m, nil
	}
	field := args[0]
	if !providerHasSecretField(m.provider, field) {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown secret field for " + m.provider.Label() + ": " + field})
		return m, nil
	}
	m.rememberProviderSecret(m.provider, field, strings.Join(args[1:], " "))
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "saved provider secret " + field})
	return m, m.loadModelsCommand()
}

func (m model) handleProviderOptionCommand(args []string) (tea.Model, tea.Cmd) {
	if !m.providerSet || m.provider == providerEcho {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a remote provider before saving provider options"})
		m.view = viewSetup
		return m, nil
	}
	if len(args) < 2 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /provider-option <field> <value>"})
		return m, nil
	}
	field := args[0]
	if !providerHasOptionField(m.provider, field) {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown option field for " + m.provider.Label() + ": " + field})
		return m, nil
	}
	m.rememberProviderOption(m.provider, field, strings.Join(args[1:], " "))
	m.modelOptions = nil
	m.selectedModel = ""
	m.savedConfig.rememberModel(m.provider, "")
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "saved provider option " + field})
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
	case "time":
		if len(args) != 4 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /tools time <timeout-ms> <max-rounds> <approval-mode>"})
			return m, nil
		}
		if err := validatePositiveInt(args[1], "tool timeout ms"); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		if err := validatePositiveInt(args[2], "tool max rounds"); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		if err := validateToolApprovalMode(args[3]); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		if len(m.savedConfig.TestCommands) > 0 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "saved test commands require /tools code-edit <root> <timeout-ms> <max-rounds> full-access or ask-before-write"})
			return m, nil
		}
		m.savedConfig.ToolHarness = args[0]
		m.savedConfig.ToolRoot = ""
		m.savedConfig.ToolTimeout = args[1]
		m.savedConfig.ToolMaxRounds = args[2]
		m.savedConfig.ToolApproval = args[3]
	case "local-files", "code-edit":
		if len(args) != 5 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /tools " + args[0] + " <root> <timeout-ms> <max-rounds> <approval-mode>"})
			return m, nil
		}
		if strings.TrimSpace(args[1]) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "tool root must not be empty"})
			return m, nil
		}
		root, err := resolveToolRootPath(args[1], m.toolRootBaseDir())
		if err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
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
		if len(m.savedConfig.TestCommands) > 0 && (args[0] != "code-edit" || (args[4] != "full-access" && args[4] != "ask-before-write")) {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "saved test commands require /tools code-edit <root> <timeout-ms> <max-rounds> full-access or ask-before-write"})
			return m, nil
		}
		m.savedConfig.ToolHarness = args[0]
		m.savedConfig.ToolRoot = root
		m.savedConfig.ToolTimeout = args[2]
		m.savedConfig.ToolMaxRounds = args[3]
		m.savedConfig.ToolApproval = args[4]
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /tools off|time <timeout-ms> <max-rounds> <approval-mode>|local-files|code-edit <root> <timeout-ms> <max-rounds> <approval-mode>"})
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
	if len(args) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /mcp-config <path> <timeout-ms> <max-rounds> <approval-mode>|off"})
		return m, nil
	}

	if args[0] == "off" {
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /mcp-config off"})
			return m, nil
		}
		m.savedConfig.MCPConfig = ""
	} else {
		if len(args) != 4 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "MCP config requires explicit tool timeout, max rounds, and approval mode"})
			return m, nil
		}
		nextConfig := m.savedConfig
		path := strings.TrimSpace(args[0])
		if path == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "MCP config path must not be empty"})
			return m, nil
		}
		nextConfig.MCPConfig = path
		nextConfig.ToolTimeout = args[1]
		nextConfig.ToolMaxRounds = args[2]
		nextConfig.ToolApproval = args[3]
		if err := validateToolConfig(runConfig{
			ToolHarness:   nextConfig.ToolHarness,
			ToolRoot:      nextConfig.ToolRoot,
			ToolTimeout:   nextConfig.ToolTimeout,
			ToolMaxRounds: nextConfig.ToolMaxRounds,
			ToolApproval:  nextConfig.ToolApproval,
			TestCommands:  nextConfig.TestCommands,
			MCPConfig:     nextConfig.MCPConfig,
		}); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		m.savedConfig = nextConfig
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
		return m, m.skillsCLICommandFor("list", "list")
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
	case "generate":
		if len(args) < 3 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills generate <name> <description>"})
			return m, nil
		}
		if strings.TrimSpace(m.savedConfig.SkillsDir) == "" {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "set /skills dir <skills-dir> before generating skills"})
			return m, nil
		}
		if !m.providerSet {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "select a provider before generating skills"})
			m.view = viewSetup
			return m, nil
		}
		if !validSkillName(args[1]) {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "invalid skill name: " + args[1]})
			return m, nil
		}
		config, err := resolveConfig(m.runConfig("generate skill " + args[1]))
		if err != nil {
			return m.withRunPreparationError(err), nil
		}
		return m, m.skillsGenerateCommand(config, args[1], strings.Join(args[2:], " "))
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /skills off|auto|dir|add|remove|clear|scripts|list|search|show|install|update|create|generate"})
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
	return m.skillsCLICommandFor("", args...)
}

func (m model) skillsCLICommandFor(action string, args ...string) tea.Cmd {
	cliArgs, err := buildSkillsCLIArgs(args, m.savedConfig.SkillsDir, true)
	if err != nil {
		return func() tea.Msg {
			return skillsCommandMsg{Action: action, Err: err}
		}
	}
	return runSkillsCLICommandFor(action, cliArgs)
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

func (m model) skillsGenerateCommand(config runConfig, name string, description string) tea.Cmd {
	cliArgs, err := buildSkillsGenerateCLIArgs(config, name, description)
	if err != nil {
		return func() tea.Msg {
			return skillsCommandMsg{Err: err}
		}
	}
	return runSkillsCLICommandWithConfig(cliArgs, config)
}

func parseSkillListResult(raw string) (skillListResult, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return skillListResult{}, errors.New("skills list output was empty")
	}
	var result skillListResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		return skillListResult{}, fmt.Errorf("invalid skills list JSON: %w", err)
	}
	for _, skill := range result.Skills {
		if strings.TrimSpace(skill.Name) == "" {
			return skillListResult{}, errors.New("skills list returned a skill without a name")
		}
		if strings.TrimSpace(skill.Description) == "" {
			return skillListResult{}, fmt.Errorf("skills list returned %s without a description", skill.Name)
		}
	}
	return result, nil
}

func selectedSkillIndex(skills []skillCatalogEntry, selected []string) int {
	for _, name := range selected {
		for index, skill := range skills {
			if skill.Name == name {
				return index
			}
		}
	}
	return 0
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

func buildSkillsGenerateCLIArgs(config runConfig, name string, description string) ([]string, error) {
	if strings.TrimSpace(config.SkillsDir) == "" {
		return nil, errors.New("set /skills dir <skills-dir> before generating skills")
	}
	if !validSkillName(name) {
		return nil, fmt.Errorf("invalid skill name: %s", name)
	}
	if strings.TrimSpace(description) == "" {
		return nil, errors.New("skill description must not be empty")
	}
	if strings.TrimSpace(config.Model) == "" {
		return nil, errors.New("model must not be empty for skill generation")
	}
	if strings.TrimSpace(config.HTTPTimeout) == "" {
		return nil, errors.New("HTTP timeout is missing for skill generation")
	}
	if strings.TrimSpace(config.InputPrice) == "" {
		return nil, errors.New("input pricing is missing for skill generation")
	}
	if strings.TrimSpace(config.OutputPrice) == "" {
		return nil, errors.New("output pricing is missing for skill generation")
	}

	cliArgs := []string{
		"generate",
		name,
		"--skills-dir",
		config.SkillsDir,
		"--description",
		description,
		"--provider",
		string(config.Provider),
		"--model",
		config.Model,
		"--http-timeout-ms",
		config.HTTPTimeout,
		"--input-price-per-million",
		config.InputPrice,
		"--output-price-per-million",
		config.OutputPrice,
		"--json",
	}
	for _, key := range sortedStringMapKeys(config.ProviderOptions) {
		value := config.ProviderOptions[key]
		cliArgs = append(cliArgs, "--provider-option", key+"="+value)
	}
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
	m.rememberSelectedModelMetadata()
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
	m.rememberSelectedModelMetadata()
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

func (m model) handleSendAgentCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) < 2 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /send-agent <agent-id> <message>"})
		return m, nil
	}
	if m.stream == nil || !m.stream.persistent {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no active session daemon"})
		return m, nil
	}
	agentID := args[0]
	message := strings.TrimSpace(strings.Join(args[1:], " "))
	if message == "" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /send-agent <agent-id> <message>"})
		return m, nil
	}
	m.messages = append(m.messages, chatMessage{Role: "system", Text: "sent message to " + agentID})
	return m, sendSessionAgentMessageCommand(m.stream, agentID, message, true)
}

func (m model) handleReadAgentCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /read-agent <agent-id>"})
		return m, nil
	}
	if m.stream == nil || !m.stream.persistent {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no active session daemon"})
		return m, nil
	}
	return m, readSessionAgentOutputCommand(m.stream, args[0])
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
		m.recordSummaryUsage(envelope.Summary)
		m.refreshGitBranchStatus()
		m.raw = line
		m.applySummaryResults(envelope.Summary)
		m.applySummaryChecklist(envelope.Summary)
		if m.stream != nil && m.stream.persistent && m.running {
			m.running = false
			m.pendingPermissions = nil
			m.pendingPermissionID = nil
			m.pendingPermissionChoice = 0
			m.pendingPlannerReviews = nil
			m.pendingPlannerReviewID = nil
			m.pendingPlannerReviewChoice = 0
			if envelope.Summary.Status == "failed" {
				errorText := summaryError(envelope.Summary)
				if updated, handled := m.withCapabilityRequired(envelope.Summary.CapabilityRequired); handled {
					return updated, nil
				}
				m.messages = append(m.messages, chatMessage{Role: "assistant", Text: "Run failed:\n" + errorText})
			} else {
				m.messages = append(m.messages, chatMessage{Role: "assistant", Text: summaryDisplayText(envelope.Summary)})
			}
			m.chatScroll = 0
			nextModel, cmd := m.startNextQueuedRun()
			if typed, ok := nextModel.(model); ok {
				return typed, cmd
			}
			return m, cmd
		}
	case "session_command_result":
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "session result: " + string(envelope.Raw)})
	case "session_error":
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "session error: " + string(envelope.Raw)})
	case "session_shutdown":
		return m, nil
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "unknown JSONL message type: " + envelope.Type})
	}

	return m, nil
}

func (m *model) applyEvent(event eventSummary) {
	if event.Type == "assistant_delta" && event.Delta != "" {
		m.appendAgentDelta(event)
		if userFacingStreamAgent(event.AgentID) {
			m.liveAssistant += event.Delta
		}
		m.markAgentRunning(event)
		return
	}

	if event.Type == "progress_commentary" {
		m.appendProgressCommentary(event)
		return
	}

	m.recordEventUsage(event)
	m.eventLog = append(m.eventLog, event)
	if m.eventAutoScroll {
		m.clampEventScroll()
	}
	if event.Type == "run_timed_out" {
		m.markRunningAgentsTimedOut(event)
	}
	if event.Type == "permission_requested" {
		m.addPendingPermission(event)
	}
	if event.Type == "permission_decided" || event.Type == "permission_cancelled" {
		m.removePendingPermission(event.RequestID)
	}
	if event.Type == "planner_review_requested" {
		m.addPendingPlannerReview(event)
	}
	if event.Type == "planner_review_decided" {
		m.removePendingPlannerReview(event.RequestID)
	}
	if event.Type == "context_budget" {
		budget := event
		m.latestContextBudget = &budget
	}
	if event.Type == "capability_required" {
		updated, handled := m.withCapabilityRequired(capabilityRequiredFromEvent(event))
		if handled {
			*m = updated
		}
	}

	m.applyWorkEvent(event)
	m.applyNonDeltaEvent(event)
}

func capabilityRequiredFromEvent(event eventSummary) capabilityRequired {
	return capabilityRequired{
		Reason:                event.Reason,
		Intent:                event.Intent,
		RequiredHarness:       event.RequiredHarness,
		RequiredHarnesses:     event.RequiredHarnesses,
		RequiredApprovalModes: event.RequiredApprovalModes,
		RequiredMCPTool:       event.RequiredMCPTool,
		RequestedRoot:         event.RequestedRoot,
		Detail:                event.Summary,
	}
}

func (m *model) applyNonDeltaEvent(event eventSummary) {
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
	case "session_agent_started":
		agent.Status = "running"
		agent.StartedAt = event.At
	case "session_agent_completed":
		agent.Status = "completed"
		agent.FinishedAt = event.At
	case "session_agent_failed":
		agent.Status = "failed"
		agent.FinishedAt = event.At
		agent.Error = event.Reason
	case "session_agent_cancelled":
		agent.Status = "stopped"
		agent.FinishedAt = event.At
		agent.Error = event.Reason
	case "agent_retry_scheduled":
		agent.Status = "retrying"
		agent.Error = event.Reason
	case "agent_heartbeat":
		agent.Status = "running"
	case "provider_request_started":
		if agent.Status == "" {
			agent.Status = "running"
		}
	}

	agent.Events = append(agent.Events, event)
	m.agents[event.AgentID] = agent
}

func (m *model) markAgentRunning(event eventSummary) {
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
	if agent.Status == "" {
		agent.Status = "running"
	}

	m.agents[event.AgentID] = agent
}

func (m *model) markRunningAgentsTimedOut(event eventSummary) {
	reason := emptyAs(event.Reason, "run timed out")
	for id, agent := range m.agents {
		status := strings.ToLower(strings.TrimSpace(agent.Status))
		if status == "" || status == "running" || status == "retrying" {
			agent.Status = "timeout"
			agent.Error = reason
			agent.FinishedAt = event.At
			agent.Events = append(agent.Events, event)
			m.agents[id] = agent
		}
	}
}

func (m *model) applyWorkEvent(event eventSummary) {
	if m.workItems == nil {
		m.workItems = map[string]workItem{}
	}

	switch event.Type {
	case "agent_delegation_scheduled":
		parentID := workAgentID(event.AgentID)
		for _, agentID := range event.DelegatedAgentIDs {
			m.upsertWorkItem(workItem{
				ID:            workAgentID(agentID),
				Kind:          "agent",
				Label:         agentID,
				ParentID:      parentID,
				Status:        "pending",
				LatestSummary: event.Summary,
			})
		}
	case "agent_started":
		m.upsertWorkItem(workItem{
			ID:            workAgentID(event.AgentID),
			Kind:          "agent",
			Label:         event.AgentID,
			ParentID:      parentWorkAgentID(event.ParentAgentID),
			Status:        "running",
			StartedAt:     event.At,
			LatestSummary: event.Summary,
		})
	case "agent_finished":
		m.upsertWorkItem(workItem{
			ID:            workAgentID(event.AgentID),
			Kind:          "agent",
			Label:         event.AgentID,
			Status:        workDoneStatus(event.Status),
			FinishedAt:    event.At,
			DurationMS:    event.DurationMS,
			LatestSummary: event.Summary,
		})
	case "session_agent_started":
		m.upsertWorkItem(workItem{
			ID:            workAgentID(event.AgentID),
			Kind:          "agent",
			Label:         event.AgentID,
			Status:        "running",
			StartedAt:     event.At,
			LatestSummary: eventDisplayLine(event),
		})
	case "session_agent_completed":
		m.upsertWorkItem(workItem{
			ID:            workAgentID(event.AgentID),
			Kind:          "agent",
			Label:         event.AgentID,
			Status:        "done",
			FinishedAt:    event.At,
			LatestSummary: eventDisplayLine(event),
		})
	case "session_agent_failed", "session_agent_cancelled":
		m.upsertWorkItem(workItem{
			ID:            workAgentID(event.AgentID),
			Kind:          "agent",
			Label:         event.AgentID,
			Status:        "error",
			FinishedAt:    event.At,
			LatestSummary: eventDisplayLine(event),
		})
	case "tool_call_started":
		m.upsertWorkItem(workItem{
			ID:            workToolID(event),
			Kind:          "tool",
			Label:         toolWorkLabel(event),
			ParentID:      workAgentID(event.AgentID),
			Status:        "running",
			StartedAt:     event.At,
			LatestSummary: eventDisplayLine(event),
		})
	case "tool_call_finished":
		m.upsertWorkItem(workItem{
			ID:            workToolID(event),
			Kind:          "tool",
			Label:         toolWorkLabel(event),
			ParentID:      workAgentID(event.AgentID),
			Status:        "done",
			FinishedAt:    event.At,
			DurationMS:    event.DurationMS,
			LatestSummary: eventDisplayLine(event),
		})
	case "tool_call_failed":
		m.upsertWorkItem(workItem{
			ID:            workToolID(event),
			Kind:          "tool",
			Label:         toolWorkLabel(event),
			ParentID:      workAgentID(event.AgentID),
			Status:        "error",
			FinishedAt:    event.At,
			DurationMS:    event.DurationMS,
			LatestSummary: eventDisplayLine(event),
		})
	case "run_timed_out":
		for id, item := range m.workItems {
			if item.Status == "" || item.Status == "pending" || item.Status == "running" {
				item.Status = "timeout"
				item.FinishedAt = event.At
				item.LatestSummary = event.Summary
				m.workItems[id] = item
			}
		}
	}
}

func (m *model) upsertWorkItem(item workItem) {
	if item.ID == "" {
		return
	}
	existing, exists := m.workItems[item.ID]
	if exists {
		item = mergeWorkItem(existing, item)
	} else {
		m.workOrder = append(m.workOrder, item.ID)
	}
	m.workItems[item.ID] = item
}

func mergeWorkItem(existing, next workItem) workItem {
	if next.Kind != "" {
		existing.Kind = next.Kind
	}
	if next.Label != "" {
		existing.Label = next.Label
	}
	if next.ParentID != "" {
		existing.ParentID = next.ParentID
	}
	if next.Status != "" {
		existing.Status = next.Status
	}
	if next.StartedAt != "" {
		existing.StartedAt = next.StartedAt
	}
	if next.FinishedAt != "" {
		existing.FinishedAt = next.FinishedAt
	}
	if next.DurationMS != nil {
		existing.DurationMS = next.DurationMS
	}
	if next.LatestSummary != "" {
		existing.LatestSummary = next.LatestSummary
	}
	return existing
}

func (m *model) applySummaryChecklist(summary summary) {
	if len(summary.Checklist) == 0 {
		return
	}
	m.workItems = map[string]workItem{}
	m.workOrder = nil
	for _, item := range summary.Checklist {
		m.upsertWorkItem(item)
	}
}

func workAgentID(agentID string) string {
	if strings.TrimSpace(agentID) == "" {
		return ""
	}
	return "agent:" + agentID
}

func parentWorkAgentID(agentID string) string {
	if strings.TrimSpace(agentID) == "" {
		return ""
	}
	return workAgentID(agentID)
}

func workToolID(event eventSummary) string {
	return "tool:" + event.AgentID + ":" + event.ToolCallID
}

func workDoneStatus(status string) string {
	if status == "ok" || status == "done" || status == "completed" {
		return "done"
	}
	return "error"
}

func toolWorkLabel(event eventSummary) string {
	if event.Summary != "" {
		return event.Summary
	}
	if event.Tool != "" {
		return event.Tool
	}
	return event.ToolCallID
}

func (m *model) appendProgressCommentary(event eventSummary) {
	text := strings.TrimSpace(event.Commentary)
	if text == "" {
		text = strings.TrimSpace(event.Summary)
	}
	if text == "" {
		return
	}
	event.Commentary = text
	if event.Summary == "" {
		event.Summary = text
	}
	m.progressComments = append(m.progressComments, event)
	if len(m.progressComments) > 8 {
		m.progressComments = m.progressComments[len(m.progressComments)-8:]
	}
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
	agent.StreamOutput += event.Delta
	agent.StreamChunks++
	agent.Events = append(agent.Events, sanitizedStreamEvent(event))
	m.agents[event.AgentID] = agent
}

func sanitizedStreamEvent(event eventSummary) eventSummary {
	event.Delta = ""
	return event
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

func (m *model) recordSummaryUsage(summary summary) {
	runID := strings.TrimSpace(summary.RunID)
	if runID != "" {
		if m.summaryUsageCounted(runID) {
			return
		}
		if liveUsage, ok := m.liveUsageByRunID[runID]; ok {
			m.recordUsage("", usageDelta(summary.Usage, liveUsage))
			m.markSummaryUsageCounted(runID)
			return
		}
	}
	m.recordUsage(summary.RunID, summary.Usage)
}

func (m *model) recordEventUsage(event eventSummary) {
	if event.Type != "provider_request_finished" || event.Usage.TotalTokens <= 0 {
		return
	}
	m.recordUsage("", event.Usage)
	runID := strings.TrimSpace(event.RunID)
	if runID == "" {
		return
	}
	if m.liveUsageByRunID == nil {
		m.liveUsageByRunID = map[string]usageSummary{}
	}
	m.liveUsageByRunID[runID] = addUsage(m.liveUsageByRunID[runID], event.Usage)
}

func (m *model) recordUsage(runID string, usage usageSummary) {
	runID = strings.TrimSpace(runID)
	if runID != "" {
		if m.summaryUsageCounted(runID) {
			return
		}
		m.markSummaryUsageCounted(runID)
	}

	m.sessionUsage = addUsage(m.sessionUsage, usage)
}

func (m *model) summaryUsageCounted(runID string) bool {
	if runID == "" {
		return false
	}
	_, ok := m.countedSummaryRunIDs[runID]
	return ok
}

func (m *model) markSummaryUsageCounted(runID string) {
	if runID == "" {
		return
	}
	if m.countedSummaryRunIDs == nil {
		m.countedSummaryRunIDs = map[string]struct{}{}
	}
	m.countedSummaryRunIDs[runID] = struct{}{}
}

func addUsage(left usageSummary, right usageSummary) usageSummary {
	return usageSummary{
		Agents:       left.Agents + right.Agents,
		InputTokens:  left.InputTokens + right.InputTokens,
		OutputTokens: left.OutputTokens + right.OutputTokens,
		TotalTokens:  left.TotalTokens + right.TotalTokens,
		CostUSD:      left.CostUSD + right.CostUSD,
	}
}

func usageDelta(total usageSummary, counted usageSummary) usageSummary {
	return usageSummary{
		Agents:       positiveDelta(total.Agents, counted.Agents),
		InputTokens:  positiveDelta(total.InputTokens, counted.InputTokens),
		OutputTokens: positiveDelta(total.OutputTokens, counted.OutputTokens),
		TotalTokens:  positiveDelta(total.TotalTokens, counted.TotalTokens),
		CostUSD:      positiveFloatDelta(total.CostUSD, counted.CostUSD),
	}
}

func positiveDelta(total int, counted int) int {
	if total <= counted {
		return 0
	}
	return total - counted
}

func positiveFloatDelta(total float64, counted float64) float64 {
	if total <= counted {
		return 0
	}
	return total - counted
}

func (m *model) refreshGitBranchStatus() {
	m.gitBranchStatus = gitBranchStatusForWorkingDir(m.workingDir)
}

func (m model) runConfig(task string) runConfig {
	config := runConfig{
		Task:                      task,
		Workflow:                  workflowAgentic,
		Provider:                  m.provider,
		APIKey:                    m.apiKey(),
		ProviderSecrets:           m.savedConfig.providerSecretsFor(m.provider),
		ProviderOptions:           m.savedConfig.providerOptionsFor(m.provider),
		Model:                     m.modelID(),
		ToolHarness:               m.savedConfig.ToolHarness,
		ToolRoot:                  m.savedConfig.ToolRoot,
		ToolTimeout:               m.savedConfig.ToolTimeout,
		ToolMaxRounds:             m.savedConfig.ToolMaxRounds,
		ToolApproval:              m.savedConfig.ToolApproval,
		TestCommands:              append([]string(nil), m.savedConfig.TestCommands...),
		MCPConfig:                 m.savedConfig.MCPConfig,
		MaxSteps:                  m.savedConfig.AgenticPersistenceMaxSteps,
		AgenticPersistenceRounds:  m.savedConfig.AgenticPersistenceRounds,
		PlannerReviewMaxRevisions: m.savedConfig.PlannerReviewMaxRevisions,
		RouterMode:                m.savedConfig.RouterMode,
		RouterModelDir:            m.savedConfig.RouterModelDir,
		RouterTimeout:             m.savedConfig.RouterTimeout,
		RouterConfidence:          m.savedConfig.RouterConfidence,
		SkillsMode:                m.savedConfig.SkillsMode,
		SkillsDir:                 m.savedConfig.SkillsDir,
		SkillNames:                append([]string(nil), m.savedConfig.SkillNames...),
		AllowSkillScripts:         m.savedConfig.AllowSkillScripts,
		ContextWarning:            m.savedConfig.ContextWarning,
		ContextTokenizer:          m.savedConfig.ContextTokenizer,
		ReservedOutput:            m.savedConfig.ReservedOutput,
		RunContextCompact:         m.savedConfig.RunContextCompact,
		ContextCompactPct:         m.savedConfig.ContextCompactPct,
		MaxContextCompact:         m.savedConfig.MaxContextCompact,
		EventLogFile:              m.eventLogFile,
		EventSessionID:            m.eventSessionID,
		ProgressObserver:          m.savedConfig.ProgressObserver,
	}
	if strings.TrimSpace(m.savedConfig.AgenticPersistenceRounds) != "" {
		config.RunTimeout = m.savedConfig.AgenticPersistenceTimeout
	}

	if pricing, ok := m.selectedModelPricing(config.Model); ok {
		config.InputPrice = formatPrice(pricing.InputPerMillion)
		config.OutputPrice = formatPrice(pricing.OutputPerMillion)
		config.HTTPTimeout = defaultHTTPTimeoutMS
	}
	config.ContextWindow = m.contextWindowForModel(config.Model)

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
	if option, ok := m.savedConfig.modelMetadataFor(m.provider, modelID); ok {
		return option.Pricing, true
	}
	return modelPricing{}, false
}

func (m model) contextWindowForModel(modelID string) string {
	if strings.TrimSpace(m.savedConfig.ContextWindow) != "" {
		return strings.TrimSpace(m.savedConfig.ContextWindow)
	}
	for _, option := range m.modelOptions {
		if option.ID == modelID && option.ContextWindowTokens > 0 {
			return strconv.Itoa(option.ContextWindowTokens)
		}
	}
	if option, ok := m.savedConfig.modelMetadataFor(m.provider, modelID); ok &&
		option.ContextWindowTokens > 0 {
		return strconv.Itoa(option.ContextWindowTokens)
	}
	return ""
}

func (m *model) rememberAPIKey(provider provider, apiKey string) {
	m.rememberProviderSecret(provider, "api_key", apiKey)
}

func (m *model) rememberProviderSecret(provider provider, field string, value string) {
	if m.savedConfig.ProviderSecrets == nil {
		m.savedConfig.ProviderSecrets = map[string]map[string]string{}
	}
	providerID := string(provider)
	if m.savedConfig.ProviderSecrets[providerID] == nil {
		m.savedConfig.ProviderSecrets[providerID] = map[string]string{}
	}
	m.savedConfig.ProviderSecrets[providerID][field] = value
}

func (m *model) rememberProviderOption(provider provider, field string, value string) {
	if m.savedConfig.ProviderOptions == nil {
		m.savedConfig.ProviderOptions = map[string]map[string]string{}
	}
	providerID := string(provider)
	if m.savedConfig.ProviderOptions[providerID] == nil {
		m.savedConfig.ProviderOptions[providerID] = map[string]string{}
	}
	m.savedConfig.ProviderOptions[providerID][field] = value
}

func (m *model) changeModel(delta int) {
	if len(m.modelOptions) == 0 {
		return
	}
	m.modelIndex = (m.modelIndex + delta + len(m.modelOptions)) % len(m.modelOptions)
	m.selectedModel = m.modelOptions[m.modelIndex].ID
}

func (m *model) rememberSelectedModelMetadata() bool {
	for _, option := range m.modelOptions {
		if option.ID == m.selectedModel {
			m.savedConfig.rememberModelMetadata(m.provider, option)
			return true
		}
	}
	return false
}

func (m *model) moveProviderPicker(delta int) {
	if len(providers) == 0 {
		m.providerPickerIndex = 0
		return
	}
	m.providerPickerIndex = (m.providerPickerIndex + delta + len(providers)) % len(providers)
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

func providerListIndex(selected provider) int {
	for index, option := range providers {
		if option == selected {
			return index
		}
	}
	return 0
}

func (m *model) moveSkillPicker(delta int) {
	indexes := m.filteredSkillIndexes()
	if len(indexes) == 0 {
		m.skillPickerIndex = 0
		return
	}
	position := 0
	for index, skillIndex := range indexes {
		if skillIndex == m.skillPickerIndex {
			position = index
			break
		}
	}
	position = (position + delta + len(indexes)) % len(indexes)
	m.skillPickerIndex = indexes[position]
}

func (m *model) setSkillPickerQuery(query string) {
	m.skillPickerQuery = query
	m.ensureSkillPickerSelectionVisible()
}

func (m *model) removeLastSkillPickerQueryRune() {
	runes := []rune(m.skillPickerQuery)
	if len(runes) == 0 {
		return
	}
	m.setSkillPickerQuery(string(runes[:len(runes)-1]))
}

func (m *model) ensureSkillPickerSelectionVisible() {
	indexes := m.filteredSkillIndexes()
	if len(indexes) == 0 {
		m.skillPickerIndex = 0
		return
	}
	for _, index := range indexes {
		if index == m.skillPickerIndex {
			return
		}
	}
	m.skillPickerIndex = indexes[0]
}

func (m model) filteredSkillIndexes() []int {
	query := strings.ToLower(strings.TrimSpace(m.skillPickerQuery))
	indexes := make([]int, 0, len(m.skillOptions))
	for index, skill := range m.skillOptions {
		searchText := strings.ToLower(skill.Name + " " + skill.Description)
		if query == "" || strings.Contains(searchText, query) {
			indexes = append(indexes, index)
		}
	}
	return indexes
}

func (m model) selectSkillFromPicker() (tea.Model, tea.Cmd) {
	if len(m.skillOptions) == 0 {
		m.skillPickerOpen = false
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no skills available"})
		return m, nil
	}
	if len(m.filteredSkillIndexes()) == 0 {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "no skill matches " + m.skillPickerQuery})
		return m, nil
	}
	if m.skillPickerIndex < 0 || m.skillPickerIndex >= len(m.skillOptions) {
		m.skillPickerIndex = 0
	}

	selected := m.skillOptions[m.skillPickerIndex]
	m.savedConfig.SkillsMode = ""
	if stringSliceContains(m.savedConfig.SkillNames, selected.Name) {
		m.savedConfig.SkillNames = removeString(m.savedConfig.SkillNames, selected.Name)
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "skill unselected " + selected.Name})
	} else {
		m.savedConfig.SkillNames = append(m.savedConfig.SkillNames, selected.Name)
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "skill selected " + selected.Name})
	}

	if err := validateSkillsConfig(runConfig{
		SkillsMode:        m.savedConfig.SkillsMode,
		SkillsDir:         m.savedConfig.SkillsDir,
		SkillNames:        m.savedConfig.SkillNames,
		AllowSkillScripts: m.savedConfig.AllowSkillScripts,
	}); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	m.skillPickerOpen = false
	return m, nil
}

func (m model) loadModelsCommand() tea.Cmd {
	if m.provider == providerEcho {
		return nil
	}
	return loadModelsCommand(m.runConfig("load models"))
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
	if err := validateAgenticPersistenceConfig(config); err != nil {
		return err
	}
	if err := validatePlannerReviewConfig(config); err != nil {
		return err
	}
	if err := validateToolConfig(config); err != nil {
		return err
	}
	if err := validateSkillsConfig(config); err != nil {
		return err
	}
	if err := validateRouterConfig(config); err != nil {
		return err
	}
	if err := validateContextConfig(config); err != nil {
		return err
	}

	switch config.Provider {
	case providerEcho:
		return nil
	default:
		if _, ok := providerSetups[config.Provider]; !ok {
			return fmt.Errorf("unsupported provider: %s", config.Provider)
		}
		if config.Model == "" {
			return errors.New("model must not be empty for remote providers")
		}
		if err := validateProviderSetup(config); err != nil {
			return err
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
	}
}

func validateProviderSetup(config runConfig) error {
	for _, field := range providerSecretFields(config.Provider) {
		value := strings.TrimSpace(config.ProviderSecrets[field.Name])
		if value == "" && field.Name == "api_key" {
			value = strings.TrimSpace(config.APIKey)
		}
		if value == "" {
			return fmt.Errorf("%s must not be empty", field.Env)
		}
	}
	for _, field := range providerOptionFields(config.Provider) {
		if strings.TrimSpace(config.ProviderOptions[field.Name]) == "" {
			return fmt.Errorf("provider option %s must not be empty for %s", field.Name, config.Provider)
		}
	}
	return nil
}

func validatePlannerReviewConfig(config runConfig) error {
	if strings.TrimSpace(config.PlannerReviewMaxRevisions) == "" {
		return nil
	}
	if config.Workflow != workflowAgentic {
		return errors.New("planner review requires agentic runtime")
	}
	return validatePositiveInt(config.PlannerReviewMaxRevisions, "planner review max revisions")
}

func validateAgenticPersistenceConfig(config runConfig) error {
	if strings.TrimSpace(config.MaxSteps) != "" {
		if err := validatePositiveInt(config.MaxSteps, "max steps"); err != nil {
			return err
		}
	}

	if strings.TrimSpace(config.AgenticPersistenceRounds) == "" {
		return nil
	}

	if config.Workflow != workflowAgentic {
		return errors.New("agentic persistence requires agentic runtime")
	}
	if err := validatePositiveInt(config.AgenticPersistenceRounds, "agentic persistence rounds"); err != nil {
		return err
	}
	if strings.TrimSpace(config.MaxSteps) == "" {
		return errors.New("agentic persistence requires explicit max steps")
	}
	if strings.TrimSpace(config.RunTimeout) == "" {
		return errors.New("agentic persistence requires explicit timeout ms")
	}
	return validatePositiveInt(config.RunTimeout, "run timeout ms")
}

func validateCompactConfig(config runConfig) error {
	switch config.Provider {
	case providerEcho:
		return nil
	default:
		if _, ok := providerSetups[config.Provider]; !ok {
			return fmt.Errorf("unsupported provider: %s", config.Provider)
		}
		if config.Model == "" {
			return errors.New("model must not be empty for remote providers")
		}
		if err := validateProviderSetup(config); err != nil {
			return err
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
		return validatePositiveInt(config.HTTPTimeout, "HTTP timeout ms")
	}
}

func validateContextConfig(config runConfig) error {
	if strings.TrimSpace(config.ContextWindow) != "" {
		if err := validatePositiveInt(config.ContextWindow, "context window tokens"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(config.ContextWarning) != "" {
		if strings.TrimSpace(config.ContextWindow) == "" {
			return errors.New("context warning percent requires context window tokens")
		}
		if err := validatePercent(config.ContextWarning, "context warning percent"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(config.ContextTokenizer) != "" {
		if err := validateExistingFile(strings.TrimSpace(config.ContextTokenizer), "context tokenizer path"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(config.ReservedOutput) != "" {
		if err := validatePositiveInt(config.ReservedOutput, "reserved output tokens"); err != nil {
			return err
		}
	}

	switch strings.TrimSpace(config.RunContextCompact) {
	case "":
		if strings.TrimSpace(config.ContextCompactPct) != "" || strings.TrimSpace(config.MaxContextCompact) != "" {
			return errors.New("run-context compaction thresholds require run-context compaction on")
		}
		return nil
	case "on":
		if strings.TrimSpace(config.ContextWindow) == "" {
			return errors.New("run-context compaction requires context window tokens")
		}
		if strings.TrimSpace(config.ContextCompactPct) == "" {
			return errors.New("run-context compaction requires run-context compact percent")
		}
		if strings.TrimSpace(config.MaxContextCompact) == "" {
			return errors.New("run-context compaction requires max context compactions")
		}
		if err := validatePercent(config.ContextCompactPct, "run-context compact percent"); err != nil {
			return err
		}
		return validatePositiveInt(config.MaxContextCompact, "max context compactions")
	case "off":
		if strings.TrimSpace(config.ContextCompactPct) != "" || strings.TrimSpace(config.MaxContextCompact) != "" {
			return errors.New("run-context compaction off does not accept compaction thresholds")
		}
		return nil
	default:
		return fmt.Errorf("unsupported run-context compaction mode: %s", config.RunContextCompact)
	}
}

func validateSavedContextConfig(config savedConfig) error {
	return validateContextSyntax(runConfig{
		ContextWindow:     config.ContextWindow,
		ContextWarning:    config.ContextWarning,
		ContextTokenizer:  config.ContextTokenizer,
		ReservedOutput:    config.ReservedOutput,
		RunContextCompact: config.RunContextCompact,
		ContextCompactPct: config.ContextCompactPct,
		MaxContextCompact: config.MaxContextCompact,
	})
}

func validateContextSyntax(config runConfig) error {
	if strings.TrimSpace(config.ContextWindow) != "" {
		if err := validatePositiveInt(config.ContextWindow, "context window tokens"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(config.ContextWarning) != "" {
		if strings.TrimSpace(config.ContextWindow) == "" {
			return errors.New("context warning percent requires explicit context window tokens")
		}
		if err := validatePercent(config.ContextWarning, "context warning percent"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(config.ContextTokenizer) != "" {
		if err := validateExistingFile(strings.TrimSpace(config.ContextTokenizer), "context tokenizer path"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(config.ReservedOutput) != "" {
		if err := validatePositiveInt(config.ReservedOutput, "reserved output tokens"); err != nil {
			return err
		}
	}
	switch strings.TrimSpace(config.RunContextCompact) {
	case "":
		if strings.TrimSpace(config.ContextCompactPct) != "" || strings.TrimSpace(config.MaxContextCompact) != "" {
			return errors.New("run-context compaction thresholds require run-context compaction on")
		}
	case "on":
		if strings.TrimSpace(config.ContextCompactPct) == "" {
			return errors.New("run-context compaction requires run-context compact percent")
		}
		if strings.TrimSpace(config.MaxContextCompact) == "" {
			return errors.New("run-context compaction requires max context compactions")
		}
		if err := validatePercent(config.ContextCompactPct, "run-context compact percent"); err != nil {
			return err
		}
		if err := validatePositiveInt(config.MaxContextCompact, "max context compactions"); err != nil {
			return err
		}
	case "off":
		if strings.TrimSpace(config.ContextCompactPct) != "" || strings.TrimSpace(config.MaxContextCompact) != "" {
			return errors.New("run-context compaction off does not accept compaction thresholds")
		}
	default:
		return fmt.Errorf("unsupported run-context compaction mode: %s", config.RunContextCompact)
	}
	return nil
}

func validateRouterConfig(config runConfig) error {
	mode := strings.TrimSpace(config.RouterMode)
	if mode == "" {
		mode = "llm"
	}

	switch mode {
	case "deterministic":
		if strings.TrimSpace(config.RouterModelDir) != "" || strings.TrimSpace(config.RouterTimeout) != "" || strings.TrimSpace(config.RouterConfidence) != "" {
			return errors.New("deterministic router does not accept local router settings")
		}
		return nil
	case "llm":
		if strings.TrimSpace(config.RouterModelDir) != "" || strings.TrimSpace(config.RouterTimeout) != "" || strings.TrimSpace(config.RouterConfidence) != "" {
			return errors.New("llm router does not accept local router settings")
		}
		return nil
	case "local":
		if strings.TrimSpace(config.RouterModelDir) == "" {
			return errors.New("router model dir must not be empty for local router")
		}
		if err := validatePositiveInt(config.RouterTimeout, "router timeout ms"); err != nil {
			return err
		}
		return validateProbability(config.RouterConfidence, "router confidence")
	default:
		return fmt.Errorf("unsupported router mode: %s", config.RouterMode)
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
	case "time":
		if strings.TrimSpace(config.ToolRoot) != "" || len(config.TestCommands) != 0 {
			return errors.New("time tool harness does not accept tool root or test commands")
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
		if err := validateToolRootCoversTaskPaths(config); err != nil {
			return err
		}
		if len(config.TestCommands) > 0 {
			if config.ToolHarness != "code-edit" {
				return errors.New("test commands require code-edit tool harness")
			}
			if config.ToolApproval != "full-access" && config.ToolApproval != "ask-before-write" {
				return errors.New("test commands require full-access or ask-before-write approval mode")
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

func validateRunnableConfig(config runConfig) error {
	return nil
}

func validateToolRootCoversTaskPaths(config runConfig) error {
	root := filepath.Clean(strings.TrimSpace(config.ToolRoot))
	for _, requestedPath := range taskAbsolutePaths(config.Task) {
		if !pathWithin(root, requestedPath) {
			return fmt.Errorf(
				"tool root %s does not cover requested path %s; run /tools %s %s %s %s %s or choose a broader explicit tool root",
				root,
				requestedPath,
				config.ToolHarness,
				requestedPath,
				config.ToolTimeout,
				config.ToolMaxRounds,
				config.ToolApproval,
			)
		}
	}
	return nil
}

func taskAbsolutePaths(text string) []string {
	paths := []string{}
	seen := map[string]bool{}

	for index := 0; index < len(text); index++ {
		if text[index] != '/' {
			continue
		}
		if index > 0 && (text[index-1] == ':' || text[index-1] == '/') {
			continue
		}

		end := index
		for end < len(text) && text[end] > ' ' {
			end++
		}

		candidate := strings.Trim(text[index:end], "\"'`.,;:!?)])}>")
		candidate = filepath.Clean(candidate)
		if plausibleTaskAbsolutePath(candidate) && !seen[candidate] {
			paths = append(paths, candidate)
			seen[candidate] = true
		}
		index = end
	}

	return paths
}

func plausibleTaskAbsolutePath(path string) bool {
	if path == "" || strings.HasPrefix(path, "//") || !filepath.IsAbs(path) || path == string(os.PathSeparator) {
		return false
	}

	trimmed := strings.Trim(path, string(os.PathSeparator))
	if trimmed == "" {
		return false
	}

	segments := strings.Split(trimmed, string(os.PathSeparator))
	if strings.Contains(segments[0], ".") {
		return false
	}
	if len(segments) >= 2 {
		return true
	}

	switch segments[0] {
	case "Users", "home", "tmp", "private", "var", "Volumes", "workspace", "workspaces", "mnt", "opt", "usr", "etc", "srv", "root":
		return true
	default:
		return false
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

func validateProbability(value string, label string) error {
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil || parsed <= 0 || parsed > 1 {
		return fmt.Errorf("%s must be greater than 0 and less than or equal to 1", label)
	}
	return nil
}

func validatePercent(value string, label string) error {
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 1 || parsed > 100 {
		return fmt.Errorf("%s must be an integer from 1 to 100", label)
	}
	return nil
}

func validateExistingFile(path string, label string) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("%s must not be empty", label)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("%s does not exist: %s", label, path)
	}
	if info.IsDir() {
		return fmt.Errorf("%s must be a file, got directory: %s", label, path)
	}
	return nil
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
		"Use the selector below to approve or deny this request.",
		"Run /allow-tools to enable "+harness+" for this root with timeout_ms="+defaultFilesystemToolTimeout+" max_rounds="+defaultFilesystemToolMaxRounds+" and retry now.",
		"Run /yolo-tools to enable "+harness+" full-access for this root with timeout_ms="+defaultFilesystemToolTimeout+" max_rounds="+defaultFilesystemToolMaxRounds+" and retry now.",
		"Run /deny-tools to decline.",
	)
	return strings.Join(lines, "\n")
}

func mcpBrowserPermissionText(configPath string) string {
	return strings.Join([]string{
		"MCP browser permission required: browser navigation uses network-risk tools.",
		"mcp config: " + configPath,
		"Use the selector below to approve or deny this request.",
		"Run /allow-tools to enable interactive ask-before-write approval or /yolo-tools for full-access and retry now.",
		"Run /deny-tools to decline.",
	}, "\n")
}

func resolveConfig(config runConfig) (runConfig, error) {
	switch config.Provider {
	case providerEcho:
		config.Model = "echo"
		config.InputPrice = "0"
		config.OutputPrice = "0"
		config.HTTPTimeout = defaultHTTPTimeoutMS
		return config, nil
	default:
		if err := requireRemoteIdentity(config); err != nil {
			return runConfig{}, err
		}
		if hasResolvedRuntimeOptions(config) {
			return config, nil
		}
		return runConfig{}, fmt.Errorf("pricing is missing for model %q; load models through /models reload or configure explicit pricing", config.Model)
	}
}

func hasResolvedRuntimeOptions(config runConfig) bool {
	return config.InputPrice != "" && config.OutputPrice != "" && config.HTTPTimeout != ""
}

func requireRemoteIdentity(config runConfig) error {
	if config.Model == "" {
		return errors.New("model must not be empty for remote providers")
	}
	return validateProviderSetup(config)
}

func parseProvider(value string) (provider, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	candidate := provider(normalized)
	if _, ok := providerSetups[candidate]; ok {
		return candidate, nil
	}
	return "", fmt.Errorf("unsupported provider: %s", value)
}

func parseWorkflow(value string) (runWorkflow, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "agentic", "":
		return workflowAgentic, nil
	default:
		return "", fmt.Errorf("unsupported runtime: %s", value)
	}
}

func (p provider) Label() string {
	if setup, ok := providerSetups[p]; ok && strings.TrimSpace(setup.Label) != "" {
		return setup.Label
	}
	return string(p)
}

func apiKeyName(provider provider) string {
	for _, field := range providerSecretFields(provider) {
		if field.Name == "api_key" {
			return field.Env
		}
	}
	return ""
}

func providerSecretFields(provider provider) []providerField {
	return providerSetups[provider].SecretFields
}

func providerOptionFields(provider provider) []providerField {
	return providerSetups[provider].OptionFields
}

func providerHasSecretField(provider provider, name string) bool {
	for _, field := range providerSecretFields(provider) {
		if field.Name == name {
			return true
		}
	}
	return false
}

func providerHasOptionField(provider provider, name string) bool {
	for _, field := range providerOptionFields(provider) {
		if field.Name == name {
			return true
		}
	}
	return false
}

func keyStatus(apiKey string) string {
	if strings.TrimSpace(apiKey) == "" {
		return "missing"
	}
	return "saved"
}

func (m model) providerSetupStatus() string {
	if !m.providerSet {
		return "missing"
	}
	if m.provider == providerEcho {
		return "not required"
	}
	missing := []string{}
	for _, field := range providerSecretFields(m.provider) {
		if strings.TrimSpace(m.savedConfig.providerSecret(m.provider, field.Name)) == "" {
			missing = append(missing, field.Name)
		}
	}
	options := m.savedConfig.providerOptionsFor(m.provider)
	for _, field := range providerOptionFields(m.provider) {
		if strings.TrimSpace(options[field.Name]) == "" {
			missing = append(missing, field.Name)
		}
	}
	if len(missing) > 0 {
		return "missing " + strings.Join(missing, ",")
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
	case "time":
		return "tools: time timeout_ms=" + emptyAsNone(m.savedConfig.ToolTimeout) + " max_rounds=" + emptyAsNone(m.savedConfig.ToolMaxRounds) + " approval=" + emptyAsNone(m.savedConfig.ToolApproval)
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

func (m model) toolRootBaseDir() string {
	if strings.TrimSpace(m.workingDir) != "" {
		return m.workingDir
	}
	workingDir, err := currentWorkingDir()
	if err != nil {
		return ""
	}
	return workingDir
}

func (m model) contextStatus() string {
	window := m.contextWindowForModel(m.modelID())
	warning := strings.TrimSpace(m.savedConfig.ContextWarning)
	compaction := strings.TrimSpace(m.savedConfig.RunContextCompact)
	if compaction == "" {
		compaction = "off"
	}

	parts := []string{
		"context: window_tokens=" + emptyAsNone(window),
		"warning_percent=" + emptyAsNone(warning),
		"tokenizer=" + emptyAsNone(m.savedConfig.ContextTokenizer),
		"reserved_output_tokens=" + emptyAsNone(m.savedConfig.ReservedOutput),
		"run_compaction=" + compaction,
	}
	if compaction == "on" {
		parts = append(parts,
			"compact_percent="+emptyAsNone(m.savedConfig.ContextCompactPct),
			"max_compactions="+emptyAsNone(m.savedConfig.MaxContextCompact),
		)
	}
	return strings.Join(parts, " ")
}

func (m model) progressStatus() string {
	if m.savedConfig.ProgressObserver {
		return "progress observer: on"
	}
	return "progress observer: off"
}

func runningStatus(config runConfig) string {
	idleTimeout := runTimeoutMS(config)
	return "running " + config.Provider.Label() + " / " + config.Model + " / strategy pending / " + runAgenticPersistenceStatus(config) + " / " + runPlannerReviewStatus(config) + " / " + runRouterStatus(config) + " / " + runProgressStatus(config) + " / idle_timeout_ms=" + idleTimeout + " hard_cap_ms=" + hardCapTimeoutMS(idleTimeout) + " / " + runToolsStatus(config) + " / " + runContextStatus(config) + " / " + runSkillsStatus(config) + " / log=" + emptyAsNone(config.LogFile) + "..."
}

func hardCapTimeoutMS(idleTimeout string) string {
	timeout, err := strconv.Atoi(strings.TrimSpace(idleTimeout))
	if err != nil || timeout <= 0 {
		return "(invalid)"
	}
	return strconv.Itoa(timeout * 3)
}

func runAgenticPersistenceStatus(config runConfig) string {
	if strings.TrimSpace(config.AgenticPersistenceRounds) == "" {
		return "persistence off"
	}
	return "persistence rounds=" + config.AgenticPersistenceRounds + " max_steps=" + runMaxSteps(config)
}

func runPlannerReviewStatus(config runConfig) string {
	if strings.TrimSpace(config.PlannerReviewMaxRevisions) == "" {
		return "planner review off"
	}
	return "planner review max_revisions=" + config.PlannerReviewMaxRevisions
}

func runProgressStatus(config runConfig) string {
	if config.ProgressObserver {
		return "progress observer on"
	}
	return "progress observer off"
}

func runToolsStatus(config runConfig) string {
	switch config.ToolHarness {
	case "":
		if strings.TrimSpace(config.MCPConfig) != "" {
			return "tools mcp config=" + config.MCPConfig
		}
		return "tools off"
	case "time":
		return "tools time timeout_ms=" + emptyAsNone(config.ToolTimeout) + " max_rounds=" + emptyAsNone(config.ToolMaxRounds)
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

func runContextStatus(config runConfig) string {
	parts := []string{"context window_tokens=" + emptyAsNone(config.ContextWindow)}
	if strings.TrimSpace(config.ContextWarning) != "" {
		parts = append(parts, "warning_percent="+config.ContextWarning)
	}
	if strings.TrimSpace(config.ContextTokenizer) != "" {
		parts = append(parts, "tokenizer="+config.ContextTokenizer)
	}
	if strings.TrimSpace(config.ReservedOutput) != "" {
		parts = append(parts, "reserved_output_tokens="+config.ReservedOutput)
	}
	if strings.TrimSpace(config.RunContextCompact) == "on" {
		parts = append(parts,
			"run_compaction=on",
			"compact_percent="+config.ContextCompactPct,
			"max_compactions="+config.MaxContextCompact,
		)
	}
	return strings.Join(parts, " ")
}

func (m model) routerStatus() string {
	mode := strings.TrimSpace(m.savedConfig.RouterMode)
	if mode == "" || mode == "llm" {
		return "router: llm current model"
	}
	if mode == "deterministic" {
		return "router: deterministic"
	}
	if mode == "local" {
		return "router: local dir=" + emptyAsNone(m.savedConfig.RouterModelDir) + " timeout_ms=" + emptyAsNone(m.savedConfig.RouterTimeout) + " confidence=" + emptyAsNone(m.savedConfig.RouterConfidence)
	}
	return "router: unsupported " + mode
}

func runRouterStatus(config runConfig) string {
	mode := strings.TrimSpace(config.RouterMode)
	if mode == "" || mode == "llm" {
		return "router llm current model"
	}
	if mode == "deterministic" {
		return "router deterministic"
	}
	if mode == "local" {
		return "router local dir=" + emptyAsNone(config.RouterModelDir) + " timeout_ms=" + emptyAsNone(config.RouterTimeout) + " confidence=" + emptyAsNone(config.RouterConfidence)
	}
	return "router unsupported " + mode
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
	theme, err := savedTUITheme(m.savedConfig)
	if err != nil {
		return fmt.Errorf("invalid saved theme in TUI config: %w", err)
	}
	m.theme = theme

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
			Workflow:      workflowAgentic,
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
			Workflow:      workflowAgentic,
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

	if err := validateRouterConfig(runConfig{
		RouterMode:       m.savedConfig.RouterMode,
		RouterModelDir:   m.savedConfig.RouterModelDir,
		RouterTimeout:    m.savedConfig.RouterTimeout,
		RouterConfidence: m.savedConfig.RouterConfidence,
	}); err != nil {
		return fmt.Errorf("invalid saved router in TUI config: %w", err)
	}

	if err := validateSavedContextConfig(m.savedConfig); err != nil {
		return fmt.Errorf("invalid saved context settings in TUI config: %w", err)
	}

	if err := validateSavedAgenticPersistenceConfig(m.savedConfig); err != nil {
		return fmt.Errorf("invalid saved agentic persistence in TUI config: %w", err)
	}

	if err := validateSavedPlannerReviewConfig(m.savedConfig); err != nil {
		return fmt.Errorf("invalid saved planner review in TUI config: %w", err)
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

func stringSliceContains(values []string, value string) bool {
	for _, current := range values {
		if current == value {
			return true
		}
	}
	return false
}

func (config savedConfig) apiKeyFor(provider provider) string {
	return config.providerSecret(provider, "api_key")
}

func (config savedConfig) providerSecret(provider provider, field string) string {
	if config.ProviderSecrets != nil {
		if value := strings.TrimSpace(config.ProviderSecrets[string(provider)][field]); value != "" {
			return value
		}
	}
	if field == "api_key" {
		switch provider {
		case providerOpenAI:
			return strings.TrimSpace(config.OpenAIAPIKey)
		case providerOpenRouter:
			return strings.TrimSpace(config.OpenRouterAPIKey)
		}
	}
	return ""
}

func (config savedConfig) providerSecretsFor(provider provider) map[string]string {
	if config.ProviderSecrets == nil {
		return nil
	}
	return copyStringMap(config.ProviderSecrets[string(provider)])
}

func (config savedConfig) providerOptionsFor(provider provider) map[string]string {
	if config.ProviderOptions == nil {
		return nil
	}
	return copyStringMap(config.ProviderOptions[string(provider)])
}

func (config savedConfig) modelFor(provider provider) string {
	if config.ProviderModels == nil {
		switch provider {
		case providerOpenAI:
			return strings.TrimSpace(config.OpenAIModel)
		case providerOpenRouter:
			return strings.TrimSpace(config.OpenRouterModel)
		default:
			return ""
		}
	}
	if model := strings.TrimSpace(config.ProviderModels[string(provider)]); model != "" {
		return model
	}
	switch provider {
	case providerOpenAI:
		return strings.TrimSpace(config.OpenAIModel)
	case providerOpenRouter:
		return strings.TrimSpace(config.OpenRouterModel)
	default:
		return ""
	}
}

func (config savedConfig) modelMetadataFor(provider provider, model string) (modelOption, bool) {
	model = strings.TrimSpace(model)
	if model == "" || config.ProviderModelMetadata == nil {
		return modelOption{}, false
	}
	metadata := config.ProviderModelMetadata[string(provider)]
	if metadata == nil {
		return modelOption{}, false
	}
	option, ok := metadata[model]
	if !ok || strings.TrimSpace(option.ID) == "" {
		return modelOption{}, false
	}
	return option, true
}

func (config *savedConfig) rememberModel(provider provider, model string) {
	if config.ProviderModels == nil {
		config.ProviderModels = map[string]string{}
	}
	config.ProviderModels[string(provider)] = model
	switch provider {
	case providerOpenAI:
		config.OpenAIModel = ""
	case providerOpenRouter:
		config.OpenRouterModel = ""
	}
}

func (config *savedConfig) rememberModelMetadata(provider provider, option modelOption) {
	if strings.TrimSpace(option.ID) == "" {
		return
	}
	if config.ProviderModelMetadata == nil {
		config.ProviderModelMetadata = map[string]map[string]modelOption{}
	}
	providerID := string(provider)
	if config.ProviderModelMetadata[providerID] == nil {
		config.ProviderModelMetadata[providerID] = map[string]modelOption{}
	}
	config.ProviderModelMetadata[providerID][option.ID] = option
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
	marker := agentStatusMarker(status)
	attempt := agent.Attempt
	if attempt == 0 {
		attempt = 1
	}
	decision := ""
	if strings.TrimSpace(agent.Decision.Mode) != "" {
		decision = "  decision " + agent.Decision.Mode
	}
	return fmt.Sprintf("%s%s %s  %s  attempt %d%s", indent, marker, agent.ID, status, attempt, decision)
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

func (m *model) scrollChat(delta int) {
	m.chatScroll += delta
	m.clampChatScroll()
}

func (m *model) clampChatScroll() {
	maxScroll := m.maxChatScroll()
	if m.chatScroll < 0 {
		m.chatScroll = 0
	}
	if m.chatScroll > maxScroll {
		m.chatScroll = maxScroll
	}
}

func (m model) maxChatScroll() int {
	height := m.chatViewportHeight()
	if height <= 0 {
		return 0
	}
	text := strings.TrimRight(m.fullChatText(), "\n")
	if text == "" {
		return 0
	}
	lineCount := len(strings.Split(text, "\n"))
	if lineCount <= height {
		return 0
	}
	return lineCount - height
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
	model, err := initialModelWithArgs(os.Args[1:])
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
