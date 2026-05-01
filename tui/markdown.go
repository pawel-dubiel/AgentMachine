package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/glamour"
	glamouransi "github.com/charmbracelet/glamour/ansi"
)

type markdownRendererKey struct {
	Width int
	Theme tuiTheme
}

var markdownRenderers = map[markdownRendererKey]*glamour.TermRenderer{}

func renderMarkdownText(text string, width int) (string, error) {
	return renderMarkdownTextWithTheme(text, width, themeClassic)
}

func renderMarkdownTextWithTheme(text string, width int, theme tuiTheme) (string, error) {
	if width <= 0 {
		return "", fmt.Errorf("markdown render width must be positive")
	}
	if text == "" {
		return "", nil
	}

	renderer, err := markdownRendererForTheme(width, theme)
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
	return renderMarkdownDisplayWithTheme(text, width, themeClassic)
}

func renderMarkdownDisplayWithTheme(text string, width int, theme tuiTheme) string {
	rendered, err := renderMarkdownTextWithTheme(text, width, theme)
	if err != nil {
		return stylesForTheme(theme).Error.Render("markdown render error: " + err.Error())
	}
	return rendered
}

func markdownRenderer(width int) (*glamour.TermRenderer, error) {
	return markdownRendererForTheme(width, themeClassic)
}

func markdownRendererForTheme(width int, theme tuiTheme) (*glamour.TermRenderer, error) {
	key := markdownRendererKey{Width: width, Theme: theme}
	if renderer, ok := markdownRenderers[key]; ok {
		return renderer, nil
	}

	renderer, err := glamour.NewTermRenderer(
		glamour.WithStyles(tuiMarkdownStyleForTheme(theme)),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return nil, fmt.Errorf("create markdown renderer: %w", err)
	}

	markdownRenderers[key] = renderer
	return renderer, nil
}

func tuiMarkdownStyle() glamouransi.StyleConfig {
	return tuiMarkdownStyleForTheme(themeClassic)
}

func tuiMarkdownStyleForTheme(theme tuiTheme) glamouransi.StyleConfig {
	if theme == themeMatrix {
		return tuiMatrixMarkdownStyle()
	}
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
					Color: stringPtr("#bcbcbc"),
				},
				Comment: glamouransi.StylePrimitive{
					Color:  stringPtr("#808080"),
					Italic: boolPtr(true),
				},
				Keyword: glamouransi.StylePrimitive{
					Color: stringPtr("#5fafff"),
					Bold:  boolPtr(true),
				},
				LiteralString: glamouransi.StylePrimitive{
					Color: stringPtr("#87d787"),
				},
				LiteralNumber: glamouransi.StylePrimitive{
					Color: stringPtr("#ff875f"),
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

func tuiMatrixMarkdownStyle() glamouransi.StyleConfig {
	return glamouransi.StyleConfig{
		Document: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color: stringPtr("120"),
			},
		},
		BlockQuote: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color:  stringPtr("34"),
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
				Color:       stringPtr("46"),
				Bold:        boolPtr(true),
			},
		},
		H2: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color: stringPtr("82"),
			},
		},
		H3: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Color: stringPtr("120"),
			},
		},
		Strong: glamouransi.StylePrimitive{
			Bold:  boolPtr(true),
			Color: stringPtr("46"),
		},
		Emph: glamouransi.StylePrimitive{
			Italic: boolPtr(true),
			Color:  stringPtr("34"),
		},
		HorizontalRule: glamouransi.StylePrimitive{
			Color:  stringPtr("22"),
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
			Color:     stringPtr("46"),
			Underline: boolPtr(true),
		},
		LinkText: glamouransi.StylePrimitive{
			Color: stringPtr("46"),
			Bold:  boolPtr(true),
		},
		Code: glamouransi.StyleBlock{
			StylePrimitive: glamouransi.StylePrimitive{
				Prefix:          " ",
				Suffix:          " ",
				Color:           stringPtr("46"),
				BackgroundColor: stringPtr("22"),
			},
		},
		CodeBlock: glamouransi.StyleCodeBlock{
			StyleBlock: glamouransi.StyleBlock{
				StylePrimitive: glamouransi.StylePrimitive{
					Color: stringPtr("120"),
				},
			},
			Chroma: &glamouransi.Chroma{
				Text: glamouransi.StylePrimitive{
					Color: stringPtr("#87ff87"),
				},
				Comment: glamouransi.StylePrimitive{
					Color:  stringPtr("#00af00"),
					Italic: boolPtr(true),
				},
				Keyword: glamouransi.StylePrimitive{
					Color: stringPtr("#00ff00"),
					Bold:  boolPtr(true),
				},
				LiteralString: glamouransi.StylePrimitive{
					Color: stringPtr("#5fff00"),
				},
				LiteralNumber: glamouransi.StylePrimitive{
					Color: stringPtr("#87ff00"),
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
