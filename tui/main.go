package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type summary struct {
	RunID       string         `json:"run_id"`
	Status      string         `json:"status"`
	FinalOutput string         `json:"final_output"`
	Usage       usageSummary   `json:"usage"`
	Events      []eventSummary `json:"events"`
}

type usageSummary struct {
	Agents       int     `json:"agents"`
	InputTokens  int     `json:"input_tokens"`
	OutputTokens int     `json:"output_tokens"`
	TotalTokens  int     `json:"total_tokens"`
	CostUSD      float64 `json:"cost_usd"`
}

type eventSummary struct {
	Type    string `json:"type"`
	AgentID string `json:"agent_id"`
	Status  string `json:"status"`
}

type runResultMsg struct {
	Summary summary
	Raw     string
	Err     error
}

type screen int

const (
	screenInput screen = iota
	screenRunning
	screenDone
)

type model struct {
	input   textinput.Model
	screen  screen
	summary summary
	raw     string
	err     error
}

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("63"))
	labelStyle = lipgloss.NewStyle().Bold(true)
	errorStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
	hintStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

func initialModel() model {
	input := textinput.New()
	input.Placeholder = "Describe the task for AgentMachine"
	input.Focus()
	input.CharLimit = 500
	input.Width = 72

	return model{
		input:  input,
		screen: screenInput,
	}
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
		case "q":
			if m.screen == screenDone {
				return m, tea.Quit
			}
		case "enter":
			if m.screen == screenInput {
				task := strings.TrimSpace(m.input.Value())
				if task == "" {
					m.err = errors.New("task must not be empty")
					return m, nil
				}

				m.err = nil
				m.screen = screenRunning
				return m, runCommand(task)
			}
		case "esc":
			if m.screen == screenDone {
				m.screen = screenInput
				m.err = nil
				m.raw = ""
				m.summary = summary{}
				return m, nil
			}
		}

	case runResultMsg:
		m.screen = screenDone
		m.summary = msg.Summary
		m.raw = msg.Raw
		m.err = msg.Err
		return m, nil
	}

	if m.screen == screenInput {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}

	return m, nil
}

func (m model) View() string {
	var b strings.Builder

	b.WriteString(titleStyle.Render("AgentMachine TUI"))
	b.WriteString("\n\n")

	switch m.screen {
	case screenInput:
		b.WriteString(labelStyle.Render("Task"))
		b.WriteString("\n")
		b.WriteString(m.input.View())
		b.WriteString("\n\n")
		b.WriteString(hintStyle.Render("Profile: local echo workflow | Enter: run | Ctrl+C: quit"))
		if m.err != nil {
			b.WriteString("\n\n")
			b.WriteString(errorStyle.Render(m.err.Error()))
		}

	case screenRunning:
		b.WriteString("Running local echo workflow...\n\n")
		b.WriteString(hintStyle.Render("AgentMachine is executing through mix agent_machine.run."))

	case screenDone:
		if m.err != nil {
			b.WriteString(errorStyle.Render("Run failed"))
			b.WriteString("\n\n")
			b.WriteString(m.err.Error())
			if strings.TrimSpace(m.raw) != "" {
				b.WriteString("\n\n")
				b.WriteString(labelStyle.Render("Raw output"))
				b.WriteString("\n")
				b.WriteString(m.raw)
			}
		} else {
			b.WriteString(labelStyle.Render("Status"))
			b.WriteString(": ")
			b.WriteString(m.summary.Status)
			b.WriteString("\n")
			b.WriteString(labelStyle.Render("Run ID"))
			b.WriteString(": ")
			b.WriteString(m.summary.RunID)
			b.WriteString("\n\n")
			b.WriteString(labelStyle.Render("Final output"))
			b.WriteString("\n")
			b.WriteString(emptyAsNone(m.summary.FinalOutput))
			b.WriteString("\n\n")
			b.WriteString(labelStyle.Render("Usage"))
			b.WriteString(fmt.Sprintf("\nagents: %d\ninput tokens: %d\noutput tokens: %d\ntotal tokens: %d\ncost usd: %.6f",
				m.summary.Usage.Agents,
				m.summary.Usage.InputTokens,
				m.summary.Usage.OutputTokens,
				m.summary.Usage.TotalTokens,
				m.summary.Usage.CostUSD,
			))
			b.WriteString("\n\n")
			b.WriteString(labelStyle.Render("Events"))
			for _, event := range m.summary.Events {
				b.WriteString("\n")
				b.WriteString("- ")
				b.WriteString(event.Type)
				if event.AgentID != "" {
					b.WriteString(" ")
					b.WriteString(event.AgentID)
				}
				if event.Status != "" {
					b.WriteString(" ")
					b.WriteString(event.Status)
				}
			}
		}

		b.WriteString("\n\n")
		b.WriteString(hintStyle.Render("Esc: new task | q: quit"))
	}

	return b.String()
}

func runCommand(task string) tea.Cmd {
	return func() tea.Msg {
		summary, raw, err := runAgentMachine(task)
		return runResultMsg{Summary: summary, Raw: raw, Err: err}
	}
}

func runAgentMachine(task string) (summary, string, error) {
	args := buildRunArgs(task)
	cmd := exec.Command("mix", args...)
	cmd.Dir = projectRoot()

	output, err := cmd.CombinedOutput()
	raw := strings.TrimSpace(string(output))
	if err != nil {
		return summary{}, raw, fmt.Errorf("mix command failed: %w", err)
	}

	parsed, parseErr := parseSummary(raw)
	if parseErr != nil {
		return summary{}, raw, parseErr
	}

	return parsed, raw, nil
}

func buildRunArgs(task string) []string {
	return []string{
		"agent_machine.run",
		"--provider", "echo",
		"--timeout-ms", "5000",
		"--max-steps", "2",
		"--max-attempts", "1",
		"--json",
		task,
	}
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
	return parsed, nil
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

func emptyAsNone(value string) string {
	if strings.TrimSpace(value) == "" {
		return "(none)"
	}
	return value
}

func main() {
	program := tea.NewProgram(initialModel())
	if _, err := program.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
