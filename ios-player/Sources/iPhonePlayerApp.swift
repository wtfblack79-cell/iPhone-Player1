
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct iPhonePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var player: AVAudioPlayer?
    @State private var fileName = "Аудиокнига не выбрана"
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var speed: Float = 1.0
    @State private var showingImporter = false
    @State private var errorMessage = ""

    private let timer = Timer
        .publish(every: 0.5, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 54))

            Text("PlayBook")
                .font(.largeTitle)
                .bold()

            Text(fileName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Button {
                showingImporter = true
            } label: {
                Label("Выбрать аудиокнигу", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            VStack(spacing: 8) {
                Slider(
                    value: $progress,
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            player?.currentTime = progress
                        }
                    }
                )
                .disabled(player == nil)

                HStack {
                    Text(timeString(progress))
                    Spacer()
                    Text(timeString(duration))
                }
                .font(.caption.monospacedDigit())
            }

            HStack(spacing: 35) {
                Button {
                    seek(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 30))
                }
                .disabled(player == nil)

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                .disabled(player == nil)

                Button {
                    seek(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 30))
                }
                .disabled(player == nil)
            }
            .buttonStyle(.plain)

            HStack {
                Text("Скорость")
                Spacer()

                Picker("Скорость", selection: $speed) {
                    Text("0,75×").tag(Float(0.75))
                    Text("1×").tag(Float(1.0))
                    Text("1,25×").tag(Float(1.25))
                    Text("1,5×").tag(Float(1.5))
                    Text("2×").tag(Float(2.0))
                }
                .pickerStyle(.menu)
                .onChange(of: speed) { newSpeed in
                    player?.rate = newSpeed
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer()
        }
        .padding(24)
        .onReceive(timer) { _ in
            guard let player = player else { return }
            progress = player.currentTime
            isPlaying = player.isPlaying

            if !player.isPlaying && player.currentTime >= player.duration {
                isPlaying = false
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            loadAudio(result)
        }
    }

    private func loadAudio(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }

            let accessGranted = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            let destination = documents.appendingPathComponent(sourceURL.lastPathComponent)

            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }

            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let newPlayer = try AVAudioPlayer(contentsOf: destination)
            newPlayer.enableRate = true
            newPlayer.prepareToPlay()

            player?.stop()
            player = newPlayer
            fileName = sourceURL.lastPathComponent
            duration = newPlayer.duration
            progress = 0
            speed = 1.0
            isPlaying = false
            errorMessage = ""
        } catch {
            errorMessage = "Не удалось открыть файл: \(error.localizedDescription)"
        }
    }

    private func togglePlayback() {
        guard let player = player else { return }

        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = speed
            player.play()
            isPlaying = true
        }
    }

    private func seek(by seconds: Double) {
        guard let player = player else { return }
        let newTime = min(max(player.currentTime + seconds, 0), player.duration)
        player.currentTime = newTime
        progress = newTime
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
