# DesignSystem

Tokens and reusable components. Feature views (`UI/`) compose these and never hardcode colors, fonts,
paddings, radii or animations. Liquid Glass is used on controls only (buttons, the composer, chips in the
composer); content (messages, rows, sheets) is flat.

Every component file ends with `#Preview`s: **Light · Purple**, **Dark · Purple** and **Dark · Orange**
(the default accent and a second one, so accent-derived colors are checked). Components that need data
use inline sample data, never the network.

## Tokens (`Tokens.swift`)

| Group | Names |
| --- | --- |
| `DS.Spacing` | `xxs 2`, `xs 4`, `sm 8`, `md 12`, `lg 16`, `xl 24`, `xxl 32`, `page 16`, `composerClearance 150` |
| `DS.Radius` | `sm 8`, `md 14`, `lg 20`, `xl 28`, `bubble 22`, `thumbnail 12`, `composer 26` |
| `DS.IconSize` | `sm 14`, `md 18`, `lg 22`, `controlDiameter 44`, `headerIcon 17`, `compactControlDiameter 36`, `composerIcon 16`, `minHitTarget 44`, `ring 22`, `ringStroke 3`, `favicon 16`, `thumbnail 64`, `cameraTile 112` |
| `DS.Typography` | `answer` / `answerEmphasis` (serif), `answerLineSpacing 3`, `ui`, `uiEmphasis`, `uiSmall`, `uiCaption`, `chip`, `monogram`, `sectionHeader`, `title`, `largeTitle`, `mono`, `monoSmall` |
| `DS.Feed` | `iconColumn 18`, `iconGap 8`, `textInset 26`, `icon 13`, `mark 10`, `markColumn 12`, `lineHeight 28`, `stepSpacing 6`, `liveWidth 116`, `liveHeight 150`, `liveDot 6` |
| `DS.Motion` | `fast 0.15`, `standard 0.25`, `slow 0.4`, `spring`, `snappy`, `ease`, `indicatorPulse` |
| `DSTheme` (environment `\.theme`) | accent roles `accent`, `accentMuted`, `accentStrong`, `accentOnTint`; surfaces `background`, `surface`, `surfaceRaised`, `bubble`, `separator`, `chipFill`, `fillTertiary`; text `textPrimary`, `textSecondary`, `textTertiary`; status `destructive`, `warning`, `live` (the feed's LIVE dot); fixed `onAccent`, `photoBadgeBackdrop`, `faviconBackdrop` |

Colors adapt to light and dark through `Color(light:dark:)`. The accent is user-selected (Settings) and
flows through `DSTheme(accent:)`; `accentOnTint` is the accent re-balanced to read on `accentMuted`.
`previewStyle(_:accent:)` applies scheme, accent and themed background in previews.

## Components

| File | Components |
| --- | --- |
| `Buttons.swift` | `GlassIconButton`, `GlassIconMenu`, `GlassIconMenuPlain`, `StreamingIndicator`, `ContextRing`, `ContextRingButton`, `AttachmentThumbnail`, `QuietLinkButtonStyle` (`.quietLink`, `.quietLink(.accent)`: text links with no chrome and a 44 pt hit target) |
| `Composer.swift` | `ComposerBar` (always two rows: text field, then attach, the settings accessory, mic, send/stop; dictation in place), `ModelSettingsButton` (the model-and-effort chip), `ComposerAttachment`, `ComposerToolSwitch` (with switches, plus is a menu: Add photos, then the chat's tool toggles) |
| `Dictation.swift` | `DictationWaveform` (static with Reduce Motion), `DictationElapsed`, `DictationStatusLine` (preparing, failures with a Settings link), `DictationConfirmButton`; the state machine and on-device engine live in `Dictation/` |
| `Messages.swift` | `MessageBubble`, `AssistantMessage` (+ `AssistantContent`), `MessageActionBar`, the MarkdownUI `Theme` for tables and complex blocks |
| `ProcessSegments.swift` | `ThinkingCard`, `ActivityCard`, `LiveThinkingTail`, `LiveToolsTail`, `ProcessDivider` |
| `ActivityFeedViews.swift` | `ThoughtLine`, `FeedLine` / `FeedSymbol` / `FeedSpinner` (the feed's quiet line: icon in `DS.Feed.iconColumn`, text at `DS.Feed.textInset`), `ActivityFeedView`, `FeedCardView`, `FeedRowView` |
| `BrowserViews.swift` | `BrowserRun` (grouping), `BrowserRunView` ("Browsing host ›" + steps), `BrowserStep`, `BrowserLivePreview` / `BrowserLiveStrip` (portrait live view + Watch / Take over / Stop browsing links), `KeptPageLink`, `SessionPageLink` (after the reply: "Open page ›" for the frozen session page, or "Page closed · Reopen"), `RobotCheckPrompt` |
| `Activity.swift` | `SourceChip`, `FaviconView`, `ActivityRow`, `ActivityStatusLine`, `ActivitySummaryRow`, `TimelineSheet`, `SourcesRow`, `SourceCard`, `SourcesSheet`, `FlowLayout`, `TrailingFade` |
| `CodeBlocks.swift` | `CodeBlockView` (collapse, copy, expand), `CodeViewer` (full screen, pinch zoom, wrap, share) |
| `SyntaxText.swift` | `DSTheme.syntax(_:)`, `HighlightedCode`, `SyntaxText.build`, `HighlightService` (highlight.js runs off the main thread; palette in `Syntax/SyntaxTokens.swift`) |
| `CompactionViews.swift` | `CompactionDivider`, `CompactionStatusRow`, `CompactionNotesSheet` |
| `Messages.swift` (translation) | `TranslationBanner` ("Translated · Show original"), translate action in `MessageActionBar`, long-press menu on translatable answers; logic in `Translation/` |
| `Sheets.swift` | `SheetScaffold`, `GroupedSection`, `SettingsRow`, `SettingsToggleRow`, `SettingsFieldRow`, `UsageCard` |
| `ArtifactGalleryViews.swift` | `ArtifactThumbnail` (cached page snapshot, placeholder while rendering), `ArtifactGridCard`, `ArtifactListRow`; thumbnails come from `Tools/ArtifactThumbnails.swift`, the screen is `UI/ArtifactsView.swift` |

Streaming Markdown rendering lives in `Rendering/StreamingMarkdown` (see its README); the design system
only styles it.

## Rules

- Control sizes: header buttons are 44 pt circles about 8 pt apart; composer controls are 36 pt; hit
  targets stay at least 44 pt through `contentShape`.
- Text over scrolling content gets a soft scroll-edge effect (`scrollEdgeEffectStyle(.soft)`), not a hard
  divider.
- Reduce Motion: the reveal fade, tail fades and row expansion animations are skipped.
- Dynamic Type: use the `DS.Typography` roles (text styles), not fixed point sizes. Fixed sizes exist only
  for icons (`DS.IconSize`) and the monogram disc.
- Localization: user-visible strings are `LocalizedStringKey` / `String(localized:)`; run
  `python3 Tools/sync_strings.py` after a build to refresh `Localizable.xcstrings`.

## Hardcoded-value audit

Checked with `grep` over `DesignSystem/`, `UI/` and `Rendering/` for color literals, `font(.system(size:)`
and numeric `padding`/`cornerRadius`. Remaining literals are deliberate:

- `Color.black` / `.clear` in `TrailingFade` and the sidebar dimming: these are alpha masks or shadows,
  not theme colors.
- `Spacing: 0` in stacks (no gap by design) and `.frame` sizes derived from tokens.
- `SettingsFieldRow` label `minWidth: 84` aligns field columns.
- Icon `font(.system(size: DS.IconSize.*))` uses the icon tokens above.

## Typography

All text roles in `DS.Typography` are Pretendard (variable font, `Resources/Fonts`, pinned in its README); only `mono` and
`monoSmall` stay SF Mono. Line height comes from `DS.Leading` (answer 1.65, thinking/timeline 1.55, UI 1.4), turned into a
line spacing from the font's own metrics at the size on screen: use `.dsLeading(.answer)` instead of `.lineSpacing`.
Space between answer blocks is `DS.blockSpacing`.

Text size: Settings > Appearance can force one of seven Dynamic Type sizes (`TextSizeSetting`); the override is applied by
`TextSizeOverride` at the root (environment plus a trait override on the windows, so sheets follow). MarkdownUI sizes and
the code viewer scale with `DS.typeScale(_:)`.
