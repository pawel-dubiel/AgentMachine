package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type streamSession struct {
	cmd     *exec.Cmd
	scanner *bufio.Scanner
	stderr  *bytes.Buffer
}

var compactRunner = runAgentMachineCompact

func runCommand(config runConfig) tea.Cmd {
	return func() tea.Msg {
		summary, raw, err := runAgentMachine(config)
		return runResultMsg{Summary: summary, Raw: raw, Err: err}
	}
}

func startStreamingCommand(config runConfig) tea.Cmd {
	return func() tea.Msg {
		session, err := startAgentMachineStream(config)
		if err != nil {
			return streamDoneMsg{Err: err}
		}
		return streamStartedMsg{Session: session}
	}
}

func readStreamCommand(session *streamSession) tea.Cmd {
	return func() tea.Msg {
		if session.scanner.Scan() {
			return streamLineMsg{Session: session, Line: session.scanner.Text()}
		}
		if err := session.scanner.Err(); err != nil {
			return streamDoneMsg{Session: session, Err: err}
		}
		err := session.cmd.Wait()
		if err != nil {
			stderr := strings.TrimSpace(session.stderr.String())
			if stderr != "" {
				return streamDoneMsg{Session: session, Err: fmt.Errorf("mix command failed: %w\n%s", err, stderr)}
			}
			return streamDoneMsg{Session: session, Err: fmt.Errorf("mix command failed: %w", err)}
		}
		return streamDoneMsg{Session: session}
	}
}

func compactCommand(config runConfig, messages []chatMessage) tea.Cmd {
	return func() tea.Msg {
		summary, raw, err := compactRunner(config, messages)
		return compactResultMsg{Summary: summary, Raw: raw, Err: err}
	}
}

func runSkillsCLICommand(args []string) tea.Cmd {
	return func() tea.Msg {
		cmdArgs := append([]string{"agent_machine.skills"}, args...)
		cmd := exec.Command("mix", cmdArgs...)
		cmd.Dir = projectRoot()
		output, err := cmd.CombinedOutput()
		raw := strings.TrimSpace(string(output))
		if err != nil {
			if raw != "" {
				return skillsCommandMsg{Output: raw, Err: fmt.Errorf("mix command failed: %w\n%s", err, raw)}
			}
			return skillsCommandMsg{Err: fmt.Errorf("mix command failed: %w", err)}
		}
		return skillsCommandMsg{Output: raw}
	}
}

func runAgentMachineCompact(config runConfig, messages []chatMessage) (compactSummary, string, error) {
	if len(messages) == 0 {
		return compactSummary{}, "", errors.New("conversation compaction requires messages")
	}

	inputFile, cleanup, err := writeCompactInput(messages)
	if err != nil {
		return compactSummary{}, "", err
	}
	defer cleanup()

	args := buildCompactArgs(config, inputFile)
	cmd := exec.Command("mix", args...)
	cmd.Dir = projectRoot()
	cmd.Env = commandEnv(os.Environ(), config)

	output, err := cmd.CombinedOutput()
	raw := strings.TrimSpace(string(output))
	if err != nil {
		return compactSummary{}, raw, fmt.Errorf("mix command failed: %w", err)
	}

	parsed, parseErr := parseCompactSummary(raw)
	if parseErr != nil {
		return compactSummary{}, raw, parseErr
	}
	if parsed.Status != "ok" {
		return parsed, raw, fmt.Errorf("AgentMachine compact failed: %s", emptyAs(parsed.Status, "unknown status"))
	}
	return parsed, raw, nil
}

func writeCompactInput(messages []chatMessage) (string, func(), error) {
	file, err := os.CreateTemp("", "agent-machine-compact-*.json")
	if err != nil {
		return "", func() {}, fmt.Errorf("failed to create compact input file: %w", err)
	}

	cleanup := func() {
		_ = os.Remove(file.Name())
	}

	payload := map[string]any{
		"type":     "conversation",
		"messages": compactInputMessages(messages),
	}

	encoder := json.NewEncoder(file)
	if err := encoder.Encode(payload); err != nil {
		_ = file.Close()
		cleanup()
		return "", func() {}, fmt.Errorf("failed to write compact input file: %w", err)
	}
	if err := file.Close(); err != nil {
		cleanup()
		return "", func() {}, fmt.Errorf("failed to close compact input file: %w", err)
	}

	return file.Name(), cleanup, nil
}

func compactInputMessages(messages []chatMessage) []map[string]string {
	out := make([]map[string]string, 0, len(messages))
	for _, message := range messages {
		out = append(out, map[string]string{
			"role": message.Role,
			"text": message.Text,
		})
	}
	return out
}

func buildCompactArgs(config runConfig, inputFile string) []string {
	return []string{
		"agent_machine.compact",
		"--provider", string(config.Provider),
		"--model", config.Model,
		"--http-timeout-ms", config.HTTPTimeout,
		"--input-price-per-million", config.InputPrice,
		"--output-price-per-million", config.OutputPrice,
		"--input-file", inputFile,
		"--json",
	}
}

func startAgentMachineStream(config runConfig) (*streamSession, error) {
	if err := prepareRunLog(config); err != nil {
		return nil, err
	}

	args := buildRunArgs(config)
	cmd := exec.Command("mix", args...)
	cmd.Dir = projectRoot()
	cmd.Env = commandEnv(os.Environ(), config)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open AgentMachine stdout: %w", err)
	}
	stderr := &bytes.Buffer{}
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start AgentMachine: %w", err)
	}

	scanner := newLineScanner(stdout)
	return &streamSession{cmd: cmd, scanner: scanner, stderr: stderr}, nil
}

func newLineScanner(reader io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	return scanner
}

func runAgentMachine(config runConfig) (summary, string, error) {
	if err := prepareRunLog(config); err != nil {
		return summary{}, "", err
	}

	args := buildRunArgs(config)
	cmd := exec.Command("mix", args...)
	cmd.Dir = projectRoot()
	cmd.Env = commandEnv(os.Environ(), config)

	output, err := cmd.CombinedOutput()
	raw := strings.TrimSpace(string(output))
	if err != nil {
		return summary{}, raw, fmt.Errorf("mix command failed: %w", err)
	}

	parsed, parseErr := parseSummary(raw)
	if parseErr != nil {
		return summary{}, raw, parseErr
	}
	if parsed.Status == "failed" {
		return parsed, raw, fmt.Errorf("AgentMachine run failed: %s", summaryError(parsed))
	}

	return parsed, raw, nil
}

func prepareRunLog(config runConfig) error {
	if strings.TrimSpace(config.LogFile) == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(config.LogFile), 0o700); err != nil {
		return fmt.Errorf("failed to create AgentMachine log directory: %w", err)
	}
	return nil
}

func buildRunArgs(config runConfig) []string {
	args := []string{
		"agent_machine.run",
		"--workflow", string(config.Workflow),
		"--provider", string(config.Provider),
		"--timeout-ms", runTimeoutMS(config),
		"--max-steps", maxSteps(config.Workflow),
		"--max-attempts", "1",
		"--jsonl",
		"--stream-response",
	}

	if config.Provider != providerEcho {
		args = append(args,
			"--model", config.Model,
			"--http-timeout-ms", config.HTTPTimeout,
			"--input-price-per-million", config.InputPrice,
			"--output-price-per-million", config.OutputPrice,
		)
	}

	if config.ToolHarness != "" || strings.TrimSpace(config.MCPConfig) != "" {
		if config.ToolHarness != "" {
			args = append(args, "--tool-harness", config.ToolHarness)
		}
		if strings.TrimSpace(config.MCPConfig) != "" {
			args = append(args, "--tool-harness", "mcp", "--mcp-config", config.MCPConfig)
		}
		args = append(args,
			"--tool-timeout-ms", config.ToolTimeout,
			"--tool-max-rounds", config.ToolMaxRounds,
			"--tool-approval-mode", config.ToolApproval,
		)
		if config.ToolRoot != "" {
			args = append(args, "--tool-root", config.ToolRoot)
		}
		for _, command := range config.TestCommands {
			args = append(args, "--test-command", command)
		}
	}

	if config.SkillsMode == "auto" {
		args = append(args, "--skills", "auto", "--skills-dir", config.SkillsDir)
	}
	if len(config.SkillNames) > 0 {
		args = append(args, "--skills-dir", config.SkillsDir)
		for _, name := range config.SkillNames {
			args = append(args, "--skill", name)
		}
	}
	if config.AllowSkillScripts {
		args = append(args, "--allow-skill-scripts")
	}

	if strings.TrimSpace(config.RouterMode) != "" {
		args = append(args, "--router-mode", config.RouterMode)
		if config.RouterMode == "local" {
			args = append(args,
				"--router-model-dir", config.RouterModelDir,
				"--router-timeout-ms", config.RouterTimeout,
				"--router-confidence-threshold", config.RouterConfidence,
			)
		}
	}

	if config.LogFile != "" {
		args = append(args, "--log-file", config.LogFile)
	}
	if config.EventLogFile != "" {
		args = append(args, "--event-log-file", config.EventLogFile)
	}
	if config.EventSessionID != "" {
		args = append(args, "--event-session-id", config.EventSessionID)
	}

	if config.ContextWindow != "" {
		args = append(args, "--context-window-tokens", config.ContextWindow)
	}
	if config.ContextWarning != "" {
		args = append(args, "--context-warning-percent", config.ContextWarning)
	}
	if config.RunContextCompact != "" {
		args = append(args, "--run-context-compaction", config.RunContextCompact)
	}
	if config.ContextCompactPct != "" {
		args = append(args, "--run-context-compact-percent", config.ContextCompactPct)
	}
	if config.MaxContextCompact != "" {
		args = append(args, "--max-context-compactions", config.MaxContextCompact)
	}

	return append(args, config.Task)
}

func maxSteps(workflow runWorkflow) string {
	switch workflow {
	case workflowChat:
		return defaultChatSteps
	case workflowBasic:
		return defaultBasicSteps
	case workflowAgentic:
		return defaultAgenticSteps
	case workflowAuto:
		return defaultAgenticSteps
	default:
		return ""
	}
}

func runTimeoutMS(config runConfig) string {
	if strings.TrimSpace(config.RunTimeout) != "" {
		return config.RunTimeout
	}
	if config.Workflow == workflowAgentic || config.Workflow == workflowAuto {
		return defaultAgenticRunTimeoutMS
	}
	return defaultRunTimeoutMS
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
	if parsed.RunID == "" {
		envelope, ok, err := parseJSONLLine(jsonLine)
		if err != nil {
			return summary{}, err
		}
		if ok && envelope.Type == "summary" {
			return envelope.Summary, nil
		}
	}
	return parsed, nil
}

func parseCompactSummary(raw string) (compactSummary, error) {
	var parsed compactSummary
	jsonLine := lastJSONLine(raw)
	if jsonLine == "" {
		return compactSummary{}, errors.New("AgentMachine compact output did not contain a JSON summary")
	}
	if err := json.Unmarshal([]byte(jsonLine), &parsed); err != nil {
		return compactSummary{}, fmt.Errorf("failed to parse AgentMachine compact JSON output: %w", err)
	}
	if strings.TrimSpace(parsed.Summary) == "" {
		return compactSummary{}, errors.New("AgentMachine compact output did not contain a summary")
	}
	return parsed, nil
}

func parseJSONLLine(line string) (jsonlEnvelope, bool, error) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || !strings.HasPrefix(trimmed, "{") {
		return jsonlEnvelope{}, false, nil
	}

	var envelope jsonlEnvelope
	if err := json.Unmarshal([]byte(trimmed), &envelope); err != nil {
		return jsonlEnvelope{}, false, fmt.Errorf("failed to parse AgentMachine JSONL line: %w", err)
	}
	if envelope.Type == "" {
		return jsonlEnvelope{}, false, nil
	}
	return envelope, true, nil
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
