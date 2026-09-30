// App-hosted: CardWebView loads the production bridge and asset resources from Bundle.main.
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import AVFoundation
import Dependencies
import Foundation
import Testing
import UIKit
import WebKit
@testable import ReviewFeature

@MainActor
@Suite(.serialized)
struct CardPlaybackTests {
    @Test(arguments: ["Hello & world!", "<b>Hello</b>&nbsp;&amp; <i>world</i>!"])
    func nativeRenderedTTSUsesSpokenText(field: String) async throws {
        let directory = try mediaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try AnkiBackend()
        try backend.openCollection(
            collectionPath: directory.appendingPathComponent("collection.anki2").path,
            mediaFolderPath: directory.appendingPathComponent("media").path,
            mediaDbPath: directory.appendingPathComponent("media.db").path
        )
        defer { try? backend.closeCollection() }
        let html = try await withDependencies {
            $0.ankiBackend = backend
        } operation: {
            let client = NotetypesClient.liveValue
            let names = try await client.listAll()
            let basic = try #require(names.first { $0.name == "Basic" })
            var notetype = try await client.get(basic.id)
            notetype.templates[0].config.qFormat = "{{tts en_US voices=MissingVoice speed=0.8:Front}}"
            return try CardRenderingService.liveValue.renderUncommittedCard(
                notetype, 0, [field, "back"]
            ).frontHTML
        }
        #expect(html.contains("[anki:tts"))

        var started = false
        let card = CardWebView(html: html, autoplayEnabled: false, onAudioStateChange: {
            if $0 { started = true }
        })
        let coordinator = card.makeCoordinator()
        let webView = card.makeWebView(coordinator: coordinator)
        let window = try host(webView)
        defer { window.isHidden = true }
        defer { CardWebView.dismantleWebView(webView, coordinator: coordinator) }
        card.updateWebView(webView, coordinator: coordinator)
        let loaded = try await wait {
            try await webView.evaluateJavaScript("!!document.querySelector('.tts-btn')") as? Bool == true
        }
        try #require(loaded, "The actual bundled card frame must finish rendering")
        let text = try await webView.evaluateJavaScript("document.querySelector('.tts-btn').dataset.ttsText") as? String
        #expect(text == "Hello & world!")
        let language = try await webView.evaluateJavaScript("document.querySelector('.tts-btn').dataset.ttsLang") as? String
        #expect(language == "en_US")

        ReviewAudioSession.apply(playInSilent: true)
        defer { ReviewAudioSession.release() }
        _ = try await webView.evaluateJavaScript("document.querySelector('.tts-btn').click()")
        let spoke = try await wait { started }
        #expect(spoke, "The real WK message must start AVSpeechSynthesizer")
    }

    @Test(arguments: [false, true])
    func localSoundPlaysThroughTheActualAssetScheme(autoplay: Bool) async throws {
        let directory = try mediaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withDependencies {
            $0.mediaClient.folderURL = { directory }
        } operation: {
            var started = false
            let card = CardWebView(
                html: "[sound:先生 space.wav]", autoplayEnabled: autoplay,
                onAudioStateChange: { if $0 { started = true } }
            )
            let coordinator = card.makeCoordinator()
            let webView = card.makeWebView(coordinator: coordinator)
            let window = try host(webView)
            defer { window.isHidden = true }
            defer { CardWebView.dismantleWebView(webView, coordinator: coordinator) }
            ReviewAudioSession.apply(playInSilent: true)
            defer { ReviewAudioSession.release() }
            card.updateWebView(webView, coordinator: coordinator)
            let loaded = try await wait {
                try await webView.evaluateJavaScript("!!document.querySelector('.anki-sound-audio')") as? Bool == true
            }
            try #require(loaded, "The actual bundled card frame must finish rendering")
            if !autoplay {
                _ = try await webView.evaluateJavaScript("document.querySelector('.sound-btn .replay-button').click()")
            }
            let selector = autoplay ? "#amgi-audio-queue-player" : ".anki-sound-audio"
            let ended = try await wait {
                try await webView.evaluateJavaScript("""
                    (() => {
                      const audio = document.querySelector('\(selector)');
                      return !!audio && audio.ended && audio.duration > 0 && audio.currentTime > 0;
                    })()
                    """) as? Bool == true
            }
            #expect(started)
            let diagnostic = try await webView.evaluateJavaScript("""
                (() => {
                  const audio = document.querySelector('\(selector)');
                  return JSON.stringify(audio && {src:audio.src, error:audio.error && audio.error.code,
                    paused:audio.paused, duration:audio.duration, time:audio.currentTime,
                    ready:audio.readyState, network:audio.networkState});
                })()
                """)
            #expect(ended, "WebKit must decode and finish the real WAV: \(String(describing: diagnostic))")
        }
    }

    @Test func nativeSoundQueueFinishesTheLocalFile() async throws {
        let directory = try mediaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        ReviewAudioSession.apply(playInSilent: true)
        defer { ReviewAudioSession.release() }
        let player = NativeCardAudioPlayer()
        defer { player.stop() }
        player.play(files: ["先生 space.wav"], mediaFolder: directory)
        #expect(player.isPlaying)
        let ended = try await wait { !player.isPlaying }
        #expect(ended)
    }

    private func mediaDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("card-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 11_025))
        buffer.frameLength = buffer.frameCapacity
        try #require(buffer.int16ChannelData)[0].update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(
            forWriting: directory.appendingPathComponent("先生 space.wav"), settings: format.settings,
            commonFormat: .pcmFormatInt16, interleaved: false
        )
        try file.write(from: buffer)
        return directory
    }

    private func host(_ webView: WKWebView) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.rootViewController?.view = webView
        window.isHidden = false
        return window
    }

    private func wait(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
