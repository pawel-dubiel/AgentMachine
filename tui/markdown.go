package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/glamour"
	glamouransi "github.com/charmbracelet/glamour/ansi"
)

var markdownRenderers = map[int]*glamour.TermRenderer{}

func renderMarkdownText(text string, width int) (string, error) {
	if width <= 0 {
		return "", fmt.Errorf("markdown render width must be positive")
	}
	if text == "" {
		return "", nil
	}

	renderer, err := markdownRenderer(width)
	if err != nil {
		return "", err
	}

	rendered, err := renderer.Render(text)
	if err != nil {
		return "", fmt.Errorf("render markdown: %w", err)
	}

	return strings.Trim(rendered, "\n"), nil
}

func renderMarkdownDisplay(text string, width int) string {
	rendered, err := renderMarkdownText(text, width)
	if err != nil {
		return errorStyle.Render("markdown render error: " + err.Error())
	}
	return rendered
}

func markdownRenderer(width int) (*glamour.TermRenderer, error) {
	if renderer, ok := markdownRenderers[width]; ok {
		return renderer, nil
	}

	renderer, err := glamour.NewTermRenderer(
		glamour.WithStyles(tuiMarkdownStyle()),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return nil, fmt.Errorf("create markdown renderer: %w", err)
	}

	markdownRenderers[width] = renderer
	return renderer, nil
}

func tuiMarkdownStyle() glamouransi.StyleConfig {
	return glamouransi.StyleConfig{
		Document: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color: stringPtr("252"),
			},
		},
		BlockQuote: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color:  stringPtr("244"),
				Italic: boolPtr(true),
			},
			Indent:      uintPtr(1),
			IndentToken: stringPtr("> "),
		},
		List: glamouransi.StyleList{
			LevelIndent: 2,
		},
		Heading: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				BlockSuffix: "\n",
				Color:       stringPtr("81"),
				Bold:        boolPtr(true),
			},
		},
		H2: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color: stringPtr("75"),
			},
		},
		H3: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color: stringPtr("110"),
			},
		},
		Strong: glamouransi.StylePrimitive{
			Bold: boolPtr(true),
		},
		Emph: glamouransi.StylePrimitive{
			Italic: boolPtr(true),
		},
		HorizontalRule: glamouransi.StylePrimitive{
			Color:  stringPtr("240"),
			Format: "\n--------\n",
		},
		Item: glamouransi.StylePrimitive{
			BlockPrefix: "- ",
		},
		Enumeration: glamouransi.StylePrimitive{
			BlockPrefix: ". ",
		},
		Task: glamouransi.StyleTask{
			Ticked:   "[x] ",
			Unticked: "[ ] ",
		},
		Link: glamouransi.StylePrimitive{
			Color:     stringPtr("75"),
			Underline: boolPtr(true),
		},
		LinkText: glamouransi.StylePrimitive{
			Color: stringPtr("75"),
			Bold:  boolPtr(true),
		},
		Code: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Prefix:          " ",
				Suffix:          " ",
				Color:           stringPtr("214"),
				BackgroundColor: stringPtr("236"),
			},
		},
		CodeBlock: glamouransi.StyleCodeBlock{
			StyleBlock: glamouransi.StyleBlock{
				StylePrimitive: glamouransi.StylePrimitive{
					Color: stringPtr("248"),
				},
			},
			Chroma: &glamouransi.Chroma{
				Text: glamouransi.StylePrimitive{
					Color: stringPtr("248"),
				},
				Comment: glamouransi.StylePrimitive{
					Color:  stringPtr("244"),
					Italic: boolPtr(true),
				},
				Keyword: glamouransi.StylePrimitive{
					Color: stringPtr("75"),
					Bold:  boolPtr(true),
				},
				LiteralString: glamouransi.StylePrimitive{
					Color: stringPtr("114"),
				},
				LiteralNumber: glamouransi.StylePrimitive{
					Color: stringPtr("209"),
				},
			},
		},
		Table: glamouransi.StyleTable{
			CenterSeparator: stringPtr("|"),
			ColumnSeparator: stringPtr("|"),
			RowSeparator:    stringPtr("-"),
		},
	}
}

func stringPtr(value string) *string {
	return &value
}

func boolPtr(value bool) *bool {
	return &value
}

func uintPtr(value uint) *uint {
	return &value
}
