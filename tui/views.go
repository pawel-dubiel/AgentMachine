package main

import (
	"fmt"
	"strings"
)

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
	if !m.workflowSet {
		parts = append(parts, "workflow=missing")
	} else {
		parts = append(parts, "workflow="+string(m.workflow))
	}
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
	workflowValue := "(missing)"
	if m.workflowSet {
		workflowValue = string(m.workflow)
	}
	providerValue := "(missing)"
	if m.providerSet {
		providerValue = string(m.provider)
	}

	return strings.Join([]string{
		labelStyle.Render("Setup"),
		"workflow: " + workflowValue,
		"provider: " + providerValue,
		"model: " + emptyAsNone(m.modelID()),
		"key: " + keyStatus(m.apiKey()),
		"config: " + m.configPath,
		"run timeout ms: " + defaultRunTimeoutMS,
		"HTTP timeout ms: " + defaultHTTPTimeoutMS,
		"",
		"Commands",
		"/workflow basic|agentic",
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
		"Up / Down: command history, or agent selection in Agents",
		"Ctrl+A / Ctrl+E / Ctrl+U / Ctrl+K / Ctrl+W: edit input",
		"Ctrl+C: quit",
		"",
		"Commands:",
		"/setup",
		"/workflow basic|agentic",
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
