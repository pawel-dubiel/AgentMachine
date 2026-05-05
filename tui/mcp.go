package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	defaultMCPToolTimeout   = "120000"
	defaultMCPToolMaxRounds = "50"
	defaultMCPToolApproval  = "ask-before-write"
	legacyMCPToolMaxRounds  = "6"
)

type mcpConfigFile struct {
	Servers []mcpServerConfig `json:"servers"`
}

type mcpServerConfig struct {
	ID        string            `json:"id"`
	Transport string            `json:"transport"`
	Command   string            `json:"command"`
	Args      []string          `json:"args"`
	Env       map[string]string `json:"env"`
	Tools     []mcpToolConfig   `json:"tools"`
}

type mcpToolConfig struct {
	Name        string         `json:"name"`
	Permission  string         `json:"permission"`
	Risk        string         `json:"risk"`
	InputSchema map[string]any `json:"inputSchema,omitempty"`
}

func (m model) handleMCPCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) == 0 || args[0] == "status" || args[0] == "list" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.mcpStatus()})
		return m, nil
	}

	switch args[0] {
	case "add":
		return m.handleMCPAddCommand(args[1:])
	case "remove":
		return m.handleMCPRemoveCommand(args[1:])
	case "off":
		if len(args) != 1 {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /mcp off"})
			return m, nil
		}
		m.savedConfig.MCPConfig = ""
		if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
			m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
			return m, nil
		}
		m.messages = append(m.messages, chatMessage{Role: "system", Text: m.mcpStatus()})
		return m, nil
	default:
		m.messages = append(m.messages, chatMessage{Role: "system", Text: mcpUsage()})
		return m, nil
	}
}

func (m model) handleMCPAddCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) < 2 || args[0] != "playwright" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /mcp add playwright <command> [args...]"})
		return m, nil
	}

	configPath := managedMCPConfigPath(m.configPath)
	if err := writePlaywrightMCPConfig(configPath, args[1:]); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	nextConfig := m.savedConfig
	nextConfig.MCPConfig = configPath
	nextConfig.ToolHarness = ""
	nextConfig.ToolRoot = ""
	nextConfig.TestCommands = nil
	nextConfig.ToolTimeout = defaultMCPToolTimeout
	nextConfig.ToolMaxRounds = defaultMCPToolMaxRounds
	nextConfig.ToolApproval = defaultMCPToolApproval

	if err := validateToolConfig(runConfig{
		ToolTimeout:   nextConfig.ToolTimeout,
		ToolMaxRounds: nextConfig.ToolMaxRounds,
		ToolApproval:  nextConfig.ToolApproval,
		MCPConfig:     nextConfig.MCPConfig,
	}); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.savedConfig = nextConfig
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.messages = append(m.messages, chatMessage{Role: "system", Text: "added MCP playwright config=" + configPath + " approval=ask-before-write; filesystem tools disabled for this MCP-only preset"})
	return m, nil
}

func (m model) handleMCPRemoveCommand(args []string) (tea.Model, tea.Cmd) {
	if len(args) != 1 || args[0] != "playwright" {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "usage: /mcp remove playwright"})
		return m, nil
	}

	managedPath := managedMCPConfigPath(m.configPath)
	if m.savedConfig.MCPConfig != managedPath {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: "playwright MCP preset is not the active managed MCP config"})
		return m, nil
	}

	m.savedConfig.MCPConfig = ""
	if err := os.Remove(managedPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}
	if err := saveSavedConfig(m.configPath, m.savedConfig); err != nil {
		m.messages = append(m.messages, chatMessage{Role: "system", Text: err.Error()})
		return m, nil
	}

	m.messages = append(m.messages, chatMessage{Role: "system", Text: "removed MCP playwright"})
	return m, nil
}

func (m model) mcpStatus() string {
	if strings.TrimSpace(m.savedConfig.MCPConfig) == "" {
		return "mcp: off"
	}
	return "mcp: config=" + m.savedConfig.MCPConfig + " timeout_ms=" + emptyAsNone(m.savedConfig.ToolTimeout) + " max_rounds=" + emptyAsNone(m.savedConfig.ToolMaxRounds) + " approval=" + emptyAsNone(m.savedConfig.ToolApproval)
}

func mcpUsage() string {
	return "usage: /mcp add playwright <command> [args...]|list|status|remove playwright|off"
}

func managedMCPConfigPath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "mcp.json")
}

func migrateManagedMCPConfig(configPath string, config *savedConfig) error {
	path := strings.TrimSpace(config.MCPConfig)
	if path == "" || path != managedMCPConfigPath(configPath) {
		return nil
	}

	return migrateManagedPlaywrightMCPConfig(path)
}

func migrateLegacyMCPToolMaxRounds(config *savedConfig) bool {
	if strings.TrimSpace(config.MCPConfig) == "" {
		return false
	}
	if strings.TrimSpace(config.ToolMaxRounds) != legacyMCPToolMaxRounds {
		return false
	}

	config.ToolMaxRounds = defaultMCPToolMaxRounds
	return true
}

func migrateManagedPlaywrightMCPConfig(path string) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("managed MCP config %s is missing; rerun /mcp add playwright <command> [args...]", path)
	}
	if err != nil {
		return fmt.Errorf("failed to read managed MCP config %s: %w", path, err)
	}

	var config mcpConfigFile
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("failed to parse managed MCP config %s: %w", path, err)
	}
	if !managedPlaywrightConfig(config) {
		return fmt.Errorf("managed MCP config %s is not the TUI Playwright preset; use /mcp-config for standalone MCP configs", path)
	}

	changed := false
	for serverIndex := range config.Servers {
		for toolIndex := range config.Servers[serverIndex].Tools {
			tool := &config.Servers[serverIndex].Tools[toolIndex]
			switch {
			case tool.Name == "browser_navigate" && tool.Permission == "mcp_playwright_browser_navigate":
				if !hasPlaywrightNavigateSchema(tool.InputSchema) {
					tool.InputSchema = playwrightNavigateInputSchema()
					changed = true
				}
			case tool.Name == "browser_snapshot" && tool.Permission == "mcp_playwright_browser_snapshot":
				if !hasPlaywrightSnapshotSchema(tool.InputSchema) {
					tool.InputSchema = playwrightSnapshotInputSchema()
					changed = true
				}
			case len(tool.InputSchema) == 0:
				return fmt.Errorf("managed MCP tool %s is missing inputSchema", tool.Name)
			}
		}
	}

	if !changed {
		return nil
	}

	return writeMCPConfigFile(path, config)
}

func managedPlaywrightConfig(config mcpConfigFile) bool {
	if len(config.Servers) != 1 {
		return false
	}
	server := config.Servers[0]
	if server.ID != "playwright" || server.Transport != "stdio" || strings.TrimSpace(server.Command) == "" {
		return false
	}

	seenNavigate := false
	seenSnapshot := false
	for _, tool := range server.Tools {
		switch {
		case tool.Name == "browser_navigate" && tool.Permission == "mcp_playwright_browser_navigate" && tool.Risk == "network":
			seenNavigate = true
		case tool.Name == "browser_snapshot" && tool.Permission == "mcp_playwright_browser_snapshot" && tool.Risk == "read":
			seenSnapshot = true
		}
	}
	return seenNavigate && seenSnapshot
}

func writePlaywrightMCPConfig(path string, commandArgs []string) error {
	command, args, err := playwrightCommand(commandArgs)
	if err != nil {
		return err
	}

	config := mcpConfigFile{
		Servers: []mcpServerConfig{
			{
				ID:        "playwright",
				Transport: "stdio",
				Command:   command,
				Args:      args,
				Env:       map[string]string{},
				Tools: []mcpToolConfig{
					{
						Name:        "browser_navigate",
						Permission:  "mcp_playwright_browser_navigate",
						Risk:        "network",
						InputSchema: playwrightNavigateInputSchema(),
					},
					{
						Name:        "browser_snapshot",
						Permission:  "mcp_playwright_browser_snapshot",
						Risk:        "read",
						InputSchema: playwrightSnapshotInputSchema(),
					},
				},
			},
		},
	}

	return writeMCPConfigFile(path, config)
}

func writeMCPConfigFile(path string, config mcpConfigFile) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("failed to create MCP config directory: %w", err)
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to encode MCP config: %w", err)
	}

	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("failed to write MCP config %s: %w", path, err)
	}
	return nil
}

func playwrightNavigateInputSchema() map[string]any {
	return map[string]any{
		"type":     "object",
		"required": []string{"url"},
		"properties": map[string]any{
			"url": map[string]any{
				"type":        "string",
				"description": "Absolute URL to navigate to.",
			},
		},
		"additionalProperties": false,
	}
}

func playwrightSnapshotInputSchema() map[string]any {
	return map[string]any{"type": "object"}
}

func hasPlaywrightNavigateSchema(schema map[string]any) bool {
	if schema["type"] != "object" {
		return false
	}
	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		return false
	}
	urlSchema, ok := properties["url"].(map[string]any)
	if !ok || urlSchema["type"] != "string" {
		return false
	}
	return schemaRequiredIncludes(schema["required"], "url")
}

func hasPlaywrightSnapshotSchema(schema map[string]any) bool {
	return schema["type"] == "object"
}

func schemaRequiredIncludes(required any, field string) bool {
	switch values := required.(type) {
	case []any:
		for _, value := range values {
			if value == field {
				return true
			}
		}
	case []string:
		for _, value := range values {
			if value == field {
				return true
			}
		}
	}
	return false
}

func playwrightCommand(commandArgs []string) (string, []string, error) {
	if len(commandArgs) == 0 || strings.TrimSpace(commandArgs[0]) == "" {
		return "", nil, errors.New("playwright MCP command must not be empty")
	}

	command := commandArgs[0]
	args := append([]string(nil), commandArgs[1:]...)

	if filepath.Base(command) == "npx" {
		args = normalizeNpxPlaywrightArgs(args, filepath.Join(os.TempDir(), "agent-machine-playwright-mcp-npm-cache"))
	} else {
		args = ensurePackageArg(args, "@playwright/mcp@latest")
		args = ensureServerArg(args, "--headless")
	}

	return command, args, nil
}

func normalizeNpxPlaywrightArgs(args []string, cachePath string) []string {
	packageArg, otherArgs := splitPlaywrightPackageArg(args)
	npxOptions, serverArgs := splitNpxAndServerArgs(otherArgs)
	npxOptions = ensureArg(npxOptions, "--yes")
	npxOptions = ensureNpxCache(npxOptions, cachePath)
	serverArgs = ensureServerArg(serverArgs, "--headless")
	return append(append(npxOptions, packageArg), serverArgs...)
}

func splitPlaywrightPackageArg(args []string) (string, []string) {
	rest := make([]string, 0, len(args))
	for _, arg := range args {
		if strings.HasPrefix(arg, "@playwright/mcp") {
			return arg, append(rest, args[len(rest)+1:]...)
		}
		rest = append(rest, arg)
	}
	return "@playwright/mcp@latest", rest
}

func splitNpxAndServerArgs(args []string) ([]string, []string) {
	npxOptions := []string{}
	serverArgs := []string{}

	for index := 0; index < len(args); index++ {
		arg := args[index]

		switch {
		case arg == "--yes" || arg == "-y" || strings.HasPrefix(arg, "--cache="):
			npxOptions = append(npxOptions, arg)
		case arg == "--cache" && index+1 < len(args):
			npxOptions = append(npxOptions, arg, args[index+1])
			index++
		default:
			serverArgs = append(serverArgs, arg)
		}
	}

	return npxOptions, serverArgs
}

func ensureArg(args []string, value string) []string {
	for _, arg := range args {
		if arg == value {
			return args
		}
	}
	return append([]string{value}, args...)
}

func ensurePackageArg(args []string, value string) []string {
	for _, arg := range args {
		if strings.HasPrefix(arg, "@playwright/mcp") {
			return args
		}
	}
	return append(args, value)
}

func ensureServerArg(args []string, value string) []string {
	for _, arg := range args {
		if arg == value {
			return args
		}
	}
	return append(args, value)
}

func ensureNpxCache(args []string, path string) []string {
	for i, arg := range args {
		if arg == "--cache" && i+1 < len(args) {
			return args
		}
		if strings.HasPrefix(arg, "--cache=") {
			return args
		}
	}
	return append(args, "--cache", path)
}
