# UI Shell and Design System

SwiftUI only, macOS 26 Liquid Glass. Black and white. No custom blur, no fake glass, no images for chrome.

## Design Tokens
- Accent: `AccentColor` asset, black in Light, white in Dark. Set `.tint(.primary)` at the root
- Palette: `.primary`, `.secondary`, `.tertiary`, `.quaternary` foreground styles only. No hue anywhere except the system destructive role on Move to Trash buttons
- Appearance setting: System (default), Light, Dark via `.preferredColorScheme`
- Typography: system font. Large numbers use `.font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit()`. Paths use `.monospaced()` caption
- Sizes formatted with `ByteCountFormatter` `.file` style. Dates relative (`.relative(presentation: .named)`) with absolute in tooltip
- Spacing scale: 4, 8, 12, 16, 24, 32. Corner radius for glass cards: `.rect(cornerRadius: 20)`
- Tier glyphs from `rules-engine.md`, always paired with the tier word for accessibility

## Liquid Glass Usage
| element | API |
|---|---|
| Sidebar | `NavigationSplitView` default (system floating glass sidebar) |
| Toolbar buttons | default toolbar glass, group with `ToolbarSpacer` |
| Primary Scan button | `.buttonStyle(.glassProminent)` |
| Secondary buttons | `.buttonStyle(.glass)` |
| Category cards on Overview | `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))` inside one `GlassEffectContainer(spacing: 16)` |
| Bottom action bar (selection) | floating `HStack` with `.glassEffect()`, appears with `glassEffectID` morph from the selection count chip |
| Scan HUD | `.glassEffect(.regular, in: .capsule)` overlay, morphs into the result toast via shared `glassEffectID` in a `@Namespace` |
| Inspector | `.inspector(isPresented:)` default styling |
| Treemap header and breadcrumb | `.backgroundExtensionEffect()` on the treemap so it flows under the toolbar |

Rules: never stack glass on glass (no glass card inside a glass card), wrap sibling glass shapes in `GlassEffectContainer`, respect Reduce Transparency and Increase Contrast (system fallback, verify visually).

## Window and Navigation
- Main window min size 960x620, default 1200x780, `.windowToolbarStyle(.unified)`
- `NavigationSplitView` sidebar sections:
  - **Overview**
  - **Clean**: Dev Caches, App Caches, Old and Large, Projects, Orphans, Duplicates
  - **Review**: Flagged, Quarantine
- Each sidebar item shows a trailing size badge (freeable total) after a scan
- Settings scene (`Settings { }`) with tabs, see `settings-permissions.md`
- `MenuBarExtra` scene, see `menu-bar.md`

## Screens

### Overview
- Hero: free space big number, below it a horizontal stacked bar (monochrome shades) of Used, Reclaimable (found), In quarantine, In Trash, Free. Legend with labels and sizes
- Scan button (glassProminent) with last scan time underneath. During scan the button turns into Cancel
- Category cards grid (2 or 3 columns adaptive): title, freeable size, item count, top 3 offenders. Click navigates to the section
- Treemap below the cards, takes remaining height

### Treemap
- Source: `dir_node` children of the current node, squarified layout drawn in a `Canvas`
- Fill: grayscale, lighter for bigger tiles, 1 pt separator lines
- Tiles containing candidates show an inner outline and the tier glyph when the tile is at least 60x40 pt
- Hover: tooltip with name, size, candidate count. Click a folder: drill down with breadcrumb. Option click: select the candidate in its list screen
- Max 300 tiles per level, rest merged into "Other"

### Category List Screens (Dev Caches, App Caches, Old and Large, Orphans)
- Filter bar (top, glass capsule): age slider "Unused for at least X days" with presets 30, 90, 180, 365 and a stepper, size slider "At least X" on a log scale 10 MB to 50 GB, tier toggle chips, search field. Filters apply live through `CandidateFilter`
- `Table` with sortable columns: checkbox, Name, Location (middle truncated), Will free, Last used, Tier, Group
- Default selection: green tier only
- Bottom glass action bar when selection is non empty: "Quarantine 12 items, 34.2 GB", secondary "Ignore" (adds to `ignored_path`)
- Context menu: Reveal in Finder, Quick Look, Copy Path, Ignore, Add to Never Touch
- Empty state: SF Symbol `sparkles` with "Nothing here above your thresholds"

### Projects, Duplicates, Flagged, Quarantine
See their feature docs. Same filter bar and action bar components.

### Inspector (right side, toggled with Cmd Option I)
- Name, full path (selectable, monospaced) as a path bar where each folder segment opens that folder in Finder, kind
- Rows and inspector header show the owning app's icon (`AppIconCache`, by `appBundleID`) when the app is installed; orphans keep a generic symbol
- Reveal in Finder selects existing items (packages as a whole) and falls back to the nearest existing ancestor; items in quarantine reveal their quarantine path
- Size block: Logical, On disk, Will free (explanation popover for the difference)
- Dates: Created, Modified, Last used
- Rule: tier glyph and word, reason sentence, rule id in tertiary text
- Buttons: Reveal in Finder, Quick Look, Copy CLI command (flagged only)

### Scan HUD
- Floating capsule bottom center: spinner, phase label, files count, bytes, current path (middle truncated), Cancel
- On finish morphs into a toast: "Found 82.4 GB in 1,204 items · 2 min 11 s" and a "Review" button

## View Model Layer
- One `@Observable @MainActor` model per screen in `App/Features/<Screen>/`
- `AppModel` holds services (injected from `AppEnvironment`), current session id, scan state, quarantine totals
- Views never call Core services directly

## Keyboard
| key | action |
|---|---|
| Cmd R | Start scan |
| Esc | Cancel scan or close sheet |
| Space | Quick Look selection |
| Cmd Delete | Quarantine selection (with confirm sheet) |
| Cmd Option I | Toggle inspector |
| Cmd 1..9 | Sidebar sections |

## Edge Cases
- No scan yet: every section shows a single Scan call to action
- Scan running and user quarantines: allowed only for candidates of the previous finished session, otherwise disabled with tooltip
- Lists with 50k rows: use `Table` (lazy), sort in SQL not in Swift
- Window too narrow: inspector collapses automatically
- Dry run mode: persistent "Dry run" capsule in the toolbar
