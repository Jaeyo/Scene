import Foundation
import SceneThemes
import SceneFoundation

/// Renders an Obsidian CSS theme: one `theme.css` that sets Obsidian's public CSS variables in a `.theme-dark` and
/// a `.theme-light` block, and the `manifest.json` Obsidian needs to list it. Only variables, no rules for app
/// elements, so an Obsidian update cannot break the layout. Every value is a number Scene writes from `RGBA`.
public enum ObsidianRenderer {
    /// The theme's folder name, its manifest name, and the value of `cssTheme`. No community theme has it.
    public static let themeName = "Scene"
    static let selectors: [(Appearance, String)] = [(.dark, ".theme-dark"), (.light, ".theme-light")]
    /// Obsidian's gray scale from the background (`color-base-00`) to the text color (`color-base-100`), with how
    /// far each step is from the background. The steps are not even: these follow Obsidian's own dark and light
    /// scales, where 05 to 25 stay close to the background and 60 and 70 are close to the text.
    static let baseSteps: [(step: Int, amount: Double)] = [
        (0, 0), (5, 0.015), (10, 0.03), (20, 0.045), (25, 0.08), (30, 0.13),
        (35, 0.18), (40, 0.29), (50, 0.37), (60, 0.64), (70, 0.78), (100, 1),
    ]

    public static func manifest() -> Data {
        Data("""
        {
          "name": "\(themeName)",
          "version": "1.0.0",
          "minAppVersion": "1.0.0",
          "author": "Scene"
        }

        """.utf8)
    }

    /// Both blocks are always present. A look the theme lacks gets the other look's colors.
    public static func themeCSS(variants: [Appearance: ResolvedVariant]) throws -> String {
        guard let fallback = variants[.dark] ?? variants[.light] else { throw SceneError.invalid("no variant to render") }
        var css = "/* Written by Scene. Scene replaces this file at the next theme switch. */\n"
        for (appearance, selector) in selectors {
            css += "\n\(selector) {\n"
            for (name, value) in variables(variants[appearance] ?? fallback) { css += "  --\(name): \(value);\n" }
            css += "}\n"
        }
        return css
    }

    /// The value of `theme` in `appearance.json`: `system` when both looks are there, otherwise Obsidian's
    /// dark (`obsidian`) or light (`moonstone`) base for the one look.
    public static func baseTheme(variants: [Appearance: ResolvedVariant]) -> String {
        if variants.count > 1 { return "system" }
        return variants.values.first?.appearance == .light ? "moonstone" : "obsidian"
    }

    static func variables(_ v: ResolvedVariant) -> [(String, String)] {
        let ui = v.interface, t = v.terminal, s = v.syntax, bg = ui.background
        func c(_ color: RGBA) -> String { color.description }
        func rgb(_ color: RGBA) -> String { "\(color.r), \(color.g), \(color.b)" }
        func a(_ color: RGBA, _ alpha: Double) -> String { color.with(alpha: alpha).hexWithAlpha }
        let faint = ui.muted.mixed(over: bg, amount: 0.7)
        let onAccent = ui.accent.contrast(with: bg) >= ui.accent.contrast(with: ui.foreground) ? bg : ui.foreground
        let accentHover = ui.accent.mixed(over: ui.foreground, amount: 0.85)
        let hsl = ui.accent.hsl
        // Obsidian's named colors. ANSI has no orange or pink: the warning color and bright magenta stand in.
        let named: [(String, RGBA)] = [
            ("red", t.ansi[1]), ("orange", ui.warning), ("yellow", t.ansi[3]), ("green", t.ansi[2]),
            ("cyan", t.ansi[6]), ("blue", t.ansi[4]), ("purple", t.ansi[5]), ("pink", t.ansi[13]),
        ]

        var list: [(String, String)] = [
            ("accent-h", String(format: "%.1f", hsl.h)), ("accent-s", String(format: "%.1f%%", hsl.s * 100)),
            ("accent-l", String(format: "%.1f%%", hsl.l * 100)),
            ("color-accent", c(ui.accent)), ("color-accent-1", c(accentHover)), ("color-accent-2", c(ui.accent.mixed(over: ui.foreground, amount: 0.7))),
            ("mono-rgb-0", rgb(bg)), ("mono-rgb-100", rgb(ui.foreground)),
        ]
        for (step, amount) in baseSteps {
            list.append((String(format: "color-base-%02d", step), c(ui.foreground.mixed(over: bg, amount: amount))))
        }
        for (name, color) in named { list += [("color-\(name)", c(color)), ("color-\(name)-rgb", rgb(color))] }
        list += [
            // Surfaces
            ("background-primary", c(bg)), ("background-primary-alt", c(ui.surface)),
            ("background-secondary", c(ui.surface)), ("background-secondary-alt", c(ui.overlay)),
            ("background-modifier-border", c(ui.border)),
            ("background-modifier-border-hover", c(ui.border.mixed(over: ui.muted, amount: 0.6))),
            ("background-modifier-border-focus", c(ui.accent)),
            ("background-modifier-hover", a(ui.foreground, 0.075)), ("background-modifier-active-hover", a(ui.accent, 0.15)),
            ("background-modifier-form-field", c(ui.overlay)),
            ("background-modifier-error", c(ui.error)), ("background-modifier-error-hover", c(ui.error)),
            ("background-modifier-success", c(ui.success)), ("background-modifier-message", c(ui.overlay)),
            ("titlebar-background", c(ui.surface)), ("titlebar-background-focused", c(ui.surface)),
            ("titlebar-text-color", c(ui.muted)), ("titlebar-text-color-focused", c(ui.foreground)),
            // Text
            ("text-normal", c(ui.foreground)), ("text-muted", c(ui.muted)), ("text-faint", c(faint)),
            ("text-accent", c(ui.accent)), ("text-accent-hover", c(accentHover)), ("text-on-accent", c(onAccent)),
            ("text-error", c(ui.error)), ("text-warning", c(ui.warning)), ("text-success", c(ui.success)),
            ("text-selection", c(ui.selection)), ("text-highlight-bg", a(ui.search, 0.4)),
            ("caret-color", c(ui.cursor)),
            // Controls
            ("interactive-normal", c(ui.overlay)), ("interactive-hover", c(ui.currentLine)),
            ("interactive-accent", c(ui.accent)), ("interactive-accent-hover", c(accentHover)),
            ("checkbox-color", c(ui.accent)), ("checkbox-color-hover", c(accentHover)), ("checkbox-border-color", c(ui.muted)),
            // Markdown
            ("link-color", c(ui.accent)), ("link-color-hover", c(accentHover)),
            ("link-external-color", c(ui.accent)), ("link-external-color-hover", c(accentHover)),
            ("tag-color", c(ui.accent)), ("tag-color-hover", c(accentHover)),
            ("tag-background", a(ui.accent, 0.1)), ("tag-background-hover", a(ui.accent, 0.2)),
            ("blockquote-border-color", c(ui.accent)), ("hr-color", c(ui.border)), ("table-border-color", c(ui.border)),
            // Code
            ("code-background", c(ui.surface)), ("code-normal", c(ui.foreground)),
            ("code-comment", c(s.comment.color)), ("code-function", c(s.function.color)),
            ("code-important", c(s.escape.color)), ("code-keyword", c(s.keyword.color)),
            ("code-operator", c(s.operator.color)), ("code-property", c(s.property.color)),
            ("code-punctuation", c(s.punctuation.color)), ("code-string", c(s.string.color)),
            ("code-tag", c(s.tag.color)), ("code-value", c(s.number.color)),
            // Graph view
            ("graph-line", c(ui.border)), ("graph-node", c(ui.muted)), ("graph-node-focused", c(ui.accent)),
            ("graph-node-unresolved", c(faint)), ("graph-node-tag", c(s.tag.color)),
            ("graph-node-attachment", c(s.string.color)), ("graph-text", c(ui.foreground)),
        ]
        // Headings take the keyword color, as Markdown headings do in Scene's VS Code theme.
        for level in 1...6 { list.append(("h\(level)-color", c(s.keyword.color))) }
        list.append(("inline-title-color", c(s.keyword.color)))
        return list
    }
}
