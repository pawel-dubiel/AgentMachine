package main

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

var streamFrames = []string{"|", "/", "-", "\\"}

const matrixSignalFrameHold = 10

var matrixWorkSignals = []string{
	"operator link open",
	"construct loading",
	"trace program running",
	"green rain active",
	"exit line ready",
	"signal lock acquired",
}
var matrixSignalGradient = []string{"22", "28", "34", "40", "46", "40", "34", "28"}

func (m model) View() string {
	styles := m.styles()
	var b strings.Builder
	b.WriteString(styles.Title.Render("AgentMachine TUI"))
	b.WriteString("\n")
	b.WriteString(styles.Hint.Render(wrapText(m.statusLine(), m.viewWidth())))
	b.WriteString("\n\n")

	if m.providerPickerOpen {
		b.WriteString(m.providerPickerView())
		b.WriteString("\n\n")
		b.WriteString(styles.Hint.Render("Provider picker is active. Enter selects; Esc closes."))
		return b.String()
	}

	if m.modelPickerOpen {
		b.WriteString(m.modelPickerView())
		b.WriteString("\n\n")
		b.WriteString(styles.Hint.Render("Model picker is active. Enter selects; Esc closes."))
		return b.String()
	}

	if m.skillPickerOpen {
		b.WriteString(m.skillPickerView())
		b.WriteString("\n\n")
		b.WriteString(styles.Hint.Render("Skill picker is active. Enter selects; Esc closes."))
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
	if _, ok := m.currentPendingPlannerReview(); ok && m.view == viewChat && strings.TrimSpace(m.input.Value()) == "" {
		b.WriteString(styles.Hint.Render(wrapText(m.inputStatusLine("Planner review pending. Up/Down selects. Enter accepts. a=approve, d=decline. Type feedback to revise."), m.viewWidth())))
	} else if _, ok := m.currentPendingPermission(); ok && m.view == viewChat && strings.TrimSpace(m.input.Value()) == "" {
		b.WriteString(styles.Hint.Render(wrapText(m.inputStatusLine("Runtime permission pending. Up/Down selects. Enter accepts. a=approve, d=deny."), m.viewWidth())))
	} else if m.running {
		b.WriteString(styles.Hint.Render(wrapText(m.inputStatusLine("Running. Enter queues message. /queue edits queue. Tab navigates."), m.viewWidth())))
	} else if m.pendingToolTask != "" && m.view == viewChat && strings.TrimSpace(m.input.Value()) == "" {
		b.WriteString(styles.Hint.Render(wrapText(m.inputStatusLine("Tool permission pending. Up/Down selects. Enter accepts. Type a command to override."), m.viewWidth())))
	} else {
		b.WriteString(styles.Hint.Render(wrapText(m.inputStatusLine("Type a message or /help. Tab changes view. Esc goes back."), m.viewWidth())))
	}
	return b.String()
}

func (m model) statusLine() string {
	parts := []string{"view=" + m.viewName()}
	parts = append(parts, "theme="+string(m.activeTheme()))
	parts = append(parts, m.sessionRuntimeStatusParts()...)
	if !m.providerSet {
		parts = append(parts, "provider=missing")
		return strings.Join(parts, " | ")
	}
	parts = append(parts, "provider="+string(m.provider))
	if m.provider != providerEcho {
		parts = append(parts, "model="+emptyAsNone(m.selectedModel))
		parts = append(parts, "setup="+m.providerSetupStatus())
	}
	if m.running {
		parts = append(parts, "run=running")
	}
	if route := executionStrategyStatus(m.lastSummary.ExecutionStrategy, m.lastSummary.WorkflowRoute); route != "" {
		parts = append(parts, route)
	}
	if len(m.queuedMessages) > 0 {
		parts = append(parts, fmt.Sprintf("queue=%d", len(m.queuedMessages)))
	}
	if m.skillsEnabled() {
		parts = append(parts, "skills="+m.skillsModeLabel())
	}
	if budget := contextBudgetStatus(m.latestContextBudget); budget != "" {
		parts = append(parts, budget)
	} else if strings.TrimSpace(m.contextWindowForModel(m.modelID())) != "" || strings.TrimSpace(m.savedConfig.RunContextCompact) == "on" {
		parts = append(parts, "context=configured")
	}
	if m.modelStatus != "" {
		parts = append(parts, "models="+m.modelStatus)
	}
	if m.skillStatus != "" {
		parts = append(parts, "skill-list="+m.skillStatus)
	}
	return strings.Join(parts, " | ")
}

func (m model) inputStatusLine(prompt string) string {
	parts := []string{prompt}
	parts = append(parts, m.sessionRuntimeStatusParts()...)
	return strings.Join(parts, " | ")
}

func (m model) sessionRuntimeStatusParts() []string {
	return []string{
		"session_tokens=" + formatTokenCount(m.sessionUsage.TotalTokens),
		"cwd=" + compactWorkingDirStatus(m.workingDir),
		"branch=" + emptyAs(m.gitBranchStatus, "unknown"),
	}
}

func contextBudgetStatus(event *eventSummary) string {
	if event == nil {
		return ""
	}
	if event.Status == "unknown" {
		return "ctx=unknown " + emptyAs(event.Reason, "unknown_context_budget")
	}
	if event.UsedPercent == nil || event.ContextWindow <= 0 {
		return ""
	}
	prefix := "ctx="
	if event.Status == "warning" {
		prefix = "ctx=warning "
	}
	parts := []string{
		prefix + fmt.Sprintf("%.1f%%", *event.UsedPercent),
		fmt.Sprintf("%d/%d", event.UsedTokens, event.ContextWindow),
	}
	if event.AvailableTokens != nil {
		parts = append(parts, fmt.Sprintf("avail=%d", *event.AvailableTokens))
	} else {
		parts = append(parts, "avail=unknown")
	}
	return strings.Join(parts, " ")
}

func (m model) chatView() string {
	if len(m.messages) == 0 && len(m.queuedMessages) == 0 && len(m.progressComments) == 0 {
		return m.styles().Hint.Render("No messages yet.")
	}

	start := len(m.messages) - 14
	if start < 0 {
		start = 0
	}

	var b strings.Builder
	for _, message := range m.messages[start:] {
		b.WriteString(m.renderChatMessage(message))
		b.WriteString("\n\n")
	}
	if m.running {
		b.WriteString(m.thinkingView())
		b.WriteString("\n\n")
		if progress := m.progressCommentaryView(); progress != "" {
			b.WriteString(progress)
			b.WriteString("\n\n")
		}
		if checklist := m.workChecklistView(); checklist != "" {
			b.WriteString(checklist)
			b.WriteString("\n\n")
		}
		if review := m.pendingPlannerReviewView(); review != "" {
			b.WriteString(review)
			b.WriteString("\n\n")
		} else if permission := m.pendingRuntimePermissionView(); permission != "" {
			b.WriteString(permission)
			b.WriteString("\n\n")
		}
		b.WriteString(m.liveActivityView())
		b.WriteString("\n")
	} else if progress := m.progressCommentaryView(); progress != "" {
		b.WriteString(progress)
		b.WriteString("\n\n")
	}
	if m.pendingToolTask != "" && !m.running {
		if b.Len() > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString(m.pendingToolPermissionView())
	}
	if len(m.queuedMessages) > 0 {
		if b.Len() > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString(m.queueView())
	}
	return strings.TrimRight(b.String(), "\n")
}

func (m model) renderChatMessage(message chatMessage) string {
	prefix := message.Role + ": "
	width := m.viewWidth() - len([]rune(prefix))
	if width < 20 {
		width = 20
	}

	rendered := m.renderChatMessageText(message, width)
	lines := strings.Split(rendered, "\n")
	indent := strings.Repeat(" ", len([]rune(prefix)))
	renderText := func(text string) string {
		if message.Role == "assistant" && strings.HasPrefix(message.Text, "Run failed:") {
			return m.styles().Error.Render(text)
		}
		return text
	}

	var b strings.Builder
	b.WriteString(m.styles().Label.Render(message.Role))
	b.WriteString(": ")
	if len(lines) > 0 {
		b.WriteString(renderText(lines[0]))
	}
	for _, line := range lines[1:] {
		b.WriteString("\n")
		b.WriteString(indent)
		b.WriteString(renderText(line))
	}
	return b.String()
}

func (m model) renderChatMessageText(message chatMessage, width int) string {
	if chatMessageUsesMarkdown(message) {
		return renderMarkdownDisplayWithTheme(message.Text, width, m.activeTheme())
	}
	return wrapText(message.Text, width)
}

func chatMessageUsesMarkdown(message chatMessage) bool {
	if message.Role != "assistant" && message.Role != "summary" {
		return false
	}
	if message.Role == "assistant" && strings.HasPrefix(message.Text, "Run failed:") {
		return false
	}
	return true
}

func (m model) viewWidth() int {
	if m.width > 0 {
		return m.width
	}
	return 100
}

func wrapText(text string, width int) string {
	if width <= 0 {
		return text
	}

	lines := strings.Split(text, "\n")
	wrapped := make([]string, 0, len(lines))
	for _, line := range lines {
		wrapped = append(wrapped, wrapLine(line, width)...)
	}
	return strings.Join(wrapped, "\n")
}

func wrapLine(line string, width int) []string {
	if line == "" {
		return []string{""}
	}

	words := strings.Fields(line)
	if len(words) == 0 {
		return []string{""}
	}

	lines := make([]string, 0, len(words))
	current := ""
	for _, word := range words {
		for runeLen(word) > width {
			head, tail := splitRunes(word, width)
			if current != "" {
				lines = append(lines, current)
				current = ""
			}
			lines = append(lines, head)
			word = tail
		}

		if current == "" {
			current = word
			continue
		}

		if runeLen(current)+1+runeLen(word) <= width {
			current += " " + word
		} else {
			lines = append(lines, current)
			current = word
		}
	}

	if current != "" {
		lines = append(lines, current)
	}
	return lines
}

func runeLen(text string) int {
	return len([]rune(text))
}

func splitRunes(text string, width int) (string, string) {
	runes := []rune(text)
	return string(runes[:width]), string(runes[width:])
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func (m model) pendingToolPermissionView() string {
	styles := m.styles()
	root := emptyAsNone(m.pendingToolRoot)
	harness := emptyAs(m.pendingToolHarness, "local-files")
	lines := []string{
		styles.Label.Render("Tool Permission"),
		"harness: " + harness,
		"root: " + root,
		"task: " + compactQueueText(m.pendingToolTask),
		"",
	}

	options := m.pendingToolOptions()
	selected := m.pendingToolChoice
	if selected < 0 || selected >= len(options) {
		selected = 0
	}

	for index, option := range options {
		prefix := "  "
		if index == selected {
			prefix = "> "
		}
		lines = append(lines, prefix+option.Label+" - "+option.Description)
	}

	lines = append(lines, "", "Up/Down choose. Enter accepts. a=allow, y=full access, d/Esc=deny.")

	return lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(styles.Border).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func (m model) pendingPlannerReviewView() string {
	request, ok := m.currentPendingPlannerReview()
	if !ok {
		return ""
	}

	styles := m.styles()
	lines := []string{
		styles.Label.Render("Planner Review"),
		"planner: " + emptyAsNone(firstNonEmpty(request.PlannerID, request.AgentID)),
		"request: " + emptyAsNone(request.RequestID),
		"reason: " + emptyAsNone(request.Reason),
		fmt.Sprintf("revisions: %d/%d", request.RevisionCount, request.MaxRevisions),
	}
	if request.Summary != "" {
		lines = append(lines, "summary: "+request.Summary)
	}
	if len(request.ProposedAgents) > 0 {
		lines = append(lines, "", "workers:")
		for _, agent := range request.ProposedAgents {
			line := "  - " + agent.ID
			if len(agent.DependsOn) > 0 {
				line += " depends_on=" + strings.Join(agent.DependsOn, ",")
			}
			if strings.TrimSpace(agent.Input) != "" {
				line += ": " + compactQueueText(agent.Input)
			}
			lines = append(lines, line)
		}
	} else if len(request.DelegatedAgentIDs) > 0 {
		lines = append(lines, "", "workers: "+strings.Join(request.DelegatedAgentIDs, ", "))
	}
	lines = append(lines, "")

	options := pendingPlannerReviewOptions()
	selected := m.pendingPlannerReviewChoice
	if selected < 0 || selected >= len(options) {
		selected = 0
	}

	for index, option := range options {
		prefix := "  "
		if index == selected {
			prefix = "> "
		}
		lines = append(lines, prefix+option.Label+" - "+option.Description)
	}

	lines = append(lines, "", "Up/Down choose. Enter accepts. a=approve, d/Esc=decline. Type feedback to request revision.")

	return lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(styles.Border).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func (m model) pendingRuntimePermissionView() string {
	request, ok := m.currentPendingPermission()
	if !ok {
		return ""
	}

	styles := m.styles()
	lines := []string{
		styles.Label.Render("Runtime Permission"),
		"worker: " + emptyAsNone(request.AgentID),
		"kind: " + emptyAsNone(request.Kind),
		"tool: " + emptyAsNone(request.Tool),
		"risk: " + emptyAsNone(request.ApprovalRisk),
	}
	if request.Capability != "" {
		lines = append(lines, "capability: "+request.Capability)
	}
	if request.RequestedRoot != "" {
		lines = append(lines, "root: "+request.RequestedRoot)
	}
	if request.RequestedTool != "" {
		lines = append(lines, "requested tool: "+request.RequestedTool)
	}
	if request.RequestedCommand != "" {
		lines = append(lines, "command: "+compactQueueText(request.RequestedCommand))
	}
	if request.Summary != "" {
		lines = append(lines, "summary: "+request.Summary)
	}
	lines = append(lines, "")

	options := pendingRuntimePermissionOptions()
	selected := m.pendingPermissionChoice
	if selected < 0 || selected >= len(options) {
		selected = 0
	}

	for index, option := range options {
		prefix := "  "
		if index == selected {
			prefix = "> "
		}
		lines = append(lines, prefix+option.Label+" - "+option.Description)
	}

	lines = append(lines, "", "Up/Down choose. Enter accepts. a=approve, d/Esc=deny.")

	return lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(styles.Border).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func (m model) thinkingView() string {
	frame := streamFrames[m.streamFrame%len(streamFrames)]
	styles := m.styles()
	if m.activeTheme() == themeMatrix {
		return styles.Signal.Render(frame+" ") + matrixGradientText(matrixWorkSignal(m.streamFrame), m.streamFrame)
	}
	return styles.Hint.Render("thinking " + frame)
}

func (m model) progressCommentaryView() string {
	if len(m.progressComments) == 0 {
		return ""
	}

	start := len(m.progressComments) - 4
	if start < 0 {
		start = 0
	}

	width := m.viewWidth()
	if width < 20 {
		width = 20
	}

	lines := []string{m.styles().Label.Render("Observer progress")}
	for _, event := range m.progressComments[start:] {
		text := strings.TrimSpace(event.Commentary)
		if text == "" {
			text = strings.TrimSpace(event.Summary)
		}
		if text == "" {
			continue
		}
		lines = append(lines, wrapText(text, width))
	}
	if len(lines) == 1 {
		return ""
	}
	return strings.Join(lines, "\n")
}

func matrixWorkSignal(frame int) string {
	if len(matrixWorkSignals) == 0 {
		return ""
	}
	signalFrame := frame / matrixSignalFrameHold
	return matrixWorkSignals[signalFrame%len(matrixWorkSignals)]
}

func matrixGradientText(text string, frame int) string {
	if text == "" || len(matrixSignalGradient) == 0 {
		return text
	}

	var b strings.Builder
	runes := []rune(text)
	for index, char := range runes {
		if char == ' ' {
			b.WriteRune(char)
			continue
		}
		color := matrixGradientColor(index, frame)
		b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color(color)).Render(string(char)))
	}
	return b.String()
}

func matrixGradientColor(index int, frame int) string {
	return matrixSignalGradient[(index+frame)%len(matrixSignalGradient)]
}

func (m model) queueView() string {
	lines := []string{m.styles().Label.Render("Queued")}
	for index, item := range m.queuedMessages {
		lines = append(lines, fmt.Sprintf("%d. %s", index+1, compactQueueText(item.Text)))
	}
	return strings.Join(lines, "\n")
}

func (m model) agentChecklistView() string {
	if len(m.workOrder) > 0 {
		return m.workChecklistView()
	}

	visible := m.visibleAgentIDs()
	if len(visible) == 0 {
		return ""
	}

	lines := []string{m.styles().Label.Render("Agents")}
	for _, id := range visible {
		lines = append(lines, m.agentChecklistLine(m.agents[id]))
	}
	return strings.Join(lines, "\n")
}

func (m model) agentChecklistLine(agent agentState) string {
	depth := m.agentDepth(agent.ID)
	indent := strings.Repeat("  ", depth)
	status := emptyAs(agent.Status, "pending")
	parts := []string{
		indent + agentStatusMarker(status),
		emptyAs(agent.ID, "(unknown)"),
	}
	if strings.TrimSpace(agent.ParentAgentID) != "" {
		parts = append(parts, "parent="+agent.ParentAgentID)
	}
	parts = append(parts, agentDurationText(agent))
	if latest := latestAgentEventText(agent); latest != "" {
		parts = append(parts, latest)
	}
	return strings.Join(parts, " ")
}

func (m model) workChecklistView() string {
	if len(m.workOrder) == 0 {
		return m.agentChecklistViewFallback()
	}

	lines := append([]string{m.styles().Label.Render("Work")}, m.workChecklistRows()...)
	return strings.Join(lines, "\n")
}

func (m model) workChecklistRows() []string {
	lines := make([]string, 0, len(m.workOrder))
	for _, id := range m.workOrder {
		item, ok := m.workItems[id]
		if !ok {
			continue
		}
		lines = append(lines, m.workChecklistLine(item))
	}
	return lines
}

func (m model) agentChecklistViewFallback() string {
	visible := m.visibleAgentIDs()
	if len(visible) == 0 {
		return ""
	}

	lines := []string{m.styles().Label.Render("Work")}
	for _, id := range visible {
		lines = append(lines, m.agentChecklistLine(m.agents[id]))
	}
	return strings.Join(lines, "\n")
}

func (m model) workChecklistLine(item workItem) string {
	depth := m.workDepth(item.ID)
	indent := strings.Repeat("  ", depth)
	status := emptyAs(item.Status, "pending")
	parts := []string{
		indent + agentStatusMarker(status),
		emptyAs(item.Label, item.ID),
	}
	if strings.TrimSpace(item.ParentID) != "" && depth == 0 {
		parts = append(parts, "parent="+strings.TrimPrefix(item.ParentID, "agent:"))
	}
	if duration := workDurationText(item); duration != "" {
		parts = append(parts, duration)
	}
	if strings.TrimSpace(item.LatestSummary) != "" && item.LatestSummary != item.Label {
		parts = append(parts, item.LatestSummary)
	}
	return strings.Join(parts, " ")
}

func (m model) workDepth(id string) int {
	depth := 0
	seen := map[string]bool{}
	current := id
	for {
		if seen[current] {
			return depth
		}
		seen[current] = true
		item, ok := m.workItems[current]
		if !ok || item.ParentID == "" {
			return depth
		}
		depth++
		current = item.ParentID
	}
}

func workDurationText(item workItem) string {
	if item.DurationMS != nil {
		return fmt.Sprintf("duration=%dms", *item.DurationMS)
	}
	if strings.TrimSpace(item.StartedAt) == "" || item.Status != "running" {
		return ""
	}
	startedAt, err := time.Parse(time.RFC3339Nano, item.StartedAt)
	if err != nil {
		return "elapsed=?"
	}
	duration := time.Since(startedAt)
	if duration < 0 {
		duration = 0
	}
	return fmt.Sprintf("elapsed=%ds", int(duration.Seconds()))
}

func agentStatusMarker(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "pending", "scheduled", "running", "retrying":
		return "[-]"
	case "ok", "done", "completed":
		return "[v]"
	case "error", "failed", "timeout":
		return "[x]"
	default:
		return "[ ]"
	}
}

func agentDurationText(agent agentState) string {
	if agent.DurationMS != nil {
		return fmt.Sprintf("duration=%dms", *agent.DurationMS)
	}
	if strings.TrimSpace(agent.StartedAt) == "" {
		return "elapsed=0s"
	}
	startedAt, err := time.Parse(time.RFC3339Nano, agent.StartedAt)
	if err != nil {
		return "elapsed=?"
	}
	if strings.TrimSpace(agent.FinishedAt) != "" {
		finishedAt, err := time.Parse(time.RFC3339Nano, agent.FinishedAt)
		if err == nil {
			return fmt.Sprintf("duration=%s", compactDuration(finishedAt.Sub(startedAt)))
		}
	}
	return fmt.Sprintf("elapsed=%s", compactDuration(time.Since(startedAt)))
}

func latestAgentEventText(agent agentState) string {
	if len(agent.Events) == 0 {
		return ""
	}
	event := agent.Events[len(agent.Events)-1]
	text := event.Summary
	if strings.TrimSpace(text) == "" {
		text = event.Type
	}
	return compactQueueText(text)
}

func compactDuration(duration time.Duration) string {
	if duration < 0 {
		duration = 0
	}
	if duration < time.Second {
		return fmt.Sprintf("%dms", duration.Milliseconds())
	}
	return fmt.Sprintf("%ds", int(duration.Seconds()))
}

func (m model) liveActivityView() string {
	styles := m.styles()
	if len(m.eventLog) == 0 {
		return styles.Hint.Render(liveActivityHeader(m) + "\nwaiting for events...")
	}

	lines := []string{liveActivityHeader(m)}
	lines = append(lines, eventDisplayLineWithTheme(m.eventLog[len(m.eventLog)-1], m.activeTheme()))
	return strings.Join(lines, "\n")
}

func liveActivityHeader(m model) string {
	frame := streamFrames[m.streamFrame%len(streamFrames)]
	if !m.running {
		frame = " "
	}
	return m.styles().Label.Render(frame + " Live events")
}

func recentEventLine(event eventSummary) string {
	return eventDisplayLine(event)
}

func compactEventDisplayLines(events []eventSummary) []string {
	return compactEventDisplayLinesWithTheme(events, themeClassic)
}

func compactEventDisplayLinesWithTheme(events []eventSummary, theme tuiTheme) []string {
	lines := make([]string, 0, len(events))
	var heartbeat eventSummary
	heartbeatCount := 0
	var groupedStream eventSummary
	groupedStreamCount := 0
	var groupedRead eventSummary
	groupedReadCount := 0

	flushHeartbeat := func() {
		if heartbeatCount == 0 {
			return
		}
		line := eventDisplayLineWithTheme(heartbeat, theme)
		if heartbeatCount > 1 {
			line += hintTextForTheme(theme, fmt.Sprintf(" x%d", heartbeatCount))
		}
		lines = append(lines, line)
		heartbeat = eventSummary{}
		heartbeatCount = 0
	}

	flushGroupedStream := func() {
		if groupedStreamCount == 0 {
			return
		}
		line := eventDisplayLineWithTheme(groupedStream, theme)
		if groupedStreamCount > 1 {
			line += hintTextForTheme(theme, fmt.Sprintf(" x%d", groupedStreamCount))
		}
		lines = append(lines, line)
		groupedStream = eventSummary{}
		groupedStreamCount = 0
	}

	flushGroupedRead := func() {
		if groupedReadCount == 0 {
			return
		}
		line := eventDisplayLineWithTheme(groupedRead, theme)
		if groupedReadCount > 1 {
			line += hintTextForTheme(theme, fmt.Sprintf(" x%d", groupedReadCount))
		}
		lines = append(lines, line)
		groupedRead = eventSummary{}
		groupedReadCount = 0
	}

	for index := 0; index < len(events); index++ {
		event := events[index]

		if event.Type == "provider_request_started" && index+1 < len(events) {
			next := events[index+1]
			if next.Type == "provider_request_finished" && next.AgentID == event.AgentID {
				flushHeartbeat()
				flushGroupedStream()
				flushGroupedRead()
				lines = append(lines, eventDisplayLineWithTheme(next, theme))
				index++
				continue
			}
		}

		if event.Type == "agent_heartbeat" {
			flushGroupedStream()
			flushGroupedRead()
			heartbeat = event
			heartbeatCount++
			continue
		}

		if event.Type == "assistant_delta" {
			flushHeartbeat()
			flushGroupedRead()
			if groupedStreamCount > 0 && groupedStream.AgentID == event.AgentID {
				groupedStream = event
				groupedStreamCount++
			} else {
				flushGroupedStream()
				groupedStream = event
				groupedStreamCount = 1
			}
			continue
		}

		if collapsibleReadEvent(event) {
			flushHeartbeat()
			flushGroupedStream()
			if groupedReadCount > 0 && groupedRead.AgentID == event.AgentID && groupedRead.Tool == event.Tool {
				groupedRead = event
				groupedReadCount++
			} else {
				flushGroupedRead()
				groupedRead = event
				groupedReadCount = 1
			}
			continue
		}

		flushHeartbeat()
		flushGroupedStream()
		flushGroupedRead()
		lines = append(lines, eventDisplayLineWithTheme(event, theme))
	}

	flushHeartbeat()
	flushGroupedStream()
	flushGroupedRead()
	return lines
}

func collapsibleReadEvent(event eventSummary) bool {
	if event.Type != "tool_call_finished" || event.Status != "ok" {
		return false
	}
	switch event.Tool {
	case "file_info", "list_files", "read_file", "search_files", "now":
		return true
	default:
		return false
	}
}

func eventDisplayLine(event eventSummary) string {
	return eventDisplayLineWithTheme(event, themeClassic)
}

func eventDisplayLineWithTheme(event eventSummary, theme tuiTheme) string {
	if text := toolEventDisplayLine(event); text != "" {
		return text
	}
	if text := plannerReviewEventDisplayLine(event, theme); text != "" {
		return text
	}
	if text := permissionEventDisplayLine(event, theme); text != "" {
		return text
	}
	if event.Type == "execution_strategy_selected" {
		strategy := firstNonEmpty(event.Strategy, event.Selected)
		text := "strategy selected: " + emptyAsNone(strategy)
		if event.Reason != "" {
			text += "  " + hintTextForTheme(theme, event.Reason)
		}
		return text
	}

	text := event.Summary
	if strings.TrimSpace(text) == "" {
		text = event.Type
	}
	if event.AgentID != "" && !strings.Contains(text, event.AgentID) {
		text = event.AgentID + ": " + text
	}
	extras := eventDetailText(event)
	if extras != "" {
		text += "  " + hintTextForTheme(theme, extras)
	}
	return text
}

func plannerReviewEventDisplayLine(event eventSummary, theme tuiTheme) string {
	switch event.Type {
	case "planner_review_requested":
		planner := firstNonEmpty(event.PlannerID, event.AgentID, "planner")
		text := fmt.Sprintf("planner review requested: %s proposed %d worker(s)", planner, len(event.DelegatedAgentIDs))
		if event.Reason != "" {
			text += "  " + hintTextForTheme(theme, event.Reason)
		}
		return text
	case "planner_review_decided":
		planner := firstNonEmpty(event.PlannerID, event.AgentID, "planner")
		text := fmt.Sprintf("planner review %s: %s", emptyAsNone(event.Decision), planner)
		if event.Reason != "" {
			text += "  " + hintTextForTheme(theme, event.Reason)
		}
		return text
	default:
		return ""
	}
}

func toolEventDisplayLine(event eventSummary) string {
	if event.Type != "tool_call_started" && event.Type != "tool_call_finished" && event.Type != "tool_call_failed" {
		return ""
	}
	if event.Type == "tool_call_failed" {
		return event.Summary
	}
	if event.Type == "tool_call_started" {
		return event.Summary
	}
	if strings.TrimSpace(event.Summary) != "" {
		return event.Summary
	}
	return ""
}

func permissionEventDisplayLine(event eventSummary, theme tuiTheme) string {
	switch event.Type {
	case "permission_requested":
		return permissionLineWithDetails(
			fmt.Sprintf("permission requested: %s wants %s", permissionActor(event), permissionTarget(event)),
			event,
			theme,
		)
	case "permission_decided":
		action := permissionDecisionAction(event.Decision)
		return permissionLineWithDetails(
			fmt.Sprintf("permission %s: %s %s %s", permissionDecisionLabel(event.Decision), permissionActor(event), action, permissionTarget(event)),
			event,
			theme,
		)
	case "permission_cancelled":
		return permissionLineWithDetails(
			fmt.Sprintf("permission cancelled: %s cannot use %s", permissionActor(event), permissionTarget(event)),
			event,
			theme,
		)
	default:
		return ""
	}
}

func permissionLineWithDetails(text string, event eventSummary, theme tuiTheme) string {
	if details := permissionDetailText(event); details != "" {
		text += "  " + hintTextForTheme(theme, details)
	}
	return text
}

func permissionActor(event eventSummary) string {
	if strings.TrimSpace(event.AgentID) != "" {
		return event.AgentID
	}
	return "runtime"
}

func permissionTarget(event eventSummary) string {
	switch {
	case strings.TrimSpace(event.Tool) != "":
		return event.Tool
	case strings.TrimSpace(event.Capability) != "":
		return event.Capability
	case strings.TrimSpace(event.RequestedTool) != "":
		return event.RequestedTool
	case strings.TrimSpace(event.RequestedCommand) != "":
		return event.RequestedCommand
	default:
		return "requested capability"
	}
}

func permissionDecisionLabel(decision string) string {
	switch strings.ToLower(strings.TrimSpace(decision)) {
	case "approved", "approve":
		return "approved"
	case "denied", "deny":
		return "denied"
	default:
		return emptyAs(strings.TrimSpace(decision), "decided")
	}
}

func permissionDecisionAction(decision string) string {
	switch strings.ToLower(strings.TrimSpace(decision)) {
	case "approved", "approve":
		return "may run"
	case "denied", "deny":
		return "cannot run"
	default:
		return "decided on"
	}
}

func permissionDetailText(event eventSummary) string {
	parts := make([]string, 0, 6)
	if event.RequestedRoot != "" {
		parts = append(parts, "root="+event.RequestedRoot)
	}
	if event.RequestedTool != "" {
		parts = append(parts, "requested_tool="+event.RequestedTool)
	}
	if event.RequestedCommand != "" {
		parts = append(parts, "command="+compactDetailValue(event.RequestedCommand))
	}
	if event.ApprovalRisk != "" {
		parts = append(parts, "risk="+event.ApprovalRisk)
	}
	if event.ApprovalMode != "" {
		parts = append(parts, "mode="+event.ApprovalMode)
	}
	if event.Reason != "" {
		parts = append(parts, "reason="+event.Reason)
	}
	return strings.Join(parts, " ")
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
		case "agent_id", "attempt", "duration_ms", "reason", "round", "tool", "input_summary", "result_summary":
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
	styles := m.styles()
	providerValue := "(missing)"
	if m.providerSet {
		providerValue = string(m.provider)
	}

	return strings.Join([]string{
		styles.Label.Render("Setup"),
		"runtime: agentic strategy direct/tool/planned/swarm",
		"theme: " + string(m.activeTheme()),
		"provider: " + providerValue,
		"model: " + emptyAsNone(m.modelID()),
		"provider setup: " + m.providerSetupStatus(),
		m.routerStatus(),
		m.toolsStatus(),
		m.agenticPersistenceStatus(),
		m.contextStatus(),
		m.progressStatus(),
		m.plannerReviewStatus(),
		m.skillsStatus(),
		"session log: " + emptyAsNone(m.eventLogFile),
		"config: " + m.configPath,
		"run idle timeout ms: " + defaultRunTimeoutMS,
		"planned/swarm idle timeout ms: " + defaultAgenticRunTimeoutMS,
		"hard cap: 3x idle timeout",
		"HTTP timeout ms: " + defaultHTTPTimeoutMS,
		"",
		"Commands",
		"/provider [<provider-id>]",
		"/theme classic|matrix",
		"/key <api-key>",
		"/provider-secret <field> <value>",
		"/provider-option <field> <value>",
		"/router deterministic",
		"/router llm",
		"/router local <model-dir>",
		"/router-timeout <ms>",
		"/router-confidence <float>",
		"/router-status",
		"/context status",
		"/context window <tokens> [warning-percent]",
		"/context tokenizer <path>|off",
		"/context reserve <tokens>|off",
		"/context run-compaction on <compact-percent> <max-compactions>",
		"/context run-compaction off",
		"/progress observer on|off",
		"/planner-review on <max-revisions>",
		"/planner-review off",
		"/agentic-persistence <rounds> <max-steps> <timeout-ms>|off",
		"/compact",
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
		"/skills generate <name> <description>",
		"/skills off",
		"/test-command add <command>",
		"/test-command list",
		"/test-command clear",
		"/allow-tools [ask-before-write|auto-approved-safe|full-access]",
		"/yolo-tools",
		"/deny-tools",
		"/models reload",
		"/model",
		"/back",
	}, "\n")
}

func (m model) providerPickerView() string {
	styles := m.styles()
	current := "(missing)"
	if m.providerSet {
		current = fmt.Sprintf("%s (%s)", m.provider.Label(), m.provider)
	}
	lines := []string{
		styles.Label.Render("Select provider"),
		"",
		"Current: " + current,
		"Use Up / Down, Enter to select, Esc to cancel",
		"",
	}

	for index, option := range providers {
		prefix := "  "
		if index == m.providerPickerIndex {
			prefix = "> "
		}
		currentMarker := " "
		if m.providerSet && option == m.provider {
			currentMarker = "*"
		}
		lines = append(lines, fmt.Sprintf("%s[%s] %-16s %s", prefix, currentMarker, option, option.Label()))
	}

	return lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(styles.Border).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func (m model) modelPickerView() string {
	if len(m.modelOptions) == 0 {
		return ""
	}
	styles := m.styles()

	indexes := m.filteredModelIndexes()
	selectedPosition := selectedModelPickerPosition(indexes, m.modelPickerIndex)
	start, end := modelPickerWindow(len(indexes), selectedPosition, 12)
	lines := []string{
		styles.Label.Render("Select model for " + m.provider.Label()),
		"",
		"Search: " + emptyAs(m.modelPickerQuery, "(type to filter)"),
		"Use Up / Down, Enter to select, Esc to cancel, Backspace to edit",
		"",
	}

	if len(indexes) == 0 {
		lines = append(lines, "No models match "+m.modelPickerQuery)
		return lipgloss.NewStyle().
			Border(lipgloss.NormalBorder()).
			BorderForeground(styles.Border).
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
		BorderForeground(styles.Border).
		Padding(1, 2).
		Render(strings.Join(lines, "\n"))
}

func (m model) skillPickerView() string {
	if len(m.skillOptions) == 0 {
		return ""
	}
	styles := m.styles()

	indexes := m.filteredSkillIndexes()
	selectedPosition := selectedModelPickerPosition(indexes, m.skillPickerIndex)
	start, end := modelPickerWindow(len(indexes), selectedPosition, 12)
	lines := []string{
		styles.Label.Render("Installed skills"),
		"",
		"Directory: " + emptyAsNone(m.savedConfig.SkillsDir),
		"Search: " + emptyAs(m.skillPickerQuery, "(type to filter)"),
		"Use Up / Down, Enter to select or unselect, Esc to cancel, Backspace to edit",
		"",
	}

	if len(indexes) == 0 {
		lines = append(lines, "No skills match "+m.skillPickerQuery)
		return lipgloss.NewStyle().
			Border(lipgloss.NormalBorder()).
			BorderForeground(styles.Border).
			Padding(1, 2).
			Render(strings.Join(lines, "\n"))
	}

	for position := start; position < end; position++ {
		index := indexes[position]
		prefix := "  "
		if index == m.skillPickerIndex {
			prefix = "> "
		}
		selected := " "
		if stringSliceContains(m.savedConfig.SkillNames, m.skillOptions[index].Name) {
			selected = "*"
		}
		lines = append(lines, fmt.Sprintf("%s[%s] %s - %s", prefix, selected, m.skillOptions[index].Name, m.skillOptions[index].Description))
	}
	if len(indexes) > end-start {
		lines = append(lines, "", fmt.Sprintf("showing %d-%d of %d", start+1, end, len(indexes)))
	}
	if m.skillPickerQuery != "" {
		lines = append(lines, fmt.Sprintf("filtered from %d installed skills", len(m.skillOptions)))
	}

	return lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(styles.Border).
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

func executionStrategyStatus(strategy workflowRoute, legacy workflowRoute) string {
	if strings.TrimSpace(strategy.Selected) == "" {
		strategy = legacy
	}
	if strings.TrimSpace(strategy.Selected) == "" {
		return ""
	}
	return "strategy=" + emptyAsNone(strategy.Selected)
}

func workflowRouteLine(route workflowRoute) string {
	if strings.TrimSpace(route.Requested) == "" && strings.TrimSpace(route.Selected) == "" {
		return ""
	}
	parts := []string{
		"runtime=" + emptyAsNone(route.Requested),
		"strategy=" + emptyAsNone(route.Selected),
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
	return "Execution strategy: " + strings.Join(parts, " ")
}

func (m model) agentsView() string {
	if len(m.agentOrder) == 0 {
		return "No agents yet. Send a message after setup."
	}

	lines := []string{m.styles().Label.Render("Agents")}
	if len(m.eventLog) > 0 {
		lines = append(lines, m.styles().Label.Render("Latest event"), eventDisplayLineWithTheme(m.eventLog[len(m.eventLog)-1], m.activeTheme()), "")
	}
	route := m.lastSummary.ExecutionStrategy
	if strings.TrimSpace(route.Selected) == "" {
		route = m.lastSummary.WorkflowRoute
	}
	if route := workflowRouteLine(route); route != "" {
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
	if rows := m.workChecklistRows(); len(rows) > 0 {
		lines = append(lines, "", m.styles().Label.Render("Work"))
		lines = append(lines, rows...)
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
	} else if agentRunning(agent) && strings.TrimSpace(agent.StartedAt) != "" {
		duration = strings.TrimPrefix(agentDurationText(agent), "elapsed=")
	}

	return strings.Join([]string{
		m.styles().Label.Render("Agent " + m.selectedAgent),
		"status: " + emptyAsNone(agent.Status),
		fmt.Sprintf("attempt: %d", agent.Attempt),
		"parent: " + emptyAsNone(agent.ParentAgentID),
		"started: " + emptyAsNone(agent.StartedAt),
		"finished: " + emptyAsNone(agent.FinishedAt),
		"duration: " + duration,
		"",
		m.styles().Label.Render("Decision"),
		agentDecisionText(agent),
		"",
		m.styles().Label.Render("Stream"),
		agentStreamText(agent),
		"",
		m.styles().Label.Render("Output"),
		m.renderAgentOutputText(agent),
		"",
		m.styles().Label.Render("Error"),
		agentErrorText(agent),
		"",
		m.styles().Label.Render("Events"),
		m.agentEventLines(agent.Events),
		"",
		"Esc or /back",
	}, "\n")
}

func agentDecisionText(agent agentState) string {
	if strings.TrimSpace(agent.Decision.Mode) == "" && strings.TrimSpace(agent.Decision.Reason) == "" && agentRunning(agent) {
		return "(pending until agent finishes)"
	}
	return decisionText(agent.Decision)
}

func agentStreamText(agent agentState) string {
	if strings.TrimSpace(agent.StreamOutput) != "" {
		return agent.StreamOutput
	}
	if agentRunning(agent) && providerRequestOpen(agent.Events) {
		return "(provider request in progress; no streamed text yet)"
	}
	if agentRunning(agent) {
		return "(waiting for streamed text)"
	}
	return "(none)"
}

func agentOutputText(agent agentState) string {
	if strings.TrimSpace(agent.Output) != "" {
		return agent.Output
	}
	if agentRunning(agent) {
		return "(pending until agent finishes)"
	}
	return "(none)"
}

func (m model) renderAgentOutputText(agent agentState) string {
	if strings.TrimSpace(agent.Output) != "" {
		return renderMarkdownDisplayWithTheme(agent.Output, m.viewWidth(), m.activeTheme())
	}
	return agentOutputText(agent)
}

func agentErrorText(agent agentState) string {
	if strings.TrimSpace(agent.Error) != "" {
		return agent.Error
	}
	if agentRunning(agent) {
		return "(none so far)"
	}
	return "(none)"
}

func agentRunning(agent agentState) bool {
	status := strings.ToLower(strings.TrimSpace(agent.Status))
	return status == "" || status == "running" || status == "retrying"
}

func providerRequestOpen(events []eventSummary) bool {
	started := false
	for _, event := range events {
		switch event.Type {
		case "provider_request_started":
			started = true
		case "provider_request_finished", "provider_request_failed":
			started = false
		}
	}
	return started
}

func (m model) helpView() string {
	return m.helpText()
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
	return strings.Join(compactEventDisplayLines(events), "\n")
}

func (m model) agentEventLines(events []eventSummary) string {
	if len(events) == 0 {
		return "(none)"
	}
	return strings.Join(compactEventDisplayLinesWithTheme(events, m.activeTheme()), "\n")
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
	return helpTextForTheme(themeClassic)
}

func (m model) helpText() string {
	return helpTextForTheme(m.activeTheme())
}

func helpTextForTheme(theme tuiTheme) string {
	return strings.Join([]string{
		stylesForTheme(theme).Label.Render("Help"),
		"Agentic runtime selects direct, tool, planned, or swarm strategy per run.",
		"",
		"Keys:",
		"Tab / Shift+Tab: switch views",
		"Esc: back",
		"Enter: submit or open selected agent",
		"Up / Down: command history / provider/model picker / agent selection in Agents",
		"Ctrl+B / Ctrl+F: scroll chat response by page",
		"Ctrl+P / Ctrl+N: scroll chat response by line",
		"Ctrl+A / Ctrl+E / Ctrl+U / Ctrl+K / Ctrl+W: edit input",
		"Ctrl+C: quit",
		"",
		"Commands:",
		"/setup",
		"/provider [<provider-id>]",
		"/theme classic|matrix",
		"/key <api-key>",
		"/provider-secret <field> <value>",
		"/provider-option <field> <value>",
		"/router deterministic|llm|local <model-dir>",
		"/router-timeout <ms>",
		"/router-confidence <float>",
		"/router-status",
		"/context status|window <tokens> [warning-percent]|window off",
		"/context tokenizer <path>|off",
		"/context reserve <tokens>|off",
		"/context run-compaction on <compact-percent> <max-compactions>|off",
		"/progress observer on|off",
		"/agentic-persistence <rounds> <max-steps> <timeout-ms>|off",
		"/compact",
		"/tools time <timeout-ms> <max-rounds> <approval-mode>",
		"/tools local-files <root> <timeout-ms> <max-rounds> <approval-mode>",
		"/tools code-edit <root> <timeout-ms> <max-rounds> <approval-mode>",
		"/tools off",
		"/skills auto <skills-dir>",
		"/skills add <name>",
		"/skills list|show <name>|install <name>|generate <name> <description>|off",
		"/test-command add <command>",
		"/test-command list",
		"/test-command clear",
		"/mcp add playwright <command> [args...]",
		"/mcp list|status|remove playwright|off",
		"/mcp-config <path> <timeout-ms> <max-rounds> <approval-mode>",
		"/models reload",
		"/models",
		"/model [<id>|next|prev] (use /model to open picker)",
		"/settings",
		"/agents",
		"/agent <id>",
		"/queue [list]|edit <index> <message>|remove <index>|clear|run <index>",
		"/scroll up|down|top|bottom",
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
