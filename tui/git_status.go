package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func gitBranchStatusForWorkingDir(workingDir string) string {
	cwd := strings.TrimSpace(workingDir)
	if cwd == "" {
		return "missing-cwd"
	}
	cwd = filepath.Clean(cwd)
	info, err := os.Stat(cwd)
	if err != nil {
		return "cwd-error"
	}
	if !info.IsDir() {
		return "cwd-not-dir"
	}

	branch, err := gitOutput(cwd, "branch", "--show-current")
	if err == nil && branch != "" {
		return branch
	}
	if isGitExecutableMissing(err) {
		return "git-missing"
	}

	inside, err := gitOutput(cwd, "rev-parse", "--is-inside-work-tree")
	if err != nil {
		if isGitExecutableMissing(err) {
			return "git-missing"
		}
		return "not-git"
	}
	if inside != "true" {
		return "not-git"
	}

	sha, err := gitOutput(cwd, "rev-parse", "--short", "HEAD")
	if err != nil {
		if isGitExecutableMissing(err) {
			return "git-missing"
		}
		return "error"
	}
	if sha == "" {
		return "detached:unknown"
	}
	return "detached:" + sha
}

func gitOutput(workingDir string, args ...string) (string, error) {
	commandArgs := append([]string{"-C", workingDir}, args...)
	cmd := exec.Command("git", commandArgs...)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func isGitExecutableMissing(err error) bool {
	if err == nil {
		return false
	}
	var pathErr *exec.Error
	return errors.As(err, &pathErr) && errors.Is(pathErr.Err, exec.ErrNotFound)
}
