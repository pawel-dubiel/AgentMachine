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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type streamSession struct {
	cmd        *exec.Cmd
	scanner    *bufio.Scanner
	stdin      io.WriteCloser
	stdinMu    sync.Mutex
	stderr     *bytes.Buffer
	persistent bool
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
		session, err := startAgentMachineSession(config)
		if err != nil {
			return streamDoneMsg{Err: err}
		}
		return streamStartedMsg{Session: session}
	}
}

func sendSessionUserMessageCommand(session *streamSession, config runConfig) tea.Cmd {
	return func() tea.Msg {
		if err := sendSessionUserMessage(session, config); err != nil {
			return sessionUserMessageSentMsg{Session: session, Err: err}
		}
		return sessionUserMessageSentMsg{Session: session}
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
	return runSkillsCLICommandFor("", args)
}

func runSkillsCLICommandFor(action string, args []string) tea.Cmd {
	return runSkillsCLICommandWithEnv(action, args, nil)
}

func runSkillsCLICommandWithConfig(args []string, config runConfig) tea.Cmd {
	return runSkillsCLICommandWithEnv("", args, commandEnv(os.Environ(), config))
}

func runSkillsCLICommandWithEnv(action string, args []string, env []string) tea.Cmd {
	return func() tea.Msg {
		root, err := projectRoot()
		if err != nil {
			return skillsCommandMsg{Action: action, Err: err}
		}

		cmdArgs := append([]string{"agent_machine.skills"}, args...)
		cmd := exec.Command("mix", cmdArgs...)
		cmd.Dir = root
		if env != nil {
			cmd.Env = env
		}
		output, err := cmd.CombinedOutput()
		raw := strings.TrimSpace(string(output))
		if err != nil {
			if raw != "" {
				return skillsCommandMsg{Action: action, Output: raw, Err: fmt.Errorf("mix command failed: %w\n%s", err, raw)}
			}
			return skillsCommandMsg{Action: action, Err: fmt.Errorf("mix command failed: %w", err)}
		}
		if hasArg(args, "--json") {
			raw = lastJSONLine(raw)
		}
		return skillsCommandMsg{Action: action, Output: raw}
	}
}

func hasArg(args []string, value string) bool {
	for _, arg := range args {
		if arg == value {
			return true
		}
	}
	return false
}

func runAgentMachineCompact(config runConfig, messages []chatMessage) (compactSummary, string, error) {
	if len(messages) == 0 {
		return compactSummary{}, "", errors.New("conversation compaction requires messages")
	}
	root, err := projectRoot()
	if err != nil {
		return compactSummary{}, "", err
	}

	inputFile, cleanup, err := writeCompactInput(messages)
	if err != nil {
		return compactSummary{}, "", err
	}
	defer cleanup()

	args := buildCompactArgs(config, inputFile)
	cmd := exec.Command("mix", args...)
	cmd.Dir = root
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
	args := []string{
		"agent_machine.compact",
		"--provider", string(config.Provider),
		"--model", config.Model,
		"--http-timeout-ms", config.HTTPTimeout,
		"--input-price-per-million", config.InputPrice,
		"--output-price-per-million", config.OutputPrice,
		"--input-file", inputFile,
		"--json",
	}
	for _, key := range sortedStringMapKeys(config.ProviderOptions) {
		value := config.ProviderOptions[key]
		args = append(args, "--provider-option", key+"="+value)
	}
	return args
}

func startAgentMachineStream(config runConfig) (*streamSession, error) {
	if err := prepareRunLog(config); err != nil {
		return nil, err
	}
	root, err := projectRoot()
	if err != nil {
		return nil, err
	}

	args := buildRunArgs(config)
	cmd := exec.Command("mix", args...)
	cmd.Dir = root
	cmd.Env = commandEnv(os.Environ(), config)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open AgentMachine stdout: %w", err)
	}
	var stdin io.WriteCloser
	if usesRuntimeControl(config) {
		stdin, err = cmd.StdinPipe()
		if err != nil {
			return nil, fmt.Errorf("failed to open AgentMachine stdin: %w", err)
		}
	}
	stderr := &bytes.Buffer{}
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start AgentMachine: %w", err)
	}

	scanner := newLineScanner(stdout)
	return &streamSession{cmd: cmd, scanner: scanner, stdin: stdin, stderr: stderr}, nil
}

func startAgentMachineSession(config runConfig) (*streamSession, error) {
	if strings.TrimSpace(config.EventSessionID) == "" {
		return nil, errors.New("session id is required for AgentMachine session daemon")
	}
	if strings.TrimSpace(config.EventLogFile) == "" {
		return nil, errors.New("session log file is required for AgentMachine session daemon")
	}
	if err := prepareRunLog(runConfig{LogFile: config.EventLogFile}); err != nil {
		return nil, err
	}
	root, err := projectRoot()
	if err != nil {
		return nil, err
	}

	args := []string{
		"agent_machine.session",
		"--jsonl-stdio",
		"--session-id", config.EventSessionID,
		"--session-dir", sessionDataDir(config),
		"--log-file", config.EventLogFile,
	}
	cmd := exec.Command("mix", args...)
	cmd.Dir = root
	cmd.Env = commandEnv(os.Environ(), config)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open AgentMachine session stdout: %w", err)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to open AgentMachine session stdin: %w", err)
	}
	stderr := &bytes.Buffer{}
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start AgentMachine session: %w", err)
	}

	session := &streamSession{
		cmd:        cmd,
		scanner:    newLineScanner(stdout),
		stdin:      stdin,
		stderr:     stderr,
		persistent: true,
	}
	if err := sendSessionUserMessage(session, config); err != nil {
		_ = cmd.Process.Kill()
		return nil, err
	}
	return session, nil
}

func sendSessionUserMessage(session *streamSession, config runConfig) error {
	if session == nil || session.stdin == nil {
		return errors.New("AgentMachine session stdin is not available")
	}
	payload, err := sessionUserMessagePayload(config)
	if err != nil {
		return err
	}
	line, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	session.stdinMu.Lock()
	defer session.stdinMu.Unlock()
	_, err = session.stdin.Write(append(line, '\n'))
	return err
}

func sessionUserMessagePayload(config runConfig) (map[string]any, error) {
	run, err := sessionRunPayload(config)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"type":       "user_message",
		"message_id": "msg-" + strconv.FormatInt(time.Now().UTC().UnixNano(), 10),
		"run":        run,
	}, nil
}

func sessionRunPayload(config runConfig) (map[string]any, error) {
	timeoutMS, err := positiveIntValue(runTimeoutMS(config), "run timeout ms")
	if err != nil {
		return nil, err
	}
	maxStepsValue, err := positiveIntValue(runMaxSteps(config), "max steps")
	if err != nil {
		return nil, err
	}
	sessionToolTimeout, err := positiveIntValue(sessionToolTimeoutMS(config), "session tool timeout ms")
	if err != nil {
		return nil, err
	}
	sessionToolMaxRounds, err := positiveIntValue(defaultSessionToolMaxRounds, "session tool max rounds")
	if err != nil {
		return nil, err
	}

	run := map[string]any{
		"task":                    config.Task,
		"provider":                string(config.Provider),
		"timeout_ms":              timeoutMS,
		"max_steps":               maxStepsValue,
		"max_attempts":            1,
		"stream_response":         true,
		"session_tool_timeout_ms": sessionToolTimeout,
		"session_tool_max_rounds": sessionToolMaxRounds,
	}
	if strings.TrimSpace(config.LogFile) != "" {
		run["log_file"] = config.LogFile
	}
	if config.ProgressObserver {
		run["progress_observer"] = true
	}

	if config.Provider != providerEcho {
		httpTimeout, err := positiveIntValue(config.HTTPTimeout, "http timeout ms")
		if err != nil {
			return nil, err
		}
		inputPrice, err := nonNegativeFloatValue(config.InputPrice, "input price")
		if err != nil {
			return nil, err
		}
		outputPrice, err := nonNegativeFloatValue(config.OutputPrice, "output price")
		if err != nil {
			return nil, err
		}
		run["model"] = config.Model
		if len(config.ProviderOptions) > 0 {
			run["provider_options"] = config.ProviderOptions
		}
		run["http_timeout_ms"] = httpTimeout
		run["pricing"] = map[string]any{
			"input_per_million":  inputPrice,
			"output_per_million": outputPrice,
		}
	}

	if err := putSessionToolPayload(run, config); err != nil {
		return nil, err
	}
	putSessionSkillsPayload(run, config)
	if err := putSessionRouterPayload(run, config); err != nil {
		return nil, err
	}
	if err := putSessionContextPayload(run, config); err != nil {
		return nil, err
	}
	if strings.TrimSpace(config.AgenticPersistenceRounds) != "" {
		rounds, err := positiveIntValue(config.AgenticPersistenceRounds, "agentic persistence rounds")
		if err != nil {
			return nil, err
		}
		run["agentic_persistence_rounds"] = rounds
	}
	if strings.TrimSpace(config.PlannerReviewMaxRevisions) != "" {
		revisions, err := positiveIntValue(config.PlannerReviewMaxRevisions, "planner review max revisions")
		if err != nil {
			return nil, err
		}
		run["planner_review_mode"] = "jsonl-stdio"
		run["planner_review_max_revisions"] = revisions
	}
	return run, nil
}

func putSessionToolPayload(run map[string]any, config runConfig) error {
	harnesses := []string{}
	if strings.TrimSpace(config.ToolHarness) != "" {
		harnesses = append(harnesses, config.ToolHarness)
	}
	if strings.TrimSpace(config.MCPConfig) != "" {
		harnesses = append(harnesses, "mcp")
		run["mcp_config_path"] = config.MCPConfig
	}
	if len(harnesses) == 0 {
		return nil
	}

	toolTimeout, err := positiveIntValue(config.ToolTimeout, "tool timeout ms")
	if err != nil {
		return err
	}
	toolMaxRounds, err := positiveIntValue(config.ToolMaxRounds, "tool max rounds")
	if err != nil {
		return err
	}
	run["tool_harnesses"] = harnesses
	run["tool_timeout_ms"] = toolTimeout
	run["tool_max_rounds"] = toolMaxRounds
	run["tool_approval_mode"] = config.ToolApproval
	if strings.TrimSpace(config.ToolRoot) != "" {
		run["tool_root"] = config.ToolRoot
	}
	if len(config.TestCommands) > 0 {
		run["test_commands"] = config.TestCommands
	}
	return nil
}

func putSessionSkillsPayload(run map[string]any, config runConfig) {
	if config.SkillsMode != "" {
		run["skills_mode"] = config.SkillsMode
	}
	if config.SkillsDir != "" {
		run["skills_dir"] = config.SkillsDir
	}
	if len(config.SkillNames) > 0 {
		run["skill_names"] = config.SkillNames
	}
	if config.AllowSkillScripts {
		run["allow_skill_scripts"] = true
	}
}

func putSessionRouterPayload(run map[string]any, config runConfig) error {
	if strings.TrimSpace(config.RouterMode) == "" {
		return nil
	}
	run["router_mode"] = config.RouterMode
	if config.RouterMode != "local" {
		return nil
	}
	timeout, err := positiveIntValue(config.RouterTimeout, "router timeout ms")
	if err != nil {
		return err
	}
	confidence, err := nonNegativeFloatValue(config.RouterConfidence, "router confidence")
	if err != nil {
		return err
	}
	run["router_model_dir"] = config.RouterModelDir
	run["router_timeout_ms"] = timeout
	run["router_confidence_threshold"] = confidence
	return nil
}

func putSessionContextPayload(run map[string]any, config runConfig) error {
	intFields := map[string]string{
		"context_window_tokens":       config.ContextWindow,
		"context_warning_percent":     config.ContextWarning,
		"reserved_output_tokens":      config.ReservedOutput,
		"run_context_compact_percent": config.ContextCompactPct,
		"max_context_compactions":     config.MaxContextCompact,
	}
	for key, value := range intFields {
		if strings.TrimSpace(value) == "" {
			continue
		}
		parsed, err := positiveIntValue(value, key)
		if err != nil {
			return err
		}
		run[key] = parsed
	}
	if config.ContextTokenizer != "" {
		run["context_tokenizer_path"] = config.ContextTokenizer
	}
	if config.RunContextCompact != "" {
		run["run_context_compaction"] = config.RunContextCompact
	}
	return nil
}

func sessionDataDir(config runConfig) string {
	return filepath.Join(filepath.Dir(config.EventLogFile), "sessions")
}

func sessionToolTimeoutMS(config runConfig) string {
	if strings.TrimSpace(config.RunTimeout) != "" {
		return config.RunTimeout
	}
	return runTimeoutMS(config)
}

func positiveIntValue(value string, label string) (int, error) {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer, got %q", label, value)
	}
	return parsed, nil
}

func nonNegativeFloatValue(value string, label string) (float64, error) {
	parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil || parsed < 0 {
		return 0, fmt.Errorf("%s must be a non-negative number, got %q", label, value)
	}
	return parsed, nil
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
	root, err := projectRoot()
	if err != nil {
		return summary{}, "", err
	}

	args := buildRunArgs(config)
	cmd := exec.Command("mix", args...)
	cmd.Dir = root
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
	// Run execution stays on the public mix agent_machine.run boundary.
	args := []string{
		"agent_machine.run",
		"--provider", string(config.Provider),
		"--timeout-ms", runTimeoutMS(config),
		"--max-steps", runMaxSteps(config),
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
		for _, key := range sortedStringMapKeys(config.ProviderOptions) {
			value := config.ProviderOptions[key]
			args = append(args, "--provider-option", key+"="+value)
		}
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
		if usesPermissionControl(config) {
			args = append(args, "--permission-control", "jsonl-stdio")
		}
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
	if config.ProgressObserver {
		args = append(args, "--progress-observer")
	}

	if config.ContextWindow != "" {
		args = append(args, "--context-window-tokens", config.ContextWindow)
	}
	if config.ContextWarning != "" {
		args = append(args, "--context-warning-percent", config.ContextWarning)
	}
	if config.ContextTokenizer != "" {
		args = append(args, "--context-tokenizer-path", config.ContextTokenizer)
	}
	if config.ReservedOutput != "" {
		args = append(args, "--reserved-output-tokens", config.ReservedOutput)
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

	if strings.TrimSpace(config.AgenticPersistenceRounds) != "" {
		args = append(args, "--agentic-persistence-rounds", config.AgenticPersistenceRounds)
	}
	if strings.TrimSpace(config.PlannerReviewMaxRevisions) != "" {
		args = append(args,
			"--planner-review", "jsonl-stdio",
			"--planner-review-max-revisions", config.PlannerReviewMaxRevisions,
		)
	}

	return append(args, config.Task)
}

func usesRuntimeControl(config runConfig) bool {
	return usesPermissionControl(config) || strings.TrimSpace(config.PlannerReviewMaxRevisions) != ""
}

func usesPermissionControl(config runConfig) bool {
	return config.ToolApproval == "ask-before-write" &&
		(config.ToolHarness != "" || strings.TrimSpace(config.MCPConfig) != "")
}

func sendPermissionDecisionCommand(session *streamSession, requestID string, decision string, reason string) tea.Cmd {
	return func() tea.Msg {
		if session == nil || session.stdin == nil {
			return permissionDecisionMsg{RequestID: requestID, Decision: decision, Err: errors.New("permission control stdin is not available")}
		}

		payload := map[string]string{
			"type":       "permission_decision",
			"request_id": requestID,
			"decision":   decision,
			"reason":     reason,
		}
		line, err := json.Marshal(payload)
		if err != nil {
			return permissionDecisionMsg{RequestID: requestID, Decision: decision, Err: err}
		}

		session.stdinMu.Lock()
		defer session.stdinMu.Unlock()
		if _, err := session.stdin.Write(append(line, '\n')); err != nil {
			return permissionDecisionMsg{RequestID: requestID, Decision: decision, Err: err}
		}
		return permissionDecisionMsg{RequestID: requestID, Decision: decision}
	}
}

func sendPlannerReviewDecisionCommand(session *streamSession, requestID string, decision string, feedback string, reason string) tea.Cmd {
	return func() tea.Msg {
		if session == nil || session.stdin == nil {
			return plannerReviewDecisionMsg{RequestID: requestID, Decision: decision, Err: errors.New("planner review stdin is not available")}
		}

		payload := map[string]string{
			"type":       "planner_review_decision",
			"request_id": requestID,
			"decision":   decision,
			"reason":     reason,
		}
		if strings.TrimSpace(feedback) != "" {
			payload["feedback"] = feedback
		}
		line, err := json.Marshal(payload)
		if err != nil {
			return plannerReviewDecisionMsg{RequestID: requestID, Decision: decision, Err: err}
		}

		session.stdinMu.Lock()
		defer session.stdinMu.Unlock()
		if _, err := session.stdin.Write(append(line, '\n')); err != nil {
			return plannerReviewDecisionMsg{RequestID: requestID, Decision: decision, Err: err}
		}
		return plannerReviewDecisionMsg{RequestID: requestID, Decision: decision}
	}
}

func sendSessionAgentMessageCommand(session *streamSession, agentID string, content string, resume bool) tea.Cmd {
	return writeSessionCommand(session, map[string]any{
		"type":       "send_agent_message",
		"message_id": "msg-" + strconv.FormatInt(time.Now().UTC().UnixNano(), 10),
		"agent_id":   agentID,
		"content":    content,
		"resume":     resume,
	})
}

func readSessionAgentOutputCommand(session *streamSession, agentID string) tea.Cmd {
	return writeSessionCommand(session, map[string]any{
		"type":       "read_agent_output",
		"request_id": "read-" + strconv.FormatInt(time.Now().UTC().UnixNano(), 10),
		"agent_id":   agentID,
		"limit":      20,
	})
}

func writeSessionCommand(session *streamSession, payload map[string]any) tea.Cmd {
	return func() tea.Msg {
		if session == nil || session.stdin == nil || !session.persistent {
			return sessionUserMessageSentMsg{Session: session, Err: errors.New("AgentMachine session daemon is not running")}
		}
		line, err := json.Marshal(payload)
		if err != nil {
			return sessionUserMessageSentMsg{Session: session, Err: err}
		}
		session.stdinMu.Lock()
		defer session.stdinMu.Unlock()
		if _, err := session.stdin.Write(append(line, '\n')); err != nil {
			return sessionUserMessageSentMsg{Session: session, Err: err}
		}
		return sessionUserMessageSentMsg{Session: session}
	}
}

func closeStreamSession(session *streamSession) {
	if session == nil {
		return
	}
	if session.stdin != nil {
		session.stdinMu.Lock()
		_, _ = session.stdin.Write([]byte("{\"type\":\"shutdown\",\"reason\":\"session replaced\"}\n"))
		_ = session.stdin.Close()
		session.stdinMu.Unlock()
	}
	if session.cmd != nil && session.cmd.Process != nil {
		_ = session.cmd.Process.Kill()
	}
}

func sessionReusable(previous runConfig, next runConfig) bool {
	return previous.Provider == next.Provider &&
		stringMapsEqual(previous.ProviderSecrets, next.ProviderSecrets) &&
		stringMapsEqual(previous.ProviderOptions, next.ProviderOptions) &&
		previous.EventSessionID == next.EventSessionID
}

func stringMapsEqual(left map[string]string, right map[string]string) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if right[key] != value {
			return false
		}
	}
	return true
}

func sortedStringMapKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func maxSteps(workflow runWorkflow) string {
	switch workflow {
	case workflowAgentic:
		return defaultAgenticSteps
	default:
		return ""
	}
}

func runMaxSteps(config runConfig) string {
	if strings.TrimSpace(config.MaxSteps) != "" {
		return config.MaxSteps
	}
	return maxSteps(config.Workflow)
}

func runTimeoutMS(config runConfig) string {
	if strings.TrimSpace(config.RunTimeout) != "" {
		return config.RunTimeout
	}
	if config.Workflow == workflowAgentic {
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
	if !strings.Contains(trimmed, `"type"`) {
		return jsonlEnvelope{}, false, nil
	}

	var envelope jsonlEnvelope
	if err := json.Unmarshal([]byte(trimmed), &envelope); err != nil {
		return jsonlEnvelope{}, false, fmt.Errorf("failed to parse AgentMachine JSONL line: %w", err)
	}
	envelope.Raw = json.RawMessage(trimmed)
	if envelope.Type == "" {
		return jsonlEnvelope{}, false, nil
	}
	return envelope, true, nil
}

func lastJSONLine(raw string) string {
	lines := strings.Split(strings.TrimSpace(raw), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if (strings.HasPrefix(line, "{") && strings.HasSuffix(line, "}")) ||
			(strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]")) {
			return line
		}
	}
	return ""
}

func projectRoot() (string, error) {
	if root := strings.TrimSpace(os.Getenv("AGENT_MACHINE_ROOT")); root != "" {
		return validateProjectRoot(root, "AGENT_MACHINE_ROOT")
	}

	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("failed to read current working directory: %w", err)
	}

	if fileExists(filepath.Join(cwd, "mix.exs")) {
		return cwd, nil
	}

	parent := filepath.Clean(filepath.Join(cwd, ".."))
	if fileExists(filepath.Join(parent, "mix.exs")) {
		return parent, nil
	}
	return "", fmt.Errorf("AgentMachine project root is required: run from the repository root, run from tui/, or set AGENT_MACHINE_ROOT to the repository containing mix.exs")
}

func validateProjectRoot(root string, source string) (string, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("failed to resolve %s %q: %w", source, root, err)
	}
	if !fileExists(filepath.Join(absolute, "mix.exs")) {
		return "", fmt.Errorf("%s must point to an AgentMachine repository containing mix.exs, got %q", source, root)
	}
	return absolute, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
