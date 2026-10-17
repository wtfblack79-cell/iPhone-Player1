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
    @State private var showingLibrary = false
    @State private var libraryFiles: [URL] = []
    @State private var currentScreenIsLibrary = false
    @State private var errorMessage = ""

    private let timer = Timer
        .publish(every: 0.5, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ZStack {
    LinearGradient(
        colors: [
            Color(red: 0.02, green: 0.04, blue: 0.13),
            Color(red: 0.04, green: 0.10, blue: 0.28),
            Color(red: 0.12, green: 0.04, blue: 0.24)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
            
    
    Circle()
        .fill(Color.cyan.opacity(0.18))
        .frame(width: 250, height: 250)
        .blur(radius: 80)
        .offset(x: -100, y: -180)

    Circle()
        .fill(Color.purple.opacity(0.20))
        .frame(width: 250, height: 250)
        .blur(radius: 80)
        .offset(x: 120, y: 200)

    if currentScreenIsLibrary {
    VStack(spacing: 16) {
        Text("Библиотека")
            .font(.largeTitle)
            .bold()

        if libraryFiles.isEmpty {
            Text("Аудиокниг пока нет")
                .foregroundStyle(.white.opacity(0.7))
        } else {
            List {
                ForEach(libraryFiles, id: \.self) { file in
                    Button {
                        loadAudio(.success([file]))
                        currentScreenIsLibrary = false
                    } label: {
                        Text(file.deletingPathExtension().lastPathComponent)
                            .foregroundStyle(.white)
                    }
                    .listRowBackground(Color.white.opacity(0.08))
                }
            }
            .scrollContentBackground(.hidden)
        }

        Spacer(minLength: 0)
    }
} else {
    VStack(spacing: 0) {
    // Название строго по центру экрана
    Text("PlayBook")
        .font(.largeTitle)
        .bold()
        .frame(maxWidth: .infinity)
        .padding(.top, 8)

    // Короткая волна под названием
    Image(systemName: "waveform")
        .font(.system(size: 22))
        .padding(.top, 4)

    // Название аудиокниги
    Text(fileName)
        .font(.headline)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .padding(.horizontal, 12)
        .padding(.top, 18)

    Spacer(minLength: 20)

    // Полоса прогресса и время
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

    Spacer(minLength: 22)

    // Перемотка и воспроизведение
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
            Image(
                systemName: isPlaying
                    ? "pause.circle.fill"
                    : "play.circle.fill"
            )
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

    Spacer(minLength: 30)

    // Овальная кнопка скорости внизу слева
    HStack {
        Menu {
            Picker("Скорость", selection: $speed) {
                Text("0,75×").tag(Float(0.75))
                Text("1×").tag(Float(1.0))
                Text("1,25×").tag(Float(1.25))
                Text("1,5×").tag(Float(1.5))
                Text("2×").tag(Float(2.0))
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(speed, specifier: "%g")×")
                    .font(.system(size: 16, weight: .medium))

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        Color.white.opacity(0.8),
                        lineWidth: 1
                    )
            }
        }
        .onChange(of: speed) { newSpeed in
            player?.rate = newSpeed
        }

        Spacer()
    }
    .padding(.bottom, 8)

    // Сообщение об ошибке
    if !errorMessage.isEmpty {
        Text(errorMessage)
            .foregroundStyle(.red)
            .font(.footnote)
            .padding(.top, 8)
    }

    Spacer(minLength: 8)
}
.padding(24)
.frame(maxWidth: .infinity, maxHeight: .infinity)
.foregroundStyle(.white)
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
}
.overlay(alignment: .topTrailing) {
        Menu {
            Button {
                showingImporter = true
            } label: {
                Label("Дропнуть аудио", systemImage: "folder")
            }

            Button {
                refreshLibrary()
                currentScreenIsLibrary = true
            } label: {
                Label("Библиотека", systemImage: "books.vertical")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .padding(.top, 12)
        .padding(.trailing, 18)
    }
    .overlay(alignment: .topLeading) {
        if currentScreenIsLibrary {
            Button {
                currentScreenIsLibrary = false
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.leading, 18)
        }
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
            refreshLibrary()
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

private func refreshLibrary() {
    let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )[0]

    do {
        let files = try FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil
        )

        libraryFiles = files.filter { url in
            [
                "mp3", "m4a", "m4b", "aac",
                "wav", "aiff", "caf", "flac"
            ].contains(url.pathExtension.lowercased())
        }
        .sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare(
                $1.lastPathComponent
            ) == .orderedAscending
        }
    } catch {
        errorMessage = "Не удалось загрузить библиотеку"
    }
}
}
