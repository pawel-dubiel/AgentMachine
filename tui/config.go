package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	userConfigDirName    = ".agent-machine"
	legacyConfigDirName  = "agent-machine"
	tuiConfigFileName    = "tui-config.json"
	projectConfigDirName = ".agent-machine"
)

type tuiConfigResolution struct {
	Path         string
	LegacyPath   string
	ProjectPath  string
	ProjectRoot  string
	WorkingDir   string
	ExplicitPath bool
}

func commandEnv(base []string, config runConfig) []string {
	keyName := apiKeyName(config.Provider)
	if keyName == "" {
		return base
	}
	env := removeEnv(base, keyName)
	return append(env, keyName+"="+config.APIKey)
}

func removeEnv(env []string, name string) []string {
	prefix := name + "="
	filtered := make([]string, 0, len(env))
	for _, value := range env {
		if !strings.HasPrefix(value, prefix) {
			filtered = append(filtered, value)
		}
	}
	return filtered
}

func tuiConfigPath() (string, error) {
	resolution, err := resolveTUIConfig()
	if err != nil {
		return "", err
	}
	return resolution.Path, nil
}

func resolveTUIConfig() (tuiConfigResolution, error) {
	workingDir, err := currentWorkingDir()
	if err != nil {
		return tuiConfigResolution{}, err
	}

	if path := strings.TrimSpace(os.Getenv("AGENT_MACHINE_TUI_CONFIG")); path != "" {
		return tuiConfigResolution{Path: path, WorkingDir: workingDir, ExplicitPath: true}, nil
	}

	userPath, err := userTUIConfigPath()
	if err != nil {
		return tuiConfigResolution{}, err
	}

	legacyPath, err := legacyTUIConfigPath()
	if err != nil {
		return tuiConfigResolution{}, err
	}

	projectPath, projectRoot, err := findProjectTUIConfig()
	if err != nil {
		return tuiConfigResolution{}, err
	}

	return tuiConfigResolution{
		Path:        userPath,
		LegacyPath:  legacyPath,
		ProjectPath: projectPath,
		ProjectRoot: projectRoot,
		WorkingDir:  workingDir,
	}, nil
}

func currentWorkingDir() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("failed to locate current directory: %w", err)
	}
	return filepath.Clean(wd), nil
}

func userTUIConfigPath() (string, error) {
	home := strings.TrimSpace(os.Getenv("HOME"))
	if home == "" {
		return "", errors.New("HOME is required to locate ~/.agent-machine/tui-config.json")
	}
	return filepath.Join(home, userConfigDirName, tuiConfigFileName), nil
}

func legacyTUIConfigPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("failed to locate legacy user config directory: %w", err)
	}
	return filepath.Join(configDir, legacyConfigDirName, tuiConfigFileName), nil
}

func findProjectTUIConfig() (string, string, error) {
	home := filepath.Clean(strings.TrimSpace(os.Getenv("HOME")))
	wd, err := os.Getwd()
	if err != nil {
		return "", "", fmt.Errorf("failed to locate current directory for project config lookup: %w", err)
	}

	dir := filepath.Clean(wd)
	for {
		if home != "" && dir == home {
			return "", "", nil
		}

		configPath, err := projectConfigInDir(dir)
		if err != nil {
			return "", "", err
		}
		if configPath != "" {
			return configPath, dir, nil
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return "", "", nil
		}
		dir = parent
	}
}

func projectConfigInDir(dir string) (string, error) {
	configPath := filepath.Join(dir, projectConfigDirName, tuiConfigFileName)
	exists, err := pathExists(configPath)
	if err != nil {
		return "", err
	}
	if exists {
		return configPath, nil
	}
	return "", nil
}

func loadResolvedSavedConfig(resolution tuiConfigResolution) (savedConfig, bool, error) {
	if resolution.ExplicitPath {
		config, err := loadSavedConfig(resolution.Path)
		return config, false, err
	}

	config, loadedLegacy, err := loadUserSavedConfig(resolution.Path, resolution.LegacyPath)
	if err != nil {
		return savedConfig{}, false, err
	}

	if strings.TrimSpace(resolution.ProjectPath) == "" {
		return config, loadedLegacy, nil
	}

	projectConfig, err := loadSavedConfig(resolution.ProjectPath)
	if err != nil {
		return savedConfig{}, false, err
	}
	projectConfig, err = normalizeProjectSavedConfig(projectConfig, resolution.ProjectRoot, resolution.ProjectPath)
	if err != nil {
		return savedConfig{}, false, err
	}

	mergedConfig := overlaySavedConfig(config, projectConfig)
	if err := validateMergedProjectConfig(mergedConfig, projectConfig, resolution.ProjectRoot, resolution.ProjectPath); err != nil {
		return savedConfig{}, false, err
	}

	return mergedConfig, loadedLegacy, nil
}

func migrateSavedToolRootToWorkingDir(config *savedConfig, workingDir string) (bool, error) {
	if config.ToolHarness != "local-files" && config.ToolHarness != "code-edit" {
		return false, nil
	}

	root := strings.TrimSpace(config.ToolRoot)
	if root == "" {
		return false, nil
	}

	resolvedRoot, err := resolveToolRootPath(root, workingDir)
	if err != nil {
		return false, err
	}

	workingDir = filepath.Clean(strings.TrimSpace(workingDir))
	if workingDir != "" && resolvedRoot == filepath.Join(workingDir, "tui") {
		config.ToolRoot = workingDir
		return true, nil
	}

	home := strings.TrimSpace(os.Getenv("HOME"))
	if home != "" && resolvedRoot == filepath.Clean(home) && workingDir != "" && workingDir != filepath.Clean(home) {
		config.ToolRoot = workingDir
		return true, nil
	}

	if resolvedRoot != root {
		config.ToolRoot = resolvedRoot
		return true, nil
	}

	return false, nil
}

func resolveToolRootPath(root string, workingDir string) (string, error) {
	root = strings.TrimSpace(root)
	if root == "" {
		return "", errors.New("tool root must not be empty")
	}

	resolved := root
	if !filepath.IsAbs(resolved) {
		base := strings.TrimSpace(workingDir)
		if base == "" {
			return "", errors.New("working directory is required to resolve relative tool root")
		}
		resolved = filepath.Join(base, resolved)
	}

	return filepath.Clean(resolved), nil
}

func loadUserSavedConfig(userPath string, legacyPath string) (savedConfig, bool, error) {
	userExists, err := pathExists(userPath)
	if err != nil {
		return savedConfig{}, false, err
	}
	if userExists {
		config, err := loadSavedConfig(userPath)
		return config, false, err
	}

	if strings.TrimSpace(legacyPath) != "" {
		legacyExists, err := pathExists(legacyPath)
		if err != nil {
			return savedConfig{}, false, err
		}
		if legacyExists {
			config, err := loadSavedConfig(legacyPath)
			return config, true, err
		}
	}

	return savedConfig{}, false, nil
}

func normalizeProjectSavedConfig(config savedConfig, projectRoot string, projectPath string) (savedConfig, error) {
	if strings.TrimSpace(config.OpenAIAPIKey) != "" || strings.TrimSpace(config.OpenRouterAPIKey) != "" {
		return savedConfig{}, fmt.Errorf("project TUI config %s must not contain API keys; keep provider secrets in ~/.agent-machine/tui-config.json", projectPath)
	}

	if strings.TrimSpace(config.ToolApproval) == "full-access" {
		return savedConfig{}, fmt.Errorf("project TUI config %s must not set full-access tool approval; enable full access explicitly in the TUI", projectPath)
	}

	var err error
	if config.ToolRoot, err = normalizeProjectPath(config.ToolRoot, projectRoot, projectPath, "tool_root"); err != nil {
		return savedConfig{}, err
	}
	if config.MCPConfig, err = normalizeProjectPath(config.MCPConfig, projectRoot, projectPath, "mcp_config"); err != nil {
		return savedConfig{}, err
	}
	if config.RouterModelDir, err = normalizeProjectPath(config.RouterModelDir, projectRoot, projectPath, "router_model_dir"); err != nil {
		return savedConfig{}, err
	}
	if config.SkillsDir, err = normalizeProjectPath(config.SkillsDir, projectRoot, projectPath, "skills_dir"); err != nil {
		return savedConfig{}, err
	}
	if config.ContextTokenizer, err = normalizeProjectPath(config.ContextTokenizer, projectRoot, projectPath, "context_tokenizer_path"); err != nil {
		return savedConfig{}, err
	}

	return config, nil
}

func validateMergedProjectConfig(config savedConfig, projectConfig savedConfig, projectRoot string, projectPath string) error {
	if projectChangesToolSurface(projectConfig) && strings.TrimSpace(config.ToolApproval) == "full-access" {
		return fmt.Errorf("project TUI config %s must not inherit full-access tool approval; set tool_approval_mode to ask-before-write, auto-approved-safe, or read-only", projectPath)
	}

	if projectChangesFilesystemToolSurface(projectConfig) &&
		strings.TrimSpace(config.ToolRoot) != "" &&
		!pathWithin(projectRoot, config.ToolRoot) {
		return fmt.Errorf("project TUI config %s must not combine project tool settings with tool_root outside project root %s, got %s", projectPath, projectRoot, config.ToolRoot)
	}

	return nil
}

func projectChangesToolSurface(config savedConfig) bool {
	return strings.TrimSpace(config.ToolHarness) != "" ||
		strings.TrimSpace(config.ToolRoot) != "" ||
		strings.TrimSpace(config.MCPConfig) != "" ||
		len(config.TestCommands) > 0
}

func projectChangesFilesystemToolSurface(config savedConfig) bool {
	return strings.TrimSpace(config.ToolHarness) != "" ||
		strings.TrimSpace(config.ToolRoot) != "" ||
		len(config.TestCommands) > 0
}

func normalizeProjectPath(value string, projectRoot string, projectPath string, field string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", nil
	}

	resolved := value
	if !filepath.IsAbs(resolved) {
		resolved = filepath.Join(projectRoot, resolved)
	}
	resolved = filepath.Clean(resolved)

	if !pathWithin(projectRoot, resolved) {
		return "", fmt.Errorf("project TUI config %s field %s must stay inside project root %s, got %s", projectPath, field, projectRoot, resolved)
	}

	return resolved, nil
}

func pathWithin(root string, path string) bool {
	root = filepath.Clean(root)
	path = filepath.Clean(path)
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)))
}

func overlaySavedConfig(base savedConfig, override savedConfig) savedConfig {
	overlayString(&base.Workflow, override.Workflow)
	overlayString(&base.Provider, override.Provider)
	overlayString(&base.OpenAIModel, override.OpenAIModel)
	overlayString(&base.OpenRouterModel, override.OpenRouterModel)
	overlayString(&base.Theme, override.Theme)
	overlayString(&base.ToolHarness, override.ToolHarness)
	overlayString(&base.ToolRoot, override.ToolRoot)
	overlayString(&base.ToolTimeout, override.ToolTimeout)
	overlayString(&base.ToolMaxRounds, override.ToolMaxRounds)
	overlayString(&base.ToolApproval, override.ToolApproval)
	overlayStrings(&base.TestCommands, override.TestCommands)
	overlayString(&base.MCPConfig, override.MCPConfig)
	overlayString(&base.AgenticPersistenceRounds, override.AgenticPersistenceRounds)
	overlayString(&base.AgenticPersistenceMaxSteps, override.AgenticPersistenceMaxSteps)
	overlayString(&base.AgenticPersistenceTimeout, override.AgenticPersistenceTimeout)
	overlayString(&base.RouterMode, override.RouterMode)
	overlayString(&base.RouterModelDir, override.RouterModelDir)
	overlayString(&base.RouterTimeout, override.RouterTimeout)
	overlayString(&base.RouterConfidence, override.RouterConfidence)
	overlayString(&base.SkillsMode, override.SkillsMode)
	overlayString(&base.SkillsDir, override.SkillsDir)
	overlayStrings(&base.SkillNames, override.SkillNames)
	if override.AllowSkillScripts {
		base.AllowSkillScripts = true
	}
	overlayString(&base.ContextWindow, override.ContextWindow)
	overlayString(&base.ContextWarning, override.ContextWarning)
	overlayString(&base.ContextTokenizer, override.ContextTokenizer)
	overlayString(&base.ReservedOutput, override.ReservedOutput)
	overlayString(&base.RunContextCompact, override.RunContextCompact)
	overlayString(&base.ContextCompactPct, override.ContextCompactPct)
	overlayString(&base.MaxContextCompact, override.MaxContextCompact)
	if override.ProgressObserver {
		base.ProgressObserver = true
	}
	return base
}

func overlayString(target *string, value string) {
	if strings.TrimSpace(value) != "" {
		*target = value
	}
}

func overlayStrings(target *[]string, values []string) {
	if len(values) > 0 {
		*target = append([]string(nil), values...)
	}
}

func pathExists(path string) (bool, error) {
	if strings.TrimSpace(path) == "" {
		return false, nil
	}
	_, err := os.Stat(path)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return false, fmt.Errorf("failed to inspect config path %s: %w", path, err)
}

func loadSavedConfig(path string) (savedConfig, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return savedConfig{}, nil
	}
	if err != nil {
		return savedConfig{}, fmt.Errorf("failed to read TUI config %s: %w", path, err)
	}

	var config savedConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return savedConfig{}, fmt.Errorf("failed to parse TUI config %s: %w", path, err)
	}
	return config, nil
}

func defaultRouterModelDir(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "router-models", defaultRouterModelDirName)
}

func defaultSkillsDir() (string, error) {
	home := strings.TrimSpace(os.Getenv("HOME"))
	if home == "" {
		return "", errors.New("HOME is required to locate ~/.agent-machine/skills")
	}
	return filepath.Join(home, userConfigDirName, "skills"), nil
}

func initializeDefaultSkillsDir(config *savedConfig) (bool, error) {
	if strings.TrimSpace(config.SkillsDir) != "" {
		return false, nil
	}

	dir, err := defaultSkillsDir()
	if err != nil {
		return false, err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return false, fmt.Errorf("failed to create default skills directory %s: %w", dir, err)
	}

	config.SkillsDir = dir
	return true, nil
}

func migrateLegacyLocalRouterDefault(config *savedConfig, configPath string) bool {
	if strings.TrimSpace(config.RouterMode) != "local" {
		return false
	}
	if filepath.Clean(strings.TrimSpace(config.RouterModelDir)) != filepath.Clean(defaultRouterModelDir(configPath)) {
		return false
	}
	if strings.TrimSpace(config.RouterTimeout) != defaultRouterTimeoutMS {
		return false
	}
	if strings.TrimSpace(config.RouterConfidence) != defaultRouterConfidence {
		return false
	}

	config.RouterMode = ""
	config.RouterModelDir = ""
	config.RouterTimeout = ""
	config.RouterConfidence = ""
	return true
}

func saveSavedConfig(path string, config savedConfig) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("failed to create TUI config directory: %w", err)
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to encode TUI config: %w", err)
	}

	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("failed to write TUI config %s: %w", path, err)
	}

	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("failed to restrict TUI config permissions %s: %w", path, err)
	}
	return nil
}
