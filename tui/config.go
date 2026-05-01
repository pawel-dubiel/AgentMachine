package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

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
	if path := strings.TrimSpace(os.Getenv("AGENT_MACHINE_TUI_CONFIG")); path != "" {
		return path, nil
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("failed to locate user config directory: %w", err)
	}
	return filepath.Join(configDir, "agent-machine", "tui-config.json"), nil
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
