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
	defaultMCPToolMaxRounds = "6"
	defaultMCPToolApproval  = "full-access"
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
	Name       string `json:"name"`
	Permission string `json:"permission"`
	Risk       string `json:"risk"`
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

	m.messages = append(m.messages, chatMessage{Role: "system", Text: "added MCP playwright config=" + configPath + " approval=full-access; filesystem tools disabled for this MCP-only preset"})
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
						Name:       "browser_navigate",
						Permission: "mcp_playwright_browser_navigate",
						Risk:       "network",
					},
					{
						Name:       "browser_snapshot",
						Permission: "mcp_playwright_browser_snapshot",
						Risk:       "read",
					},
				},
			},
		},
	}

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
