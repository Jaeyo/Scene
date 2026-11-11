import Foundation
import SceneEngine
import SceneFoundation
import SceneIntegrations
import SceneRenderers
import SceneThemes
import SceneTestSupport
import Testing

@Suite("Obsidian")
struct ObsidianTests {
    static let list = "Library/Application Support/obsidian/obsidian.json"
    static let notes = """
    {
      "accentColor": "#3cc0ec",
      "theme": "moonstone",
      "enabledCssSnippets": [
        "colors",
        "layout"
      ],
      "cssTheme": "Sparkling Day",
      "baseFontSize": 17
    }
    """

    /// Four vaults: one with its own look, one without appearance.json, one with a broken one, and one that is gone.
    static func setUp() throws -> (FixtureHome, SceneEnvironment) {
        let home = try FixtureHome()
        let app = try home.fakeApp("Obsidian", version: "1.8.10")
        let vaults = ["notes", "empty", "broken", "gone"].map { home.path("vaults/\($0)").path }
        let entries = vaults.enumerated().map { "\"id\($0.offset)\": {\"path\": \"\($0.element)\", \"ts\": 1}" }
        try home.write(list, "{\"vaults\": {\(entries.joined(separator: ", "))}}")
        try home.write("vaults/notes/.obsidian/appearance.json", notes)
        try home.write("vaults/notes/.obsidian/snippets/colors.css", ".markdown-preview-view h1 {\n  color: #222222;\n}\n")
        try home.write("vaults/notes/.obsidian/snippets/layout.css", "body {\n  --line-height-normal: 1.8;\n}\n")
        try FileManager.default.createDirectory(at: home.path("vaults/empty/.obsidian"), withIntermediateDirectories: true)
        try home.write("vaults/broken/.obsidian/appearance.json", "{broken")
        return (home, Fixtures.environment(home, apps: [ObsidianIntegration.bundleID: app]))
    }

    @Test func detectsVaultsAndWhatWinsOverTheTheme() async throws {
        let (home, env) = try Self.setUp()
        let detection = await ObsidianIntegration().detect(env, FakeServices())
        #expect(detection.installed && detection.version == "1.8.10")
        #expect(detection.setup == .ready)
        #expect(detection.detail == "2 vaults: empty, notes")
        #expect(detection.conflicts.contains { $0.contains("“colors”") && $0.contains("“notes”") })
        #expect(!detection.conflicts.contains { $0.contains("“layout”") })
        #expect(detection.conflicts.contains { $0.contains("“broken”") })
        #expect(home.read("vaults/broken/.obsidian/appearance.json") == "{broken")
    }

    @Test func applyFollowsTheLookAndRestoresEveryVault() async throws {
        let (home, env) = try Self.setUp()
        let engine = Engine(env: env, services: FakeServices(), integrations: [ObsidianIntegration()])
        let theme = try Fixtures.theme("gruvbox")
        let notes = "vaults/notes/.obsidian/", empty = "vaults/empty/.obsidian/"
        for (mode, base) in [(AppearanceMode.system, "system"), (.dark, "obsidian"), (.light, "moonstone")] {
            let request = ApplyRequest(theme: theme, mode: mode, systemIsDark: true)
            let report = await engine.apply(request, planned: await engine.plan(request, detections: await engine.detectAll()), selected: ["obsidian"])
            #expect(report.results.count == 1 && report.results.allSatisfy { $0.outcome.isSuccess })
            let doc = try JSONCDocument(text: #require(home.read(notes + "appearance.json")))
            #expect(doc.value(forKey: "cssTheme") == .string("Scene"))
            #expect(doc.value(forKey: "theme") == .string(base))
            #expect(doc.value(forKey: "accentColor") == .string(""))
            #expect(doc.value(forKey: "baseFontSize") == .number(17))
            #expect(doc.value(forKey: "enabledCssSnippets") == .array([.string("colors"), .string("layout")]))
            let created = try JSONCDocument(text: #require(home.read(empty + "appearance.json")))
            #expect(created.value(forKey: "cssTheme") == .string("Scene"))
            #expect(created.value(forKey: "accentColor") == nil)
            for vault in [notes, empty] {
                #expect(home.read(vault + "themes/Scene/theme.css") == (try ObsidianRenderer.themeCSS(variants: request.nativeVariants)))
                #expect(home.read(vault + "themes/Scene/manifest.json") != nil)
            }
            #expect(home.read("vaults/broken/.obsidian/appearance.json") == "{broken")
            #expect(!FileManager.default.fileExists(atPath: home.path("vaults/gone").path))
            _ = await engine.restoreOriginal()
            #expect(home.read(notes + "appearance.json") == Self.notes)
            #expect(home.read(empty + "appearance.json") == nil)
            for vault in [notes, empty] { #expect(home.read(vault + "themes/Scene/theme.css") == nil) }
        }
    }

    @Test func restoreKeepsWhatTheUserPickedLater() async throws {
        let (home, env) = try Self.setUp()
        let engine = Engine(env: env, services: FakeServices(), integrations: [ObsidianIntegration()])
        let request = ApplyRequest(theme: try Fixtures.theme("catppuccin"), mode: .system, systemIsDark: false)
        _ = await engine.apply(request, planned: await engine.plan(request, detections: await engine.detectAll()), selected: ["obsidian"])
        let path = "vaults/notes/.obsidian/appearance.json"
        var doc = try JSONCDocument(text: #require(home.read(path)))
        try doc.set(.string("Minimal"), forKey: "cssTheme")
        try home.write(path, doc.text)
        _ = await engine.restoreOriginal()
        let restored = try JSONCDocument(text: #require(home.read(path)))
        #expect(restored.value(forKey: "cssTheme") == .string("Minimal"))
        #expect(restored.value(forKey: "theme") == .string("moonstone"))
        #expect(restored.value(forKey: "accentColor") == .string("#3cc0ec"))
    }

    @Test func blockedWithoutVaults() async throws {
        let home = try FixtureHome()
        let app = try home.fakeApp("Obsidian", version: "1.8.10")
        let env = Fixtures.environment(home, apps: [ObsidianIntegration.bundleID: app])
        let integration = ObsidianIntegration()
        guard case .blocked = await integration.detect(env, FakeServices()).setup else { Issue.record("no vault list"); return }
        try home.write(Self.list, "{\"vaults\": {\"a\": {\"path\": \"\(home.path("missing").path)\"}}}")
        guard case .blocked = await integration.detect(env, FakeServices()).setup else { Issue.record("no vault on disk"); return }
        try home.write(Self.list, "{broken")
        guard case .blocked = await integration.detect(env, FakeServices()).setup else { Issue.record("broken vault list"); return }
        #expect(await integration.detect(Fixtures.environment(home, apps: [:]), FakeServices()).installed == false)
    }
}
