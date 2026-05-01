package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

type tuiTheme string

const (
	themeClassic tuiTheme = "classic"
	themeMatrix  tuiTheme = "matrix"
)

type tuiThemeStyles struct {
	Title  lipgloss.Style
	Label  lipgloss.Style
	Error  lipgloss.Style
	Hint   lipgloss.Style
	Signal lipgloss.Style
	Border lipgloss.Color
}

func parseTUITheme(value string) (tuiTheme, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case string(themeClassic):
		return themeClassic, nil
	case string(themeMatrix):
		return themeMatrix, nil
	case "":
		return "", fmt.Errorf("TUI theme is required (available: %s)", themeOptionsText())
	default:
		return "", fmt.Errorf("unsupported TUI theme %q (available: %s)", value, themeOptionsText())
	}
}

func themeOptionsText() string {
	return "classic|matrix"
}

func savedTUITheme(config savedConfig) (tuiTheme, error) {
	if strings.TrimSpace(config.Theme) == "" {
		return themeClassic, nil
	}
	return parseTUITheme(config.Theme)
}

func (m model) activeTheme() tuiTheme {
	switch m.theme {
	case themeClassic, themeMatrix:
		return m.theme
	default:
		return themeClassic
	}
}

func (m model) styles() tuiThemeStyles {
	return stylesForTheme(m.activeTheme())
}

func stylesForTheme(theme tuiTheme) tuiThemeStyles {
	switch theme {
	case themeMatrix:
		return tuiThemeStyles{
			Title:  lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("46")),
			Label:  lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("120")),
			Error:  lipgloss.NewStyle().Foreground(lipgloss.Color("196")),
			Hint:   lipgloss.NewStyle().Foreground(lipgloss.Color("34")),
			Signal: lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("46")),
			Border: lipgloss.Color("22"),
		}
	default:
		return tuiThemeStyles{
			Title:  lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("63")),
			Label:  lipgloss.NewStyle().Bold(true),
			Error:  lipgloss.NewStyle().Foreground(lipgloss.Color("9")),
			Hint:   lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
			Signal: lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
			Border: lipgloss.Color("240"),
		}
	}
}

func hintTextForTheme(theme tuiTheme, text string) string {
	return stylesForTheme(theme).Hint.Render(text)
}

var (
	titleStyle = stylesForTheme(themeClassic).Title
	labelStyle = stylesForTheme(themeClassic).Label
	errorStyle = stylesForTheme(themeClassic).Error
	hintStyle  = stylesForTheme(themeClassic).Hint
)
