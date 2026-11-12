import Foundation
import SceneEngine
import SceneFoundation
import SceneRenderers

/// MonoCode reads an external theme in Scene's theme file format (`ThemeFileRenderer`) from its `themes` folder,
/// selected by `colorTheme` in its `appearance.json`. It checks both files every second and repaints every window,
/// and follows macOS Light/Dark itself when the file's mode is `system`. Contract: MonoCode's
/// `docs/scene-theme-integration.txt`.
public struct MonocodeIntegration: Integration {
    public let id = "monocode"
    public let displayName = "MonoCode"
    public let kind = IntegrationKind.editor
    public static let bundleID = "com.monocode.desktop"
    static let file = "scene.json"
    public init() {}

    /// Tauri's app data folder. MonoCode reads no environment variables for it.
    static func folder(_ env: SceneEnvironment) -> URL {
        env.home.appendingPathComponent("Library/Application Support/\(bundleID)")
    }

    public func detect(_ env: SceneEnvironment, _ services: SystemServices) async -> Detection {
        guard let app = env.locateApp(Self.bundleID) else { return .notInstalled() }
        let folder = Self.folder(env)
        let appearance = folder.appendingPathComponent("appearance.json")
        let version = Processes.appVersion(at: app)
        var detail = Operation.tilde(appearance.path)
        if FileOps.exists(appearance) && !FileOps.isWritable(appearance) {
            return Detection(installed: true, version: version, setup: .blocked("\(Operation.tilde(appearance.path)) is read-only."))
        }
        if let data = FileOps.read(FileOps.resolvedTarget(appearance)) {
            do {
                let doc = try JSONCDocument(text: String(decoding: data, as: UTF8.self))
                if case .string(let current)? = doc.value(forKey: "colorTheme"), !current.isEmpty, current != Self.file {
                    detail = "Current theme file: \(current)"
                }
            } catch {
                return Detection(installed: true, version: version,
                                 setup: .blocked("appearance.json cannot be read: \(error). Fix it in MonoCode first."))
            }
        }
        return Detection(installed: true, version: version, detail: detail,
                         context: ["appearance": appearance.path, "themes": folder.appendingPathComponent("themes").path])
    }

    public func plan(_ request: ApplyRequest, _ detection: Detection, _ env: SceneEnvironment) throws -> IntegrationPlan {
        let theme = URL(fileURLWithPath: detection.context["themes"]!).appendingPathComponent(Self.file)
        let data = try ThemeFileRenderer.file(variants: request.nativeVariants, appearance: request.effectiveAppearance,
                                              mode: request.mode.rawValue)
        // The file first: MonoCode falls back to its default theme while colorTheme names a missing file.
        return IntegrationPlan(operations: [
            .writeManagedFile(path: theme.path, contents: data),
            .setJSONValue(path: detection.context["appearance"]!, key: "colorTheme", value: .string(Self.file)),
        ], notes: ["MonoCode checks its theme files every second, so open windows change without a restart. Themes with both looks follow macOS Light/Dark."])
    }

    public func verify(_ plan: IntegrationPlan, _ detection: Detection, _ env: SceneEnvironment, _ services: SystemServices) async -> Verification {
        for op in plan.operations {
            guard case let .setJSONValue(path, key, value) = op else { continue }
            guard let data = FileOps.read(URL(fileURLWithPath: path)),
                  let doc = try? JSONCDocument(text: String(decoding: data, as: UTF8.self)),
                  doc.value(forKey: key) == value else { return .mismatch("\(key) was not saved") }
        }
        return Self.verifyFiles(plan)
    }
}
