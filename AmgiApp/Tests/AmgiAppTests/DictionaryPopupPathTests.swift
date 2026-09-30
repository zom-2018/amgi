import AppCore
import Dependencies
import Foundation
import Reader
import Sharing
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import ReaderDictionary
@testable import ReaderFeature
@testable import ReviewFeature

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DictionaryPopupPathTests {
    @Test(arguments: [1, 2, 16])
    func cardTapOpensNativeLookupPopup(scanLength: Int) async throws {
        let profileID = "popup-path-" + UUID().uuidString
        let directory = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first).appendingPathComponent("ReaderDictionaries").appendingPathComponent(profileID)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = DictionaryLookupRuntime(configStore: .testValue, profileID: profileID)
        let archive = try #require(Bundle(for: DictionaryPopupFixture.self)
            .url(forResource: "scan-length", withExtension: "zip"))
        _ = try await runtime.importArchive(at: archive, kind: .term, requiresSecurityScope: false)
        let suite = "popup-prefs-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(scanLength, forKey: ReaderPreferences.Keys.dictionaryScanLength)
        preferences.set(1, forKey: ReaderPreferences.Keys.dictionaryMaxResults)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        var matched: String?
        var tappedQuery: String?
        let card = CardWebView(
            html: "<p><ruby>先生<rt>せんせい</rt></ruby>は来た。</p>",
            autoplayEnabled: false, lookupPopupEnabled: true,
            dictionaryScanLength: preferences.integer(forKey: ReaderPreferences.Keys.dictionaryScanLength),
            onLookupRequested: { query, sentence, _ in
                tappedQuery = query
                guard let query else { return }
                let popup = withDependencies {
                    $0.defaultAppStorage = preferences
                    $0.dictionaryLookupClient.lookup = { query, limit, length in
                        try await runtime.lookup(query, maxResults: limit, scanLength: length)
                    }
                } operation: {
                    LookupPopupView(initialQuery: query, sentence: sentence,
                                    onMatched: { matched = $0 }, onDismiss: {})
                }
                window.rootViewController?.present(UIHostingController(rootView: popup), animated: false)
            }
        )
        let coordinator = card.makeCoordinator()
        let webView = card.makeWebView(coordinator: coordinator)
        window.rootViewController?.view = webView
        defer { CardWebView.dismantleWebView(webView, coordinator: coordinator) }
        card.updateWebView(webView, coordinator: coordinator)
        try #require(try await wait {
            try await webView.evaluateJavaScript("""
                !!document.querySelector('#qa ruby') &&
                Date.now() - amgiCardState().renderedAt >= 300
                """) as? Bool == true
        })
        _ = try await webView.evaluateJavaScript("""
            (() => {
                const node = document.querySelector('#qa ruby').firstChild;
                const range = document.createRange();
                range.setStart(node, 0); range.setEnd(node, 1);
                const rect = range.getBoundingClientRect();
                document.querySelector('#qa ruby').dispatchEvent(new MouseEvent('click', {
                    bubbles: true, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2
                }));
            })()
            """)
        try #require(try await wait { matched != nil })
        let expected = scanLength == 1 ? "先" : "先生"
        #expect(tappedQuery?.hasPrefix(expected) == true)
        #expect(matched == expected)
        #expect(window.rootViewController?.presentedViewController is UIHostingController<LookupPopupView>)
        window.rootViewController?.dismiss(animated: false)
    }

    private func wait(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

private final class DictionaryPopupFixture: NSObject {}
