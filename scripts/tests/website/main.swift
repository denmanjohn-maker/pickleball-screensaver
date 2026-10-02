import AppKit
import WebKit

let args = CommandLine.arguments
let noScript = args.contains("--no-script")
let releaseScenario = args.first(where: { $0.hasPrefix("--release=") }).map {
    String($0.dropFirst("--release=".count))
} ?? "windows"
let windowsAssetNames = [
    "PickleballScreensaver-win-x64.msi", "PickleballScreensaver-win-x64.zip",
    "PickleballScreensaver-win-arm64.msi", "PickleballScreensaver-win-arm64.zip",
    "Pickleball-Classic.deskthemepack", "Pickleball-BlackLight.deskthemepack"
]
let width: CGFloat = args.contains("--mobile") ? 375 : 1440
let height: CGFloat = args.contains("--mobile") ? 812 : 1000
let snapshotDirectory: URL? = args.first(where: { $0.hasPrefix("--snapshots=") }).map {
    URL(fileURLWithPath: String($0.dropFirst("--snapshots=".count)), isDirectory: true)
}

@MainActor
final class WebsiteCheck: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs")

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = !noScript
        let fixtureNames: [String]
        switch releaseScenario {
        case "windows": fixtureNames = windowsAssetNames
        case "partial": fixtureNames = Array(windowsAssetNames.prefix(1))
        case "macos", "network-failure", "http-error": fixtureNames = []
        default: fatalError("Unknown release fixture: \(releaseScenario)")
        }
        let fixture: [String: Any] = [
            "tag_name": "v2.3",
            "assets": (["PickleballScreensaver.dmg", "PickleballScreensaver.zip"] + fixtureNames).map { ["name": $0] }
        ]
        let fixtureJSON = String(data: try! JSONSerialization.data(withJSONObject: fixture), encoding: .utf8)!
        let response = releaseScenario == "network-failure" ?
            "Promise.reject(new Error('Fixture network failure'))" :
            "Promise.resolve({ok: \(releaseScenario != "http-error"), json: () => Promise.resolve(\(fixtureJSON))})"
        config.userContentController.addUserScript(WKUserScript(source: """
            window.__fixtureReleaseCalls = 0;
            window.fetch = function (url) {
                window.__fixtureReleaseCalls++;
                if (url !== "https://api.github.com/repos/denmanjohn-maker/pickleball-screensaver/releases/latest") {
                    return Promise.reject(new Error("Unexpected website request"));
                }
                return \(response);
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func start() {
        if snapshotDirectory != nil { window.orderBack(nil) }
        webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let result = try await webView.callAsyncJavaScript("""
                    const assert = (value, message) => { if (!value) throw new Error(message); };
                    const names = ["Classic", "Black Light", "Living Court", "Ink-and-paper", "Rally Painting"];
                    const buttons = [...document.querySelectorAll(".appearance-button")];
                    const panels = [...document.querySelectorAll(".shot-panel")];
                    assert(buttons.length === 5 && panels.length === 5, "Five appearances required");
                    assert(buttons.every((b, i) => b.textContent === names[i]), "Incorrect appearance labels");
                    assert(new Set(panels.map(p => p.id)).size === 5, "Duplicate panel IDs");
                    assert(document.documentElement.scrollWidth <= window.innerWidth, "Horizontal overflow");
                    const releasesURL = "https://github.com/denmanjohn-maker/pickleball-screensaver/releases";
                    const windows = document.getElementById("windows-downloads");
                    const windowsDownloads = [...windows.querySelectorAll("[data-release-asset]")];
                    assert(windowsDownloads.length === 6, "Missing Windows package/theme links");
                    assert(windowsDownloads.every((link, i) => link.dataset.releaseAsset === windowsAssetNames[i]), "Incorrect Windows download filenames");
                    assert(windows.textContent.includes("ARM64") && windows.textContent.includes("x64"), "Missing Windows architectures");
                    assert(windows.textContent.includes("System type") && windows.textContent.includes(".NET"), "Missing Windows requirements");
                    assert(windows.querySelector(".windows-notice").textContent.includes("unsigned"), "Missing unsigned Windows notice");
                    assert(windows.querySelector(".windows-notice").textContent.includes("SmartScreen"), "Missing Windows warning");
                    assert(windows.querySelector(".windows-notice").textContent.includes("standard-user"), "Missing desktop acceptance limitation");
                    assert(windows.querySelector(".windows-install").textContent.includes("current-user"), "Missing MSI installation instructions");
                    assert(windows.querySelector(".windows-install").textContent.includes("keep all its files together"), "Missing portable instructions");
                    assert(windows.querySelector(".windows-install").textContent.includes("does not automatically activate"), "Missing opt-in/policy notice");
                    assert(document.title.includes("Windows"), "Missing Windows page metadata");
                    const availableCount = noScript || ["macos", "network-failure", "http-error"].includes(releaseScenario) ? 0 :
                        releaseScenario === "partial" ? 1 : windowsAssetNames.length;
                    for (const [index, link] of windowsDownloads.entries()) {
                        const expected = index < availableCount ? releasesURL + "/latest/download/" + link.dataset.releaseAsset : releasesURL;
                        assert(link.href === expected, "Incorrect direct download or fallback for " + link.dataset.releaseAsset);
                        const rect = link.getBoundingClientRect();
                        assert(rect.width > 0 && rect.height > 0 && rect.left >= 0 && rect.right <= innerWidth, "Windows download hidden or clipped");
                    }
                    const status = document.getElementById("windows-release-status");
                    assert(status.getAttribute("role") === "status", "Missing accessible download status");
                    assert(window.__fixtureReleaseCalls === (noScript ? 0 : 1), "Unexpected live or duplicate release request");
                    const expectedStatus = noScript ? "open GitHub Releases" :
                        releaseScenario === "windows" ? "available in the latest release" :
                        releaseScenario === "macos" ? "does not yet include Windows" :
                        releaseScenario === "partial" ? "Some Windows packages" : "Could not check";
                    assert(status.textContent.includes(expectedStatus), "Incorrect Windows availability notice");
                    const macDownloads = [...document.querySelectorAll(".hero .cta-row a")];
                    assert(macDownloads.length === 2, "macOS download options changed");
                    assert(macDownloads[0].href === "https://github.com/denmanjohn-maker/pickleball-screensaver/releases/latest/download/PickleballScreensaver.dmg", "macOS DMG link changed");
                    assert(macDownloads[1].href === "https://github.com/denmanjohn-maker/pickleball-screensaver/releases/latest/download/PickleballScreensaver.zip", "macOS ZIP link changed");
                    for (const link of document.querySelectorAll('a[href^="#"]')) {
                        assert(document.getElementById(link.hash.slice(1)), "Broken section link");
                    }
                    for (const panel of panels) {
                        const img = panel.querySelector("img");
                        img.loading = "eager";
                        await img.decode();
                        assert(img.naturalWidth === 1280 && img.naturalHeight === 720, "Incorrect screenshot dimensions");
                        assert(img.alt.length > 30, "Missing screenshot description");
                        assert(panel.querySelector("a").getAttribute("href") === img.getAttribute("src"), "Full-size link mismatch");
                    }
                    if (noScript) {
                        assert(document.querySelector(".appearance-picker").hidden, "Inactive controls exposed");
                        assert(panels.every(p => !p.hidden), "No-script gallery hides screenshots");
                    } else {
                        assert(!document.querySelector(".appearance-picker").hidden, "Controls not initialized");
                        for (const button of buttons) {
                            button.click();
                            const selected = document.getElementById(button.getAttribute("aria-controls"));
                            assert(panels.filter(p => !p.hidden).length === 1 && !selected.hidden, "Wrong gallery panel");
                            assert(buttons.filter(b => b.getAttribute("aria-pressed") === "true").length === 1, "Incorrect selected state");
                            assert(button.getAttribute("aria-pressed") === "true", "Clicked button not selected");
                            const rect = selected.querySelector("img").getBoundingClientRect();
                            assert(rect.width > 0 && rect.left >= 0 && rect.right <= innerWidth, "Screenshot clipped");
                            assert(document.documentElement.scrollWidth <= innerWidth, "Gallery creates horizontal overflow");
                        }
                        buttons[0].focus();
                        assert(document.activeElement === buttons[0], "Gallery button cannot receive keyboard focus");
                        const focusRule = [...document.styleSheets].flatMap(sheet => [...sheet.cssRules])
                            .find(rule => rule.selectorText && rule.selectorText.includes("button:focus-visible"));
                        assert(focusRule && focusRule.style.outlineStyle !== "none", "Keyboard focus styling missing");
                        if (buttons[0].matches(":focus-visible")) {
                            assert(getComputedStyle(buttons[0]).outlineStyle !== "none", "Keyboard focus is not visible");
                        }
                    }
                    assert(document.getAnimations().length === 0, "Unexpected automatic gallery animation");
                    const sources = [...document.querySelectorAll("img")].map(img => img.getAttribute("src"));
                    return { width: innerWidth, screenshots: panels.length, noScript, releaseScenario, sources };
                    """, arguments: ["noScript": noScript, "releaseScenario": releaseScenario,
                                     "windowsAssetNames": windowsAssetNames], in: nil, contentWorld: .page)
                print("Website checks passed: \(String(describing: result))")
                if let directory = snapshotDirectory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try await snapshot(to: directory.appendingPathComponent("top-\(Int(width)).png"))
                    _ = try await webView.callAsyncJavaScript("""
                        const paper = document.querySelector('[aria-controls="appearance-ink-and-paper"]');
                        if (!noScript) paper.click();
                        const section = document.getElementById("screens-title");
                        window.scrollTo({top: section.getBoundingClientRect().top + scrollY - 24, behavior: "instant"});
                        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                        """, arguments: ["noScript": noScript], in: nil, contentWorld: .page)
                    try await snapshot(to: directory.appendingPathComponent("gallery-\(Int(width)).png"))
                }
                exit(0)
            } catch {
                fputs("FAIL: website: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private func snapshot(to url: URL) async throws {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WebsiteCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to encode website snapshot"])
        }
        try png.write(to: url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fputs("FAIL: website navigation: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}

_ = NSApplication.shared
let check = MainActor.assumeIsolated {
    let check = WebsiteCheck()
    check.start()
    return check
}
DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
    fputs("FAIL: website checks timed out\n", stderr)
    exit(1)
}
NSApplication.shared.run()
