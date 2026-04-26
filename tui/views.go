package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

func (m model) View() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render("AgentMachine TUI"))
	b.WriteString("\n")
	b.WriteString(hintStyle.Render(m.statusLine()))
	b.WriteString("\n\n")

	if m.modelPickerOpen {
		b.WriteString(m.modelPickerView())
		b.WriteString("\n\n")
		b.WriteString(hintStyle.Render("Model picker is active. Enter selects; Esc closes."))
		return b.String()
	}

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
	if m.skillsEnabled() {
		parts = append(parts, "skills="+m.skillsModeLabel())
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
		"mode: planner-managed agentic",
		"provider: " + providerValue,
		"model: " + emptyAsNone(m.modelID()),
		"key: " + keyStatus(m.apiKey()),
		m.toolsStatus(),
		m.skillsStatus(),
		"config: " + m.configPath,
		"run timeout ms: " + defaultRunTimeoutMS,
		"HTTP timeout ms: " + defaultHTTPTimeoutMS,
		"",
		"Commands",
		"/provider echo|openai|openrouter",
		"/key <api-key>",
		"/tools local-files <root> <timeout-ms> <max-rounds> <approval-mode>",
		"/tools code-edit <root> <timeout-ms> <max-rounds> <approval-mode>",
		"/tools off",
		"/skills auto <skills-dir>",
		"/skills dir <skills-dir>",
		"/skills add <name>",
		"/skills list",
		"/skills show <name>",
		"/skills install <name>",
		"/skills off",
		"/test-command add <command>",
		"/test-command list",
		"/test-command clear",
		"/allow-tools [auto-approved-safe|full-access]",
		"/yolo-tools",
		"/deny-tools",
		"/models reload",
		"/model",
		"/back",
	}, "\n")
}

func (m model) modelPickerView() string {
	if len(m.modelOptions) == 0 {
		return ""
	}

	indexes := m.filteredModelIndexes()
	selectedPosition := selectedModelPickerPosition(indexes, m.modelPickerIndex)
	start, end := modelPickerWindow(len(indexes), selectedPosition, 12)
	lines := []string{
		labelStyle.Render("Select model for " + m.provider.Label()),
		"",
		"Search: " + emptyAs(m.modelPickerQuery, "(type to filter)"),
		"Use Up / Down, Enter to select, Esc to cancel, Backspace to edit",
		"",
	}

	if len(indexes) == 0 {
		lines = append(lines, "No models match "+m.modelPickerQuery)
		return lipgloss.NewStyle().
			Border(lipgloss.NormalBorder()).
			BorderForeground(lipgloss.Color("240")).
			Padding(1, 2).
			Render(strings.Join(lines, "\n"))
	}

	for position := start; position < end; position++ {
		index := indexes[position]
		prefix := "  "
		if index == m.modelPickerIndex {
			prefix = "> "
		}
		option := m.modelOptions[index]
		lines = append(lines, fmt.Sprintf("%s%s (%s/$M in, %s/$M out)", prefix, option.ID, formatPrice(option.Pricing.InputPerMillion), formatPrice(option.Pricing.OutputPerMillion)))
	}
	if len(indexes) > end-start {
		lines = append(lines, "", fmt.Sprintf("showing %d-%d of %d", start+1, end, len(indexes)))
	}
	if m.modelPickerQuery != "" {
		lines = append(lines, fmt.Sprintf("filtered from %d total models", len(m.modelOptions)))
	}

	return lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(lipgloss.Color("240")).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func modelPickerWindow(total int, selected int, size int) (int, int) {
	if total <= size {
		return 0, total
	}
	if selected < 0 {
		selected = 0
	}
	if selected >= total {
		selected = total - 1
	}

	start := selected - size/2
	if start < 0 {
		start = 0
	}
	end := start + size
	if end > total {
		end = total
		start = total - size
	}
	return start, end
}

func selectedModelPickerPosition(indexes []int, selected int) int {
	for position, index := range indexes {
		if index == selected {
			return position
		}
	}
	return 0
}

func (m model) agentsView() string {
	if len(m.agentOrder) == 0 {
		return "No agents yet. Send a message after setup."
	}

	lines := []string{labelStyle.Render("Agents")}
	if len(m.lastSummary.Skills) > 0 {
		lines = append(lines, "Skills: "+skillSummaryLine(m.lastSummary.Skills), "")
	}
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

func skillSummaryLine(skills []skillSummary) string {
	names := make([]string, 0, len(skills))
	for _, skill := range skills {
		if strings.TrimSpace(skill.Name) != "" {
			names = append(names, skill.Name)
		}
	}
	if len(names) == 0 {
		return "(none)"
	}
	return strings.Join(names, ", ")
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
		labelStyle.Render("Decision"),
		decisionText(agent.Decision),
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

func decisionText(decision plannerDecision) string {
	if strings.TrimSpace(decision.Mode) == "" && strings.TrimSpace(decision.Reason) == "" {
		return "(none)"
	}
	parts := []string{"mode: " + emptyAsNone(decision.Mode)}
	if strings.TrimSpace(decision.Reason) != "" {
		parts = append(parts, "reason: "+decision.Reason)
	}
	if len(decision.DelegatedAgentIDs) > 0 {
		parts = append(parts, "delegated: "+strings.Join(decision.DelegatedAgentIDs, ", "))
	}
	return strings.Join(parts, "\n")
}

func agentEventLines(events []eventSummary) string {
	if len(events) == 0 {
		return "(none)"
	}
	lines := make([]string, 0, len(events))
	for _, event := range events {
		label := event.Type
		if event.ToolCallID != "" {
			label += " " + event.ToolCallID
		}
		if event.Tool != "" {
			label += " " + event.Tool
		}
		if event.Round > 0 {
			label += fmt.Sprintf(" round=%d", event.Round)
		}
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
		"Up / Down: command history / model picker / agent selection in Agents",
		"Ctrl+A / Ctrl+E / Ctrl+U / Ctrl+K / Ctrl+W: edit input",
		"Ctrl+C: quit",
		"",
		"Commands:",
		"/setup",
		"/provider echo|openai|openrouter",
		"/key <api-key>",
		"/tools local-files <root> <timeout-ms> <max-rounds> <approval-mode>",
		"/tools code-edit <root> <timeout-ms> <max-rounds> <approval-mode>",
		"/tools off",
		"/skills auto <skills-dir>",
		"/skills add <name>",
		"/skills list|show <name>|install <name>|off",
		"/test-command add <command>",
		"/test-command list",
		"/test-command clear",
		"/models reload",
		"/models",
		"/model [<id>|next|prev] (use /model to open picker)",
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
