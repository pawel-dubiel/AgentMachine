package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var streamFrames = []string{"|", "/", "-", "\\"}

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
	b.WriteString("> ")
	b.WriteString(m.input.View())
	b.WriteString("\n")
	if m.running {
		b.WriteString(hintStyle.Render("Running. Enter queues message. /queue edits queue. Tab navigates."))
	} else {
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
	if route := workflowRouteStatus(m.lastSummary.WorkflowRoute); route != "" {
		parts = append(parts, route)
	}
	if len(m.queuedMessages) > 0 {
		parts = append(parts, fmt.Sprintf("queue=%d", len(m.queuedMessages)))
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
	if len(m.messages) == 0 && len(m.queuedMessages) == 0 {
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
	if m.running {
		if strings.TrimSpace(m.liveAssistant) != "" {
			b.WriteString(labelStyle.Render("assistant"))
			b.WriteString(": ")
			b.WriteString(m.liveAssistant)
			b.WriteString("\n\n")
		}
		b.WriteString(m.liveActivityView())
		b.WriteString("\n")
	}
	if len(m.queuedMessages) > 0 {
		if b.Len() > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString(m.queueView())
	}
	return strings.TrimRight(b.String(), "\n")
}

func (m model) queueView() string {
	lines := []string{labelStyle.Render("Queued")}
	for index, item := range m.queuedMessages {
		lines = append(lines, fmt.Sprintf("%d. %s", index+1, compactQueueText(item.Text)))
	}
	return strings.Join(lines, "\n")
}

func (m model) liveActivityView() string {
	if len(m.eventLog) == 0 {
		return hintStyle.Render(liveActivityHeader(m) + "\nwaiting for events...")
	}

	start := m.eventScroll
	if start < 0 {
		start = 0
	}
	if start > maxEventScroll(len(m.eventLog), liveEventWindowSize) {
		start = maxEventScroll(len(m.eventLog), liveEventWindowSize)
	}
	end := start + liveEventWindowSize
	if end > len(m.eventLog) {
		end = len(m.eventLog)
	}

	lines := []string{liveActivityHeader(m)}
	for _, event := range m.eventLog[start:end] {
		lines = append(lines, eventDisplayLine(event))
	}
	if len(m.eventLog) > liveEventWindowSize {
		lines = append(lines, hintStyle.Render(fmt.Sprintf("showing %d-%d of %d; Up/Down scroll, End follows", start+1, end, len(m.eventLog))))
	}
	return strings.Join(lines, "\n")
}

func liveActivityHeader(m model) string {
	frame := streamFrames[m.streamFrame%len(streamFrames)]
	if !m.running {
		frame = " "
	}
	return labelStyle.Render(frame + " Live events")
}

func recentEventLine(event eventSummary) string {
	return eventDisplayLine(event)
}

func eventDisplayLine(event eventSummary) string {
	text := event.Summary
	if strings.TrimSpace(text) == "" {
		text = event.Type
	}
	if event.AgentID != "" && !strings.Contains(text, event.AgentID) {
		text = event.AgentID + ": " + text
	}
	extras := eventDetailText(event)
	if extras != "" {
		text += "  " + hintStyle.Render(extras)
	}
	return text
}

func eventDetailText(event eventSummary) string {
	parts := make([]string, 0, 6)
	if event.Tool != "" {
		parts = append(parts, "tool="+event.Tool)
	}
	if event.ToolCallID != "" {
		parts = append(parts, "call="+event.ToolCallID)
	}
	if event.Status != "" {
		parts = append(parts, "status="+event.Status)
	}
	if event.Round > 0 {
		parts = append(parts, fmt.Sprintf("round=%d", event.Round))
	}
	if event.Attempt > 0 {
		parts = append(parts, fmt.Sprintf("attempt=%d", event.Attempt))
	}
	if event.DurationMS != nil {
		parts = append(parts, fmt.Sprintf("duration=%dms", *event.DurationMS))
	}
	if event.Reason != "" && !strings.Contains(event.Summary, event.Reason) {
		parts = append(parts, "reason="+event.Reason)
	}
	parts = append(parts, compactDetails(event.Details)...)
	return strings.Join(parts, " ")
}

func compactDetails(details map[string]any) []string {
	if len(details) == 0 {
		return nil
	}
	keys := make([]string, 0, len(details))
	for key := range details {
		switch key {
		case "agent_id", "attempt", "duration_ms", "reason", "round", "tool":
			continue
		default:
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	limit := len(keys)
	if limit > 3 {
		limit = 3
	}
	parts := make([]string, 0, limit)
	for _, key := range keys[:limit] {
		parts = append(parts, key+"="+compactDetailValue(details[key]))
	}
	return parts
}

func compactDetailValue(value any) string {
	text := fmt.Sprintf("%v", value)
	text = strings.Join(strings.Fields(text), " ")
	if len(text) > 48 {
		return text[:48] + "..."
	}
	return text
}

func (m model) setupView() string {
	providerValue := "(missing)"
	if m.providerSet {
		providerValue = string(m.provider)
	}

	return strings.Join([]string{
		labelStyle.Render("Setup"),
		"mode: progressive auto",
		"provider: " + providerValue,
		"model: " + emptyAsNone(m.modelID()),
		"key: " + keyStatus(m.apiKey()),
		m.routerStatus(),
		m.toolsStatus(),
		m.skillsStatus(),
		"session log: " + emptyAsNone(m.eventLogFile),
		"config: " + m.configPath,
		"run timeout ms: " + defaultRunTimeoutMS,
		"agentic/auto timeout ms: " + defaultAgenticRunTimeoutMS,
		"HTTP timeout ms: " + defaultHTTPTimeoutMS,
		"",
		"Commands",
		"/provider echo|openai|openrouter",
		"/key <api-key>",
		"/router deterministic",
		"/router local <model-dir>",
		"/router-timeout <ms>",
		"/router-confidence <float>",
		"/router-status",
		"/tools time <timeout-ms> <max-rounds> <approval-mode>",
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

func workflowRouteStatus(route workflowRoute) string {
	if strings.TrimSpace(route.Requested) == "" && strings.TrimSpace(route.Selected) == "" {
		return ""
	}
	return "route=" + emptyAsNone(route.Requested) + "->" + emptyAsNone(route.Selected)
}

func workflowRouteLine(route workflowRoute) string {
	if strings.TrimSpace(route.Requested) == "" && strings.TrimSpace(route.Selected) == "" {
		return ""
	}
	parts := []string{
		"requested=" + emptyAsNone(route.Requested),
		"selected=" + emptyAsNone(route.Selected),
		"intent=" + emptyAsNone(route.ToolIntent),
		fmt.Sprintf("tools=%v", route.ToolsExposed),
	}
	if strings.TrimSpace(route.Classifier) != "" {
		parts = append(parts, "classifier="+route.Classifier)
	}
	if strings.TrimSpace(route.ClassifiedIntent) != "" {
		parts = append(parts, "classified="+route.ClassifiedIntent)
	}
	if route.Confidence != nil {
		parts = append(parts, fmt.Sprintf("confidence=%.3f", *route.Confidence))
	}
	if strings.TrimSpace(route.Reason) != "" {
		parts = append(parts, "reason="+route.Reason)
	}
	return "Workflow route: " + strings.Join(parts, " ")
}

func (m model) agentsView() string {
	if len(m.agentOrder) == 0 {
		return "No agents yet. Send a message after setup."
	}

	lines := []string{labelStyle.Render("Agents")}
	if len(m.eventLog) > 0 {
		lines = append(lines, liveActivityHeader(m), recentEventLine(m.eventLog[len(m.eventLog)-1]), "")
	}
	if route := workflowRouteLine(m.lastSummary.WorkflowRoute); route != "" {
		lines = append(lines, route, "")
	}
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
		lines = append(lines, eventDisplayLine(event))
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
		"/router deterministic|local <model-dir>",
		"/router-timeout <ms>",
		"/router-confidence <float>",
		"/router-status",
		"/tools time <timeout-ms> <max-rounds> <approval-mode>",
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
		"/queue [list]|edit <index> <message>|remove <index>|clear|run <index>",
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
