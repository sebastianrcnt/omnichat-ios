# Interactive views (OpenUI Lang)

An answer can contain a fenced block tagged `openui` (or `openui-lang`, OpenUI's own tag). The app draws it as
native SwiftUI in place of a code block. Only the language comes from OpenUI. There is no web view and no React.

- Language: [OpenUI Lang 1.0](https://github.com/thesysdev/openui), `spec/` at 9823ec0 (2026-10-19).
- License: MIT, "Copyright (c) 2011-2024 Thesys Inc."
- No OpenUI code is included. Prop orders follow its generated library specs (`docs/generated/*-library.spec.json`), so
  programs written from its docs work. The parser's behaviour follows `spec/fixtures/1.0`, and
  `StrataTests/OpenUILangTests.swift` ports the relevant fixtures.

## Files

| File | What it does |
| --- | --- |
| `OpenUILang.swift` | Lexer, lenient Pratt parser, statement splitter and the incremental `OUIStreamParser`. |
| `OpenUIEvaluator.swift` | Values, the component library (`OUILibrary.omniChat`), and the evaluator. The evaluator handles references, `$state`, `@` builtins and actions. |
| `OpenUIRuntime.swift` | Per-view state, fields, validation, actions turned into the follow-up message, saved state on `Message`, and plain text for Copy. |
| `OpenUIBlockView.swift` | The block view, the host environment (`OpenUIHost`), the failure note and source sheet, and dispatch by type. |
| `OpenUIViews.swift`, `OpenUICharts.swift`, `OpenUIControls.swift` | The component views. |
| `OpenUIPrompt.swift` | Fence detection and `AppPrompt.views`. |

## Language support

These parts of the spec are supported:

- Statements `name = expr`, one per line. A line continues while brackets are open or a ternary is open.
- Comments with `//` and `#`.
- Double-quoted strings with JSON escapes; single-quoted strings with `\'`, `\\`, `\n` and `\t`.
- Numbers, including the spec's rule for when `-` belongs to a number.
- `true`, `false`, `null`, lists and objects. Object keys can be names, strings, numbers or `$names`.
- Operators: ternary, `||`, `&&`, `==`/`!=`, comparisons, arithmetic, unary operators, `.field` (which plucks over
  lists), `[index]` and `.length`. Coercions follow the fixtures.
- The entry is `root`. Without it, the first statement that calls a root component (`Card` or `Stack`) is the entry.
  Statements can come in any order, and a later definition wins. A reference that isn't defined yet is left out of
  lists. A reference cycle ends instead of looping.
- `$state` variables have defaults and two-way bindings on `value`.
- Builtins: `@Count`, `@First`, `@Last`, `@Sum`, `@Avg`, `@Min`, `@Max`, `@Filter`, `@Sort`, `@Round`, `@Abs`,
  `@Floor`, `@Ceil` and `@Each`.
- Actions: `@ToAssistant(message, context)`, `@OpenUrl`, `@Set`, `@Reset`, `@Run` (ignored) and `Action([...])`.
- `Query(tool, args, defaults)` evaluates to its defaults, and `Mutation` evaluates to `{status: "idle"}`, because a
  chat runs no tools from a view.
- Named arguments (`label: value`) are accepted in calls, which goes beyond the spec.

The parser tolerates errors:

- A statement that doesn't parse is skipped, and the rest still renders.
- A line of plain prose isn't counted as a problem.
- An unknown component renders its first text argument plus any components passed to it, and is reported. It never
  crashes.
- An unknown function evaluates to `null`.
- Extra positional arguments are dropped.

## Components

Arguments are positional in the order below. You can also pass them by name.

| Kind | Components and props |
| --- | --- |
| Layout | `Card(children, variant: card/sunk/clear, direction, gap, align, justify, wrap)`<br>`Stack(children, direction: row/column, gap, align, justify, wrap)`<br>`Separator(orientation)`<br>`Tabs(items)` with `TabItem(value, trigger, content)`<br>`Accordion(items)` with `AccordionItem(value, trigger, content)`<br>`SectionBlock(sections, isFoldable)` with `SectionItem`<br>`Steps(items)` with `StepsItem(title, details)`<br>`Carousel(children)` |
| Text | `CardHeader(title, subtitle)`<br>`InlineHeader(heading, description)`<br>`TextContent(text, size: small/small-heavy/default/large/large-heavy)` (inline Markdown)<br>`MarkDownRenderer(textMarkdown)`<br>`Callout(variant, title, description)`<br>`TextCallout`<br>`Tag(text, icon, size, variant)`<br>`TagBlock(tags)`<br>`Label(text)`<br>`CodeBlock(language, codeString)`<br>`Icon(name)` (Lucide names mapped to SF Symbols) |
| Data | `Table(columns)` with `Col(label, data, type)`<br>`EntityList(rows, size, header, footer)` with rows `{left, right}`<br>`ListBlock(items, variant: number)` with `ListItem(title, subtitle, image, actionLabel, action)`<br>`Metric(label, value, change, caption)`<br>`MetricIndicatorInline(value, subtext, trend)`<br>`MetricIndicatorWithStrikethrough(value, subtext, previousValue, trend)`<br>`Progress(label, value, max)` |
| Charts (Swift Charts) | `BarChart`, `LineChart`, `AreaChart` and `HorizontalBarChart(labels, series, variant, xLabel, yLabel, height)` with `Series(category, values)`. The variant is grouped/stacked for bars and linear/natural/step for lines.<br>`PieChart(labels, values, variant: pie/donut)`<br>`RadialChart` (drawn as a donut)<br>`SingleStackedBarChart(labels, values)`<br>`RadarChart` (drawn as bars)<br>`ScatterChart(datasets, xLabel, yLabel)` with `ScatterSeries(name, points)` and `Point(x, y)` |
| Media | `Image(alt, src)`<br>`ImageBlock(src, alt)`<br>`ImageGallery(images)` |
| Actions | `Button(label, action, variant: primary/secondary/tertiary)`<br>`Buttons(buttons, direction)`<br>`IconButton(name, icon, action)`<br>`Link(label, url)` (opens in the in-app browser)<br>`FollowUpBlock(items)` with `FollowUpItem(text)` |
| Forms | `Form(name, buttons, fields)`<br>`FormControl(label, input, hint)`<br>`Input(name, placeholder, type, rules, value)`<br>`TextArea(name, placeholder, rows)`<br>`Select(name, items, placeholder)` with `SelectItem(value, label)`<br>`RadioGroup(name, items, defaultValue)` with `RadioItem(label, description, value)`<br>`CheckBoxGroup(name, items)` with `CheckBoxItem(label, description, name, defaultChecked)`<br>`SwitchGroup` with `SwitchItem`<br>`Chips(name, single/multiple, items)` with `ChipItem(value, label)`<br>`Slider(name, continuous/discrete, min, max, step, defaultValue)`<br>`DatePicker(name, single/range)` |

Aliases: `Header` → `CardHeader`, `Divider` → `Separator`, `Badge` → `Tag`.

Form `rules`: `required`, `email`, `url`, `numeric`, `min`, `max`, `minLength`, `maxLength` and `pattern`.

## Streaming

`OpenUIBlockView` feeds the block's text so far to the view's `OUIRuntime`. The runtime keeps one `OUIStreamParser`
per message and block.

- A statement counts as complete at a newline outside brackets, strings and an open ternary, once the next non-blank
  character has arrived and isn't `?`. Completed statements are parsed once and don't change.
- While the block streams, only completed statements are evaluated, so a component appears once its line is
  complete.
- A reference that isn't defined yet renders nothing.
- Until the root has something to show, a small "Preparing view…" placeholder stands in. This avoids an empty card.
- When the fence closes, or the message ends (including when it is stopped), the pending tail is parsed as well.
- If anything didn't parse, the parts that did are shown, with a quiet "Part of this view couldn't be shown." If
  nothing parsed, the note reads "Couldn't show this view." Either way, a "View source" link opens the program.

## Actions

| What the person does | What is sent |
| --- | --- |
| Presses a button with no action | The button's label is sent as the next user message (OpenUI's default). |
| Presses a button with `@ToAssistant("text", context)` | The text is sent. The context follows as `- key: value` lines. |
| Presses a button inside a `Form` | The form's fields are validated first. The message then carries one `- Label: value` line per filled field. Values are written as the person sees them: option labels, checked boxes and date ranges. |
| Picks a `RadioGroup`, `Select` or `Chips` value outside a form | The choice is sent at once, but only when the page has nothing else to press. |
| Taps a `FollowUpItem` or a `ListItem` with an action | The item's text is sent. |
| Uses `@Set` / `@Reset` | `$state` changes, and the view redraws. Nothing is sent. |
| Uses `@OpenUrl` or `Link` | The link opens in the in-app browser. Nothing is sent, and links work even in a locked view. |

When a view sends, `ChatView` does three things:

1. It saves `OUISavedState` (label, form, field values, state) in `Message.openUIStateData`, a JSON map keyed by the
   block's position in the answer. This is an optional field with a `nil` default, so the migration is lightweight.
2. It sends the follow-up into the same chat.
3. It scrolls to the new question.

Controls work only on the latest message while no reply is running. Older views are disabled, show the saved values,
and mark the pressed button.

## Prompt and toggle

`ToolGroup.views` is a tool group without tools.

- When the group is on, `AppPrompt.text(…, views: true)` appends `AppPrompt.views` at the end of the system prompt.
  The section is about 3.5k characters (420 words), roughly 900–1,000 tokens.
- The group is frozen at the chat's first send, like the other groups. Turning it off later keeps the prompt
  byte-identical and adds the note `[Interactive views: off]`.
- Settings › Tools › "Interactive views in new chats" sets the default. It is on by default.

## Copy and translation

- **Copy:** `MarkdownPlain.text` replaces each view with `OUIPlainText`, which is what the view shows:
  - headings and text
  - table rows as `a | b`
  - `label: value` pairs
  - chart data

  Controls are left out.
- **Translation:** `TranslationPlan` keeps fenced code literal, so a view's program never reaches the translator and
  stays byte-identical.

## Debug gallery

Launch with `-StrataOpenUIGallery N` (DEBUG builds), where N is 1–6. Each page shows sample views:

| N | Page |
| --- | --- |
| 1 | Comparison |
| 2 | Dashboard |
| 3 | Form |
| 4 | Choices and a locked view |
| 5 | A simulated stream |
| 6 | Tabs and broken programs |

Options:

- `-StrataOpenUIGalleryDark 1` forces dark mode.
- `-StrataOpenUIGallerySnapshot name` writes `tmp/name.png` into the app's container after a short delay.
- `-StrataOpenUIGalleryStop n` holds the stream at n characters.
