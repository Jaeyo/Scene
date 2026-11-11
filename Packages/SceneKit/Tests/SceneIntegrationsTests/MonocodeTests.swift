import Foundation
import SceneEngine
import SceneFoundation
import SceneIntegrations
import SceneRenderers
import SceneThemes
import SceneTestSupport
import Testing

@Suite("MonoCode")
struct MonocodeTests {
    static let folder = "Library/Application Support/com.monocode.desktop"
    static let appearance = folder + "/appearance.json"
    static let theme = folder + "/themes/scene.json"

    static func setUp() throws -> (FixtureHome, SceneEnvironment) {
        let home = try FixtureHome()
        let app = try home.fakeApp("MonoCode", version: "0.14.0")
        return (home, Fixtures.environment(home, apps: [MonocodeIntegration.bundleID: app]))
    }

    @Test func applyWritesTheFileAndSelectsItThenRestores() async throws {
        let (home, env) = try Self.setUp()
        // MonoCode allows comments and keeps keys it does not know.
        let original = "{\n  // mine\n  \"colorTheme\": \"mine.json\",\n  \"fontSize\": 14\n}\n"
        try home.write(Self.appearance, original)
        try home.write(Self.folder + "/themes/mine.json", "{}")
        let services = FakeServices()
        let engine = Engine(env: env, services: services, integrations: [MonocodeIntegration()])
        #expect(await engine.detectAll()["monocode"]?.detail == "Current theme file: mine.json")
        for (mode, looks) in [(AppearanceMode.system, Set(["dark", "light"])), (.dark, ["dark"]), (.light, ["light"])] {
            let request = ApplyRequest(theme: try Fixtures.theme("catppuccin"), mode: mode, systemIsDark: true)
            let report = await engine.apply(request, planned: await engine.plan(request, detections: await engine.detectAll()), selected: ["monocode"])
            #expect(report.results.count == 1 && report.results.allSatisfy { $0.outcome.isSuccess })
            let doc = try JSONCDocument(text: #require(home.read(Self.appearance)))
            #expect(doc.value(forKey: "colorTheme") == .string("scene.json"))
            #expect(doc.value(forKey: "fontSize") == .number(14))
            #expect(doc.text.contains("// mine"))
            let file = try #require(home.read(Self.theme))
            let root = try #require(try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any])
            #expect(root["format"] as? Int == 1)
            #expect(root["mode"] as? String == mode.rawValue)
            let variants = try #require(root["variants"] as? [String: [String: Any]])
            #expect(Set(variants.keys) == looks)
            for (look, variant) in variants {
                let syntax = try #require(variant["syntax"] as? [String: String])
                #expect(syntax.count == 19)
                let v = request.variant(try #require(Appearance(rawValue: look)))
                #expect(syntax["string"] == v.syntax.string.color.description)
                #expect((variant["interface"] as? [String: String])?["background"] == v.interface.background.description)
            }
            // The file stays under MonoCode's 512 KB limit by a wide margin.
            #expect(file.utf8.count < 64 * 1024)
            _ = await engine.restoreOriginal()
            #expect(home.read(Self.appearance) == original)
            #expect(home.read(Self.theme) == nil)
            #expect(home.read(Self.folder + "/themes/mine.json") == "{}")
        }
        #expect(services.calls.isEmpty) // MonoCode watches its files; Scene starts and signals nothing
    }

    @Test func restoreRemovesTheKeyItAddedAndKeepsTheUsersChoice() async throws {
        let (home, env) = try Self.setUp()
        let engine = Engine(env: env, services: FakeServices(), integrations: [MonocodeIntegration()])
        let request = ApplyRequest(theme: try Fixtures.theme("gruvbox"), mode: .system, systemIsDark: false)
        // MonoCode never ran: no folder yet. Restore takes the key away, so MonoCode shows its default theme.
        _ = await engine.apply(request, planned: await engine.plan(request, detections: await engine.detectAll()), selected: ["monocode"])
        #expect(try JSONCDocument(text: #require(home.read(Self.appearance))).value(forKey: "colorTheme") == .string("scene.json"))
        _ = await engine.restoreOriginal()
        #expect(home.read(Self.appearance) == nil)
        // “Use built-in theme” in MonoCode removes colorTheme. Restore keeps that.
        _ = await engine.apply(request, planned: await engine.plan(request, detections: await engine.detectAll()), selected: ["monocode"])
        try home.write(Self.appearance, "{\"fontSize\": 15}")
        _ = await engine.restoreOriginal()
        #expect(home.read(Self.appearance) == "{\"fontSize\": 15}")
    }

    @Test func blockedWhenAppearanceCannotBeEdited() async throws {
        let (home, env) = try Self.setUp()
        let integration = MonocodeIntegration()
        for text in ["{broken", "[1, 2]"] {
            try home.write(Self.appearance, text)
            guard case .blocked = await integration.detect(env, FakeServices()).setup else { Issue.record("\(text) should block"); return }
            #expect(home.read(Self.appearance) == text)
        }
        try home.write(Self.appearance, "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: home.path(Self.appearance).path)
        guard case .blocked = await integration.detect(env, FakeServices()).setup else { Issue.record("read-only should block"); return }
        #expect(await integration.detect(Fixtures.environment(home, apps: [:]), FakeServices()).installed == false)
    }
}
