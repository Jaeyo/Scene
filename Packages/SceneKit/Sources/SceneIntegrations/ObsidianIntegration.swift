import Foundation
import SceneEngine
import SceneRenderers
import SceneThemes
import SceneFoundation

/// Obsidian keeps its look per vault, in `<vault>/.obsidian/appearance.json`. Scene adds a CSS theme to every vault
/// Obsidian lists and selects it there. A running Obsidian reloads `appearance.json` and the selected theme's
/// `theme.css` when they change, so open vaults change live (checked against Obsidian 1.15.0's app code).
public struct ObsidianIntegration: Integration {
    public let id = "obsidian"
    public let displayName = "Obsidian"
    public let kind = IntegrationKind.editor
    public static let bundleID = "md.obsidian"
    public init() {}

    /// Obsidian's own list of vaults.
    static func vaultList(_ env: SceneEnvironment) -> URL {
        env.home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// Properties that change colors. An enabled snippet that sets one loads after the theme and wins over it.
    static let colorPattern = try! NSRegularExpression(pattern: #"(^|[\s;{])(color|background(-color)?|--(color|background|text|interactive)-[\w-]+)\s*:"#)

    public func detect(_ env: SceneEnvironment, _ services: SystemServices) async -> Detection {
        guard let app = env.locateApp(Self.bundleID) else { return .notInstalled() }
        let version = Processes.appVersion(at: app)
        let list = Self.vaultList(env)
        guard let data = FileOps.read(list) else {
            return Detection(installed: true, version: version, setup: .blocked("Obsidian has no vaults yet. Open a vault in Obsidian first."))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Detection(installed: true, version: version, setup: .blocked("\(Operation.tilde(list.path)) cannot be read. Open Obsidian once to repair it."))
        }
        let paths = ((json["vaults"] as? [String: Any]) ?? [:]).values
            .compactMap { ($0 as? [String: Any])?["path"] as? String }
            .sorted()
        var vaults: [String] = [], clearAccent: [String] = [], conflicts: [String] = []
        for path in paths {
            let config = URL(fileURLWithPath: path).appendingPathComponent(".obsidian")
            var isFolder: ObjCBool = false
            // A vault Obsidian still lists but that was moved or deleted.
            guard FileManager.default.fileExists(atPath: config.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            var doc: JSONCDocument?
            if let text = FileOps.read(FileOps.resolvedTarget(config.appendingPathComponent("appearance.json"))) {
                guard let parsed = try? JSONCDocument(text: String(decoding: text, as: UTF8.self)) else {
                    conflicts.append("The vault “\(name)” has an appearance.json Scene cannot read, so Scene leaves that vault alone.")
                    continue
                }
                doc = parsed
            }
            vaults.append(path)
            // A custom accent color wins over the theme's accent. An empty one means none.
            if case .string(let accent)? = doc?.value(forKey: "accentColor"), !accent.isEmpty { clearAccent.append(path) }
            if case .array(let snippets)? = doc?.value(forKey: "enabledCssSnippets") {
                for case .string(let snippet) in snippets where Self.setsColors(snippet: snippet, config: config) {
                    conflicts.append("The CSS snippet “\(snippet)” in the vault “\(name)” sets colors, which win over Scene's theme.")
                }
            }
        }
        guard !vaults.isEmpty else {
            return Detection(installed: true, version: version, setup: .blocked("Scene found no Obsidian vault. Open a vault in Obsidian first."),
                             conflicts: conflicts)
        }
        conflicts.append("A vault that syncs (Obsidian Sync, iCloud) takes the Scene theme to your other devices.")
        let names = vaults.map { URL(fileURLWithPath: $0).lastPathComponent }
        return Detection(installed: true, version: version,
                         detail: vaults.count == 1 ? "Vault: \(names[0])" : "\(vaults.count) vaults: \(names.joined(separator: ", "))",
                         conflicts: conflicts,
                         context: ["vaults": vaults.joined(separator: "\n"), "clearAccent": clearAccent.joined(separator: "\n")])
    }

    /// Whether an enabled snippet sets a color. Snippet names come from the user's file, so one that is not a
    /// plain file name is skipped.
    static func setsColors(snippet: String, config: URL) -> Bool {
        guard !snippet.isEmpty, !snippet.contains("/"), !snippet.hasPrefix(".") else { return false }
        guard let data = FileOps.read(config.appendingPathComponent("snippets/\(snippet).css")) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return colorPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public func plan(_ request: ApplyRequest, _ detection: Detection, _ env: SceneEnvironment) throws -> IntegrationPlan {
        let variants = request.nativeVariants
        let css = Data(try ObsidianRenderer.themeCSS(variants: variants).utf8)
        let base = ObsidianRenderer.baseTheme(variants: variants)
        let clearAccent = Set(Self.lines(detection.context["clearAccent"]))
        var ops: [Operation] = []
        for vault in Self.lines(detection.context["vaults"]) {
            let config = URL(fileURLWithPath: vault).appendingPathComponent(".obsidian")
            let folder = config.appendingPathComponent("themes/\(ObsidianRenderer.themeName)")
            let appearance = config.appendingPathComponent("appearance.json").path
            // The files first: Obsidian loads the theme when it sees cssTheme change.
            ops += [
                .writeManagedFile(path: folder.appendingPathComponent("manifest.json").path, contents: ObsidianRenderer.manifest()),
                .writeManagedFile(path: folder.appendingPathComponent("theme.css").path, contents: css),
                .setJSONValue(path: appearance, key: "cssTheme", value: .string(ObsidianRenderer.themeName)),
                .setJSONValue(path: appearance, key: "theme", value: .string(base)),
            ]
            if clearAccent.contains(vault) { ops.append(.setJSONValue(path: appearance, key: "accentColor", value: .string(""))) }
        }
        return IntegrationPlan(operations: ops, conflicts: detection.conflicts,
                               notes: ["Open vaults change live. Other vaults show the theme when you open them."])
    }

    public func verify(_ plan: IntegrationPlan, _ detection: Detection, _ env: SceneEnvironment, _ services: SystemServices) async -> Verification {
        for op in plan.operations {
            guard case let .setJSONValue(path, key, value) = op else { continue }
            guard let data = FileOps.read(URL(fileURLWithPath: path)),
                  let doc = try? JSONCDocument(text: String(decoding: data, as: UTF8.self)),
                  doc.value(forKey: key) == value else { return .mismatch("\(key) was not saved in \(Operation.tilde(path))") }
        }
        return Self.verifyFiles(plan)
    }

    static func lines(_ value: String?) -> [String] {
        (value ?? "").split(separator: "\n").map(String.init)
    }
}
