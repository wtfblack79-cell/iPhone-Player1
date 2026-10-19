import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct iPhonePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "playbook" else { return }

        if let path = UserDefaults(suiteName: "group.com.personal.iphoneplayer")?
            .string(forKey: "lastSharedAudioPath") {
            
            let fileURL = URL(fileURLWithPath: path)
            print("Получен аудиофайл:", fileURL.path)
            
            // Сохраняем путь, чтобы ContentView мог его подхватить
            UserDefaults.standard.set(path, forKey: "pendingAudioPath")
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
    @State private var libraryFiles: [URL] = []
    @State private var currentScreenIsLibrary = false
    @State private var errorMessage = ""
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var folders: [String] = []
    @State private var selectedFolder: String? = nil
    @State private var fileFolders: [String: String] = [:]
    @State private var didAttemptRestore = false
    @State private var sleepTimerTotal: Int = 0          // выбранный таймер в минутах, 0 = выключен
    @State private var sleepTimerRemaining: TimeInterval = 0  // сколько осталось, секунды
    @State private var sleepTimerStartedAt: Date?        // когда запустили
    @State private var sleepTimerExpired = false         // сработал ли уже
    @State private var sleepTimerStartedPosition: Double = 0 // позиция книги при старте таймера
    @State private var isSeeking = false                 // пользователь держит ползунок

    private let timer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac",
        "wav", "aiff", "caf", "flac"
    ]

    private var percentCompleted: Int {
        guard duration > 0 else { return 0 }
        return Int((progress / duration * 100).rounded())
    }

    var body: some View {
        ZStack {
            background

            if currentScreenIsLibrary {
                libraryView
            } else {
                playerView
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let sharedDefaults = UserDefaults(suiteName: "group.com.personal.iphoneplayer")
                if let path = sharedDefaults?.string(forKey: "lastSharedAudioPath") {
                    openSharedAudio(URL(fileURLWithPath: path))
                    sharedDefaults?.removeObject(forKey: "lastSharedAudioPath")
                } else {
                    restoreLastAudio()
                }
            }
        }
        .onOpenURL { url in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if url.scheme == "playbook" {
                    let sharedDefaults = UserDefaults(suiteName: "group.com.personal.iphoneplayer")
                    if let path = sharedDefaults?.string(forKey: "lastSharedAudioPath") {
                        openSharedAudio(URL(fileURLWithPath: path))
                        sharedDefaults?.removeObject(forKey: "lastSharedAudioPath")
                    }
                } else {
                    importIncomingAudio(url)
                }
            }
        }
        .onReceive(timer) { _ in
            guard let player else { return }

            // Пока пользователь держит ползунок — не трогаем позицию
            if !isSeeking {
                progress = player.currentTime
            }
            isPlaying = player.isPlaying

            tickSleepTimer()

            if !isSeeking {
                UserDefaults.standard.set(
                    player.currentTime,
                    forKey: "playbook.lastPosition"
                )

                UserDefaults.standard.set(
                    player.url?.lastPathComponent ?? "",
                    forKey: "playbook.lastFileName"
                )
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            loadAudio(result)
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

    private var background: some View {
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
        }
        .ignoresSafeArea()
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            Text("PlayBook")
                .font(.largeTitle)
                .bold()
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            Image(systemName: "waveform")
                .font(.system(size: 22))
                .padding(.top, 4)

            Text(fileName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 18)

            Spacer(minLength: 20)

            Spacer(minLength: 22)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // Полоска теперь здесь — прямо над кнопками
                VStack(spacing: 8) {
                    SlimSlider(
                        value: $progress,
                        range: 0...max(duration, 1),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if !editing {
                                player?.currentTime = progress
                            }
                        }
                    )
                    .allowsHitTesting(player != nil)

                    HStack {
                        Text(timeString(progress))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(percentCompleted)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text(timeString(duration))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.bottom, 20)   // расстояние между полоской и кнопками

                HStack(spacing: 35) {
                    seekButton(seconds: -15, symbol: "gobackward.15")
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
                    seekButton(seconds: 15, symbol: "goforward.15")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .frame(maxHeight: .infinity)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if sleepTimerExpired {
                    Text("Таймер сработал — книга стояла на \(timeString(sleepTimerStartedPosition))")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .transition(.opacity)
                }

                HStack(spacing: 12) {
                    speedButton
                    sleepTimerButton
                    Spacer()
                }
            }
            .animation(.easeInOut(duration: 0.3), value: sleepTimerExpired)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.clear)
        }
    }

    private var speedButton: some View {
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
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            }
        }
        .onChange(of: speed) { newSpeed in
            player?.rate = newSpeed
        }
    }

    private var sleepTimerIsActive: Bool {
        sleepTimerTotal > 0 && sleepTimerRemaining > 0
    }

    private var sleepTimerCountdownText: String {
        let total = Int(max(0, sleepTimerRemaining.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var sleepTimerStartedText: String {
        guard let date = sleepTimerStartedAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var sleepTimerButton: some View {
        Menu {
            Picker("Таймер сна", selection: $sleepTimerTotal) {
                Text("Выкл").tag(0)
                Text("5 мин").tag(5)
                Text("10 мин").tag(10)
                Text("15 мин").tag(15)
                Text("30 мин").tag(30)
                Text("45 мин").tag(45)
                Text("1 час").tag(60)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16, weight: .medium))

                if sleepTimerIsActive {
                    Text(sleepTimerCountdownText)
                        .font(.system(size: 16, weight: .medium))
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, sleepTimerIsActive ? 16 : 14)
            .frame(height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: sleepTimerIsActive)
        }
        .onChange(of: sleepTimerTotal) { newMinutes in
            setSleepTimer(minutes: newMinutes)
        }
    }

    private func setSleepTimer(minutes: Int) {
        if minutes <= 0 {
            sleepTimerTotal = 0
            sleepTimerRemaining = 0
            sleepTimerStartedAt = nil
            sleepTimerStartedPosition = 0
            sleepTimerExpired = false
            return
        }

        sleepTimerTotal = minutes
        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimerStartedAt = Date()
        sleepTimerStartedPosition = player?.currentTime ?? 0
        sleepTimerExpired = false
    }

    private func tickSleepTimer() {
        guard sleepTimerTotal > 0, sleepTimerRemaining > 0, !sleepTimerExpired else { return }

        // На паузе обратный отсчёт замирает
        guard let player, player.isPlaying else { return }

        sleepTimerRemaining = max(0, sleepTimerRemaining - 0.5)

        if sleepTimerRemaining <= 0 {
            sleepTimerExpired = true
            player.pause()
            isPlaying = false
        }
    }

    private var libraryView: some View {
        VStack(spacing: 16) {
            Text("Библиотека")
                .font(.largeTitle)
                .bold()

            if libraryFiles.isEmpty && folders.isEmpty {
                Text("Аудиокниг пока нет")
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                List {
                    if let selectedFolder {
                        Button {
                            self.selectedFolder = nil
                        } label: {
                            Label("Назад к библиотеке", systemImage: "chevron.left")
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white.opacity(0.08))

                        Text(selectedFolder)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .listRowBackground(Color.white.opacity(0.08))
                    } else {
                        ForEach(folders, id: \.self) { folder in
                            Button {
                                selectedFolder = folder
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(
                                            Color(red: 0.85, green: 0.76, blue: 0.48)
                                        )
                                    Text(folder)
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.white.opacity(0.08))
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteFolder(folder)
                                } label: {
                                    Label("Удалить папку", systemImage: "trash")
                                }
                            }
                        }
                    }

                    ForEach(
                        libraryFiles.filter { file in
                            fileFolders[file.lastPathComponent] == selectedFolder
                        },
                        id: \.self
                    ) { file in
                        Button {
                            loadAudio(.success([file]))
                            currentScreenIsLibrary = false
                        } label: {
                            Text(file.deletingPathExtension().lastPathComponent)
                                .foregroundStyle(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.08))
                        .contextMenu {
                            Menu {
                                if folders.isEmpty {
                                    Button {
                                        newFolderName = ""
                                        showingCreateFolder = true
                                    } label: {
                                        Label("Создать папку", systemImage: "folder.badge.plus")
                                    }
                                } else {
                                    ForEach(folders, id: \.self) { folder in
                                        Button {
                                            moveFile(file, to: folder)
                                        } label: {
                                            Label(folder, systemImage: "folder")
                                        }
                                    }
                                }
                            } label: {
                                Label("Добавить в папку…", systemImage: "folder.badge.plus")
                            }

                            if fileFolders[file.lastPathComponent] != nil {
                                Button {
                                    moveFile(file, to: nil)
                                } label: {
                                    Label("Убрать из папки", systemImage: "folder")
                                }
                            }
                            Button(role: .destructive) {
                                deleteFile(file)
                            } label: {
                                Label("Удалить аудио", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }

            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    newFolderName = ""
                    showingCreateFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay {
                            Capsule()
                                .stroke(
                                    Color.white.opacity(0.8),
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .alert("Новая папка", isPresented: $showingCreateFolder) {
            TextField("Название папки", text: $newFolderName)

            Button("Отмена", role: .cancel) {
                newFolderName = ""
            }

            Button("ОК") {
                createFolder()
            }
        } message: {
            Text("Введите название папки")
        }
        .onAppear {
            loadFolders()
        }
    }

    private func seekButton(seconds: Double, symbol: String) -> some View {
        Button {
            seek(by: seconds)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30))
        }
        .disabled(player == nil)
    }

    private func loadFolders() {
        folders = UserDefaults.standard.stringArray(
            forKey: "playbook.libraryFolders"
        ) ?? []

        fileFolders = UserDefaults.standard.dictionary(
            forKey: "playbook.fileFolders"
        ) as? [String: String] ?? [:]
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !name.isEmpty else {
            newFolderName = ""
            return
        }

        let alreadyExists = folders.contains {
            $0.localizedCaseInsensitiveCompare(name) == .orderedSame
        }

        guard !alreadyExists else {
            newFolderName = ""
            return
        }

        folders.append(name)

        UserDefaults.standard.set(
            folders,
            forKey: "playbook.libraryFolders"
        )

        newFolderName = ""
    }

    private func moveFile(_ file: URL, to folder: String?) {
        let key = file.lastPathComponent

        if let folder {
            fileFolders[key] = folder
        } else {
            fileFolders.removeValue(forKey: key)
        }

        UserDefaults.standard.set(
            fileFolders,
            forKey: "playbook.fileFolders"
        )
    }

    private func deleteFile(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            errorMessage = "Не удалось удалить файл"
            return
        }

        fileFolders.removeValue(forKey: file.lastPathComponent)
        UserDefaults.standard.set(fileFolders, forKey: "playbook.fileFolders")

        if player?.url == file {
            player?.stop()
            player = nil
            isPlaying = false
            fileName = "Аудиокнига не выбрана"
        }

        refreshLibrary()
    }

    private func deleteFolder(_ folder: String) {
        folders.removeAll { $0 == folder }
        for key in fileFolders.keys where fileFolders[key] == folder {
            fileFolders.removeValue(forKey: key)
        }
        UserDefaults.standard.set(folders, forKey: "playbook.libraryFolders")
        UserDefaults.standard.set(fileFolders, forKey: "playbook.fileFolders")
        if selectedFolder == folder {
            selectedFolder = nil
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

            let destination = documents.appendingPathComponent(
                sourceURL.lastPathComponent
            )

            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }

            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default
            )
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

    private func openSharedAudio(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let allowedExtensions: Set<String> = [
            "mp3", "m4a", "m4b", "aac",
            "wav", "aiff", "caf", "flac"
        ]

        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "Этот формат аудио не поддерживается."
            return
        }

        do {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            let sourceURL = url.standardizedFileURL
            var destinationURL = documentsURL.appendingPathComponent(
                url.lastPathComponent
            )

            if sourceURL != destinationURL.standardizedFileURL {
                let baseName = url.deletingPathExtension().lastPathComponent
                let fileExtension = url.pathExtension
                var number = 2

                while FileManager.default.fileExists(
                    atPath: destinationURL.path
                ) {
                    destinationURL = documentsURL.appendingPathComponent(
                        "\(baseName) (\(number)).\(fileExtension)"
                    )
                    number += 1
                }

                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destinationURL
                )
            }

            loadAudio(.success([destinationURL]))
            currentScreenIsLibrary = false
            errorMessage = ""
        } catch {
            errorMessage = "Не удалось открыть аудио: \(error.localizedDescription)"
        }
    }

    private func importIncomingAudio(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let allowedExtensions: Set<String> = [
            "mp3", "m4a", "m4b", "aac",
            "wav", "aiff", "caf", "flac"
        ]

        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "Этот формат аудио не поддерживается."
            return
        }

        do {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            let sourceURL = url.standardizedFileURL
            var destinationURL = documentsURL.appendingPathComponent(
                url.lastPathComponent
            )

            if sourceURL != destinationURL.standardizedFileURL {
                let baseName = url.deletingPathExtension().lastPathComponent
                let fileExtension = url.pathExtension
                var number = 2

                while FileManager.default.fileExists(
                    atPath: destinationURL.path
                ) {
                    destinationURL = documentsURL.appendingPathComponent(
                        "\(baseName) (\(number)).\(fileExtension)"
                    )
                    number += 1
                }

                try FileManager.default.copyItem(
                    at: url,
                    to: destinationURL
                )
            }

            refreshLibrary()
            currentScreenIsLibrary = true
            errorMessage = ""
        } catch {
            errorMessage = "Не удалось добавить аудио: \(error.localizedDescription)"
        }
    }

    private func restoreLastAudio() {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true

        let savedFileName = UserDefaults.standard.string(
            forKey: "playbook.lastFileName"
        ) ?? ""

        guard !savedFileName.isEmpty else { return }

        let savedPosition = UserDefaults.standard.double(
            forKey: "playbook.lastPosition"
        )

        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let savedURL = documentsURL.appendingPathComponent(savedFileName)

        guard FileManager.default.fileExists(atPath: savedURL.path) else {
            return
        }

        loadAudio(.success([savedURL]))

        guard let player else { return }

        player.currentTime = max(
            0,
            min(savedPosition - 2, player.duration)
        )

        progress = player.currentTime
        isPlaying = false
        player.pause()
    }

    private func togglePlayback() {
        guard let player else { return }

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
        guard let player else { return }

        let newTime = min(
            max(player.currentTime + seconds, 0),
            player.duration
        )
        player.currentTime = newTime
        progress = newTime
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
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

            libraryFiles = files.filter {
                audioExtensions.contains($0.pathExtension.lowercased())
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

// Ползунок с маленьким кружком и обычной толщиной линии
struct SlimSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void

    private let trackHeight: CGFloat = 6
    private let knobSize: CGFloat = 16
    private let accent = Color(red: 0.20, green: 0.55, blue: 1.0)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0
                ? min(max((value - range.lowerBound) / span, 0), 1)
                : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(accent)
                    .frame(width: max(0, width * fraction), height: trackHeight)

                Circle()
                    .fill(accent)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: max(0, min(width - knobSize, width * fraction - knobSize / 2)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onEditingChanged(true)
                        let f = min(max(g.location.x / max(width, 1), 0), 1)
                        value = range.lowerBound + f * span
                    }
                    .onEnded { _ in
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 32)
    }
}
