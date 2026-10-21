
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import UIKit

@MainActor
final class AudioBookPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published var books: [URL] = []
    @Published var currentURL: URL?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    override init() {
        super.init()
        configureAudio()
        refreshBooks()
        restoreLastBook()
    }

    private var folder: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
    }

    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func refreshBooks() {
        do {
            books = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
            .filter {
                ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf"]
                    .contains($0.pathExtension.lowercased())
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }
        } catch {
            books = []
        }
    }

    private func positionKey(_ url: URL) -> String {
        "position_" + url.lastPathComponent
    }

    private func restoreLastBook() {
        guard
            let name = UserDefaults.standard.string(forKey: "lastBook"),
            let url = books.first(where: {
                $0.lastPathComponent == name
            })
        else {
            return
        }

        load(url)
    }

    func load(_ url: URL) {
        savePosition()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.enableRate = true
            newPlayer.prepareToPlay()

            let savedTime = UserDefaults.standard.double(
                forKey: positionKey(url)
            )

            newPlayer.currentTime = min(
                savedTime,
                newPlayer.duration
            )
            newPlayer.rate = rate

            player = newPlayer
            currentURL = url
            currentTime = newPlayer.currentTime
            duration = newPlayer.duration
            isPlaying = false

            UserDefaults.standard.set(
                url.lastPathComponent,
                forKey: "lastBook"
            )

            startTimer()
        } catch {
            print("Could not open audiobook: \(error)")
        }
    }

    func playPause() {
        guard let player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            savePosition()
        } else {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Audio activation error: \(error)")
            }

            player.enableRate = true
            player.rate = rate

            if player.play() {
                isPlaying = true
            }
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }

        player.currentTime = min(max(seconds, 0), player.duration)
        currentTime = player.currentTime
        savePosition()
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player?.enableRate = true

        if isPlaying {
            player?.rate = newRate
        }
    }

    func savePosition() {
        guard let currentURL else { return }

        UserDefaults.standard.set(
            currentTime,
            forKey: positionKey(currentURL)
        )
    }

    private func startTimer() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                guard let player = self.player else { return }

                self.currentTime = player.currentTime
                self.duration = player.duration

                if !player.isPlaying {
                    self.isPlaying = false
                }

                self.savePosition()
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func importBooks(_ urls: [URL]) {
        for url in urls {
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let ext = url.pathExtension
                let base = url.deletingPathExtension().lastPathComponent
                var destination = folder.appendingPathComponent(
                    url.lastPathComponent
                )
                var index = 2

                while FileManager.default.fileExists(
                    atPath: destination.path
                ) {
                    let name = ext.isEmpty
                        ? "\(base) \(index)"
                        : "\(base) \(index).\(ext)"

                    destination = folder.appendingPathComponent(name)
                    index += 1
                }

                try FileManager.default.copyItem(
                    at: url,
                    to: destination
                )
            } catch {
                print("Import error: \(error)")
            }
        }

        refreshBooks()
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        isPlaying = false
        currentTime = 0
        savePosition()
    }
}

struct PlayerApp: App {
    var body: some Scene {
        WindowGroup {
            PlayerView()
        }
    }
}

struct PlayerView: View {
    @StateObject private var player = AudioBookPlayer()
    @State private var showImporter = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    private let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "headphones")
                    .font(.system(size: 58))
                    .padding(.top, 20)

                Text(player.currentURL?.deletingPathExtension()
                    .lastPathComponent ?? "Выбери аудиокнигу")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                Slider(
                    value: Binding(
                        get: {
                            isScrubbing
                                ? scrubValue
                                : player.currentTime
                        },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing

                        if !editing {
                            player.seek(to: scrubValue)
                        }
                    }
                )
                .disabled(player.currentURL == nil)

                HStack {
                    Text(timeString(player.currentTime))
                    Spacer()
                    Text("-" + timeString(
                        max(player.duration - player.currentTime, 0)
                    ))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 35) {
                    Button {
                        player.skip(-15)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 30))
                    }
                    .disabled(player.currentURL == nil)

                    Button {
                        player.playPause()
                    } label: {
                        Image(systemName: player.isPlaying
                              ? "pause.circle.fill"
                              : "play.circle.fill")
                            .font(.system(size: 62))
                    }
                    .disabled(player.currentURL == nil)

                    Button {
                        player.skip(30)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 30))
                    }
                    .disabled(player.currentURL == nil)
                }
                .buttonStyle(.plain)

                HStack {
                    Text("Скорость")
                    Spacer()

                    Picker(
                        "Скорость",
                        selection: Binding(
                            get: { player.rate },
                            set: { player.setRate($0) }
                        )
                    ) {
                        ForEach(speeds, id: \.self) { speed in
                            Text("\(speed, specifier: "%.2g")×")
                                .tag(speed)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Divider()

                HStack {
                    Text("Мои аудиокниги")
                        .font(.headline)
                    Spacer()

                    Button {
                        showImporter = true
                    } label: {
                        Label("Добавить", systemImage: "plus")
                    }
                }

                List(player.books, id: \.path) { book in
                    Button {
                        player.load(book)
                        player.playPause()
                    } label: {
                        HStack {
                            Image(systemName: "book.closed")
                            Text(book.deletingPathExtension()
                                .lastPathComponent)
                                .lineLimit(2)
                            Spacer()

                            if player.currentURL == book {
                                Image(systemName: player.isPlaying
                                      ? "speaker.wave.2.fill"
                                      : "bookmark.fill")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .listStyle(.plain)
            }
            .padding(.horizontal)
            .navigationTitle("iPhone Player")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    player.importBooks(urls)

                    if player.currentURL == nil,
                       let first = player.books.first {
                        player.load(first)
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification
                )
            ) { _ in
                player.savePosition()
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }

        let total = max(Int(seconds), 0)
        return "\(total / 60):" +
            String(format: "%02d", total % 60)
    }
}
