package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const defaultPaidOpenRouterModel = "stepfun/step-3.5-flash"
const paidOpenRouterAgenticRunTimeoutMS = "240000"

func TestPaidOpenRouterRunThroughTUIAdapter(t *testing.T) {
	apiKey := paidOpenRouterAPIKey(t)
	paidModel := paidOpenRouterModel(t)

	logFile := filepath.Join(t.TempDir(), "agent-machine-paid-openrouter.jsonl")
	t.Logf("starting paid OpenRouter basic TUI adapter run with model=%s", paidModel)

	summary, raw, err := runPaidAgentMachine(t, runConfig{
		Task:        "Reply with one concise sentence that includes AgentMachine and TUI.",
		Workflow:    workflowBasic,
		Provider:    providerOpenRouter,
		APIKey:      apiKey,
		Model:       paidModel,
		InputPrice:  "0",
		OutputPrice: "0",
		HTTPTimeout: "120000",
		LogFile:     logFile,
	})
	if err != nil {
		t.Fatalf("expected paid OpenRouter TUI adapter run to succeed: %v\nraw output:\n%s", err, raw)
	}
	t.Logf("completed basic TUI adapter run: run_id=%s tokens=%d", summary.RunID, summary.Usage.TotalTokens)

	if summary.Status != "completed" {
		t.Fatalf("expected completed summary, got %#v", summary)
	}
	assertPlannerDecision(t, summary.Results, "delegate")
	if strings.TrimSpace(summary.FinalOutput) == "" {
		t.Fatalf("expected non-empty final output, got %#v", summary)
	}
	if summary.Usage.TotalTokens <= 0 {
		t.Fatalf("expected positive token usage, got %#v", summary.Usage)
	}
	if !hasEvent(summary.Events, "run_completed") {
		t.Fatalf("expected run_completed event, got %#v", summary.Events)
	}

	logContent, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("expected TUI adapter to create run log: %v", err)
	}
	if !strings.Contains(string(logContent), `"type":"summary"`) {
		t.Fatalf("expected run log to include summary, got %s", string(logContent))
	}
}

func TestPaidOpenRouterAgenticRunThroughTUIAdapter(t *testing.T) {
	apiKey := paidOpenRouterAPIKey(t)
	paidModel := paidOpenRouterModel(t)
	t.Logf("starting paid OpenRouter agentic delegation TUI adapter run with model=%s", paidModel)

	summary, raw, err := runPaidAgentMachine(t, runConfig{
		Task:        "Use exactly one delegated worker. The worker should answer with a concise sentence containing AgentMachine worker result. The final answer should mention that worker result.",
		Workflow:    workflowAgentic,
		Provider:    providerOpenRouter,
		APIKey:      apiKey,
		Model:       paidModel,
		InputPrice:  "0",
		OutputPrice: "0",
		HTTPTimeout: "120000",
		RunTimeout:  paidOpenRouterAgenticRunTimeoutMS,
	})
	if err != nil {
		t.Fatalf("expected paid OpenRouter agentic TUI adapter run to succeed: %v\nraw output:\n%s", err, raw)
	}
	t.Logf("completed agentic delegation run: run_id=%s tokens=%d results=%d", summary.RunID, summary.Usage.TotalTokens, len(summary.Results))

	if summary.Status != "completed" {
		t.Fatalf("expected completed summary, got %#v", summary)
	}
	if strings.TrimSpace(summary.FinalOutput) == "" {
		t.Fatalf("expected non-empty final output, got %#v", summary)
	}
	if summary.Usage.TotalTokens <= 0 {
		t.Fatalf("expected positive token usage, got %#v", summary.Usage)
	}
	if !hasEvent(summary.Events, "run_completed") {
		t.Fatalf("expected run_completed event, got %#v", summary.Events)
	}

	workerID, worker := delegatedWorkerResult(summary.Results)
	if workerID == "" {
		t.Fatalf("expected delegated worker result, got %#v", summary.Results)
	}
	if strings.TrimSpace(worker.Output) == "" {
		t.Fatalf("expected delegated worker output, got %s: %#v", workerID, worker)
	}

	display := summaryDisplayText(summary)
	if strings.TrimSpace(display) == "" {
		t.Fatalf("expected non-empty TUI display text for summary %#v", summary)
	}

	m := model{agents: map[string]agentState{}}
	m.applySummaryResults(summary)
	if m.agents[workerID].Output != worker.Output {
		t.Fatalf("expected TUI agent detail state to include worker output, got %#v", m.agents[workerID])
	}
}

func TestPaidOpenRouterAgenticToolsCreateDirectoryAndFileThroughTUIAdapter(t *testing.T) {
	apiKey := paidOpenRouterAPIKey(t)
	paidModel := paidOpenRouterModel(t)
	root := t.TempDir()
	dirName := "paid-agentic-tool-flow"
	fileName := "result.txt"
	expectedContent := "AgentMachine paid agentic tool result"
	targetDir := filepath.Join(root, dirName)
	targetFile := filepath.Join(targetDir, fileName)
	t.Logf("starting paid OpenRouter agentic local-files run with model=%s root=%s", paidModel, root)

	summary, raw, err := runPaidAgentMachine(t, runConfig{
		Task: "Use exactly one delegated worker. The worker must use the available local-files tools to create directory " + dirName +
			" under tool_root, then create " + dirName + "/" + fileName + " with exactly this UTF-8 text: " + expectedContent +
			" Do not only describe the change; use tools and report the confirmed result.",
		Workflow:      workflowAgentic,
		Provider:      providerOpenRouter,
		APIKey:        apiKey,
		Model:         paidModel,
		InputPrice:    "0",
		OutputPrice:   "0",
		HTTPTimeout:   "120000",
		RunTimeout:    paidOpenRouterAgenticRunTimeoutMS,
		ToolHarness:   "local-files",
		ToolRoot:      root,
		ToolTimeout:   "120000",
		ToolMaxRounds: "8",
		ToolApproval:  "auto-approved-safe",
	})
	if err != nil {
		t.Fatalf("expected paid OpenRouter agentic tool TUI adapter run to succeed: %v\nraw output:\n%s", err, raw)
	}
	t.Logf("completed agentic local-files run: run_id=%s tokens=%d results=%d", summary.RunID, summary.Usage.TotalTokens, len(summary.Results))

	if summary.Status != "completed" {
		t.Fatalf("expected completed summary, got %#v", summary)
	}
	assertPlannerDecision(t, summary.Results, "delegate")
	if !hasEvent(summary.Events, "tool_call_finished") {
		t.Fatalf("expected tool_call_finished event, got %#v", summary.Events)
	}
	if !hasEvent(summary.Events, "run_completed") {
		t.Fatalf("expected run_completed event, got %#v", summary.Events)
	}
	if summary.Usage.TotalTokens <= 0 {
		t.Fatalf("expected positive token usage, got %#v", summary.Usage)
	}

	info, err := os.Stat(targetDir)
	if err != nil {
		t.Fatalf("expected delegated worker to create directory %s: %v\nsummary:%#v\nraw:%s", targetDir, err, summary, raw)
	}
	if !info.IsDir() {
		t.Fatalf("expected %s to be a directory", targetDir)
	}

	content, err := os.ReadFile(targetFile)
	if err != nil {
		t.Fatalf("expected delegated worker to create file %s: %v\nsummary:%#v\nraw:%s", targetFile, err, summary, raw)
	}
	if strings.TrimSpace(string(content)) != expectedContent {
		t.Fatalf("unexpected file content %q, expected %q", strings.TrimSpace(string(content)), expectedContent)
	}

	workerID, worker := delegatedWorkerResult(summary.Results)
	if workerID == "" {
		t.Fatalf("expected delegated worker result, got %#v", summary.Results)
	}
	if strings.TrimSpace(worker.Output) == "" {
		t.Fatalf("expected delegated worker output, got %s: %#v", workerID, worker)
	}

	display := summaryDisplayText(summary)
	if strings.TrimSpace(display) == "" {
		t.Fatalf("expected non-empty TUI display text for tool summary %#v", summary)
	}

	m := model{agents: map[string]agentState{}}
	m.applySummaryResults(summary)
	if m.agents[workerID].Output != worker.Output {
		t.Fatalf("expected TUI agent detail state to include tool worker output, got %#v", m.agents[workerID])
	}
}

func TestPaidOpenRouterAgenticCodeEditThroughTUIAdapter(t *testing.T) {
	apiKey := paidOpenRouterAPIKey(t)
	paidModel := paidOpenRouterModel(t)
	root := t.TempDir()
	docsDir := filepath.Join(root, "docs")
	if err := os.MkdirAll(docsDir, 0o700); err != nil {
		t.Fatal(err)
	}

	sourcePath := filepath.Join(root, "app_status.txt")
	docPath := filepath.Join(docsDir, "health_check.md")
	updatedSource := "component: health\nstatus: STATUS_GREEN\n"
	createdDoc := "# Health Check\n\nStatus: STATUS_GREEN\n"
	patch := "diff --git a/app_status.txt b/app_status.txt\n" +
		"--- a/app_status.txt\n" +
		"+++ b/app_status.txt\n" +
		"@@ -1,2 +1,2 @@\n" +
		" component: health\n" +
		"-status: STATUS_PLACEHOLDER\n" +
		"+status: STATUS_GREEN\n" +
		"diff --git a/docs/health_check.md b/docs/health_check.md\n" +
		"new file mode 100644\n" +
		"--- /dev/null\n" +
		"+++ b/docs/health_check.md\n" +
		"@@ -0,0 +1,3 @@\n" +
		"+# Health Check\n" +
		"+\n" +
		"+Status: STATUS_GREEN\n"

	if err := os.WriteFile(sourcePath, []byte("component: health\nstatus: STATUS_PLACEHOLDER\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Logf("starting paid OpenRouter agentic code-edit run with model=%s root=%s", paidModel, root)

	summary, raw, err := runPaidAgentMachine(t, runConfig{
		Task: "Use exactly one delegated worker. The worker must use the available code-edit tools to make these two edits under tool_root: " +
			"1. In app_status.txt replace STATUS_PLACEHOLDER with STATUS_GREEN exactly once. " +
			"2. Create docs/health_check.md with exactly this content: " + createdDoc +
			"Call apply_patch exactly once with the exact patch text below as the patch argument. Do not call apply_edits. Patch:\n" + patch +
			"Do not only describe the change. Report the checkpoint id and confirmed changed files.",
		Workflow:      workflowAgentic,
		Provider:      providerOpenRouter,
		APIKey:        apiKey,
		Model:         paidModel,
		InputPrice:    "0",
		OutputPrice:   "0",
		HTTPTimeout:   "120000",
		RunTimeout:    paidOpenRouterAgenticRunTimeoutMS,
		ToolHarness:   "code-edit",
		ToolRoot:      root,
		ToolTimeout:   "120000",
		ToolMaxRounds: "8",
		ToolApproval:  "auto-approved-safe",
	})
	if err != nil {
		t.Fatalf("expected paid OpenRouter agentic code-edit TUI adapter run to succeed: %v\nraw output:\n%s", err, raw)
	}
	t.Logf("completed agentic code-edit run: run_id=%s tokens=%d results=%d", summary.RunID, summary.Usage.TotalTokens, len(summary.Results))

	if summary.Status != "completed" {
		t.Fatalf("expected completed summary, got %#v", summary)
	}
	assertPlannerDecision(t, summary.Results, "delegate")
	if !hasEvent(summary.Events, "tool_call_finished") {
		t.Fatalf("expected tool_call_finished event, got %#v", summary.Events)
	}
	if !hasEvent(summary.Events, "run_completed") {
		t.Fatalf("expected run_completed event, got %#v", summary.Events)
	}
	if summary.Usage.TotalTokens <= 0 {
		t.Fatalf("expected positive token usage, got %#v", summary.Usage)
	}

	assertFileContent(t, sourcePath, updatedSource)
	assertFileContent(t, docPath, createdDoc)

	checkpointRoot := filepath.Join(root, ".agent_machine", "checkpoints")
	entries, err := os.ReadDir(checkpointRoot)
	if err != nil {
		t.Fatalf("expected code-edit checkpoint directory %s: %v\nsummary:%#v\nraw:%s", checkpointRoot, err, summary, raw)
	}
	if len(entries) == 0 {
		t.Fatalf("expected at least one code-edit checkpoint in %s", checkpointRoot)
	}

	workerID, worker := delegatedWorkerResult(summary.Results)
	if workerID == "" {
		t.Fatalf("expected delegated worker result, got %#v", summary.Results)
	}
	if strings.TrimSpace(worker.Output) == "" {
		t.Fatalf("expected delegated worker output, got %s: %#v", workerID, worker)
	}

	display := summaryDisplayText(summary)
	if strings.TrimSpace(display) == "" {
		t.Fatalf("expected non-empty TUI display text for code-edit summary %#v", summary)
	}

	m := model{agents: map[string]agentState{}}
	m.applySummaryResults(summary)
	if m.agents[workerID].Output != worker.Output {
		t.Fatalf("expected TUI agent detail state to include code-edit worker output, got %#v", m.agents[workerID])
	}
}

func paidOpenRouterAPIKey(t *testing.T) string {
	t.Helper()

	if os.Getenv("AGENT_MACHINE_PAID_OPENROUTER") != "1" {
		t.Skip("set AGENT_MACHINE_PAID_OPENROUTER=1 to run paid OpenRouter TUI adapter tests")
	}

	apiKey := strings.TrimSpace(os.Getenv("OPENROUTER_API_KEY"))
	if apiKey == "" {
		t.Fatal("OPENROUTER_API_KEY is required for paid OpenRouter TUI adapter tests")
	}
	return apiKey
}

func runPaidAgentMachine(t *testing.T, config runConfig) (summary, string, error) {
	t.Helper()

	session, err := startAgentMachineStream(config)
	if err != nil {
		return summary{}, "", err
	}

	var lines []string
	var final summary
	sawSummary := false

	for session.scanner.Scan() {
		line := session.scanner.Text()
		lines = append(lines, line)
		envelope, ok, parseErr := parseJSONLLine(line)
		if parseErr != nil {
			return summary{}, strings.Join(lines, "\n"), parseErr
		}
		if !ok {
			continue
		}

		switch envelope.Type {
		case "event":
			t.Logf("event: %s", paidEventLog(envelope.Event))
		case "summary":
			final = envelope.Summary
			sawSummary = true
			t.Logf("summary: status=%s run_id=%s tokens=%d results=%d", final.Status, final.RunID, final.Usage.TotalTokens, len(final.Results))
		}
	}

	if err := session.scanner.Err(); err != nil {
		return summary{}, strings.Join(lines, "\n"), err
	}
	if err := session.cmd.Wait(); err != nil {
		stderr := strings.TrimSpace(session.stderr.String())
		if stderr != "" {
			return summary{}, strings.Join(lines, "\n"), fmt.Errorf("mix command failed: %w\n%s", err, stderr)
		}
		return summary{}, strings.Join(lines, "\n"), fmt.Errorf("mix command failed: %w", err)
	}
	if !sawSummary {
		return summary{}, strings.Join(lines, "\n"), fmt.Errorf("AgentMachine stream ended without a summary")
	}
	if final.Status == "failed" {
		return final, strings.Join(lines, "\n"), fmt.Errorf("AgentMachine run failed: %s", summaryError(final))
	}

	return final, strings.Join(lines, "\n"), nil
}

func paidEventLog(event eventSummary) string {
	parts := []string{event.Type}
	if event.AgentID != "" {
		parts = append(parts, "agent="+event.AgentID)
	}
	if event.ParentAgentID != "" {
		parts = append(parts, "parent="+event.ParentAgentID)
	}
	if event.Tool != "" {
		parts = append(parts, "tool="+event.Tool)
	}
	if event.Status != "" {
		parts = append(parts, "status="+event.Status)
	}
	if event.DurationMS != nil {
		parts = append(parts, fmt.Sprintf("duration_ms=%d", *event.DurationMS))
	}
	if event.Reason != "" {
		parts = append(parts, "reason="+event.Reason)
	}
	return strings.Join(parts, " ")
}

func paidOpenRouterModel(t *testing.T) string {
	t.Helper()

	model, ok := os.LookupEnv("AGENT_MACHINE_PAID_OPENROUTER_MODEL")
	if !ok {
		return defaultPaidOpenRouterModel
	}

	model = strings.TrimSpace(model)
	if model == "" {
		t.Fatal("AGENT_MACHINE_PAID_OPENROUTER_MODEL must be non-empty when set")
	}
	return model
}

func assertFileContent(t *testing.T, path string, expected string) {
	t.Helper()

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("expected file %s to exist: %v", path, err)
	}
	if string(content) != expected {
		t.Fatalf("unexpected content for %s: %q, expected %q", path, string(content), expected)
	}
}

func delegatedWorkerResult(results map[string]runResultSummary) (string, runResultSummary) {
	for id, result := range results {
		if id != "planner" && id != "finalizer" {
			return id, result
		}
	}
	return "", runResultSummary{}
}

func assertPlannerDecision(t *testing.T, results map[string]runResultSummary, mode string) {
	t.Helper()

	planner, ok := results["planner"]
	if !ok {
		t.Fatalf("expected planner result, got %#v", results)
	}
	if planner.Decision.Mode != mode {
		t.Fatalf("expected planner decision mode %q, got %#v", mode, planner.Decision)
	}
	if strings.TrimSpace(planner.Decision.Reason) == "" {
		t.Fatalf("expected planner decision reason, got %#v", planner.Decision)
	}
}

func hasEvent(events []eventSummary, eventType string) bool {
	for _, event := range events {
		if event.Type == eventType {
			return true
		}
	}
	return false
}
