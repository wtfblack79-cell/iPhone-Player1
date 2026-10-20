import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

enum AppFont {
    static func regular(_ size: CGFloat) -> Font {
        .custom("ShantellSans-Regular", size: size)
    }

    static func bold(_ size: CGFloat) -> Font {
        .custom("ShantellSans-Bold", size: size)
    }

    static func italic(_ size: CGFloat) -> Font {
        .custom("ShantellSans-Italic", size: size)
    }
}

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

            UserDefaults.standard.set(path, forKey: "pendingAudioPath")
        }
    }
}

struct ContentView: View {

    enum ActiveMenu {
        case options
        case speed
        case sleep
    }

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
    @State private var sleepTimerTotal: Int = 0
    @State private var sleepTimerRemaining: TimeInterval = 0
    @State private var sleepTimerStartedAt: Date?
    @State private var sleepTimerExpired = false
    @State private var sleepTimerStartedPosition: Double = 0

    // Ползунок
    @State private var isSeeking = false

    // Меню
    @State private var activeMenu: ActiveMenu? = nil

    // Волна: сглаженный уровень громкости 0...1
    @State private var smoothLevel: Double = 0

    // Фон
    @State private var homeBackground: UIImage?
    @State private var libraryBackground: UIImage?
    @State private var showingBackgroundPicker = false
    @State private var backgroundTarget = "home"

    private let timer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    // Быстрый таймер для волны: 20 раз в секунду
    private let waveTimer = Timer.publish(
        every: 0.05,
        on: .main,
        in: .common
    ).autoconnect()

    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac",
        "wav", "aiff", "caf", "flac"
    ]

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
            loadBackgrounds()

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
        .onReceive(waveTimer) { _ in
            updateWaveLevel()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            loadAudio(result)
        }
        .fileImporter(
            isPresented: $showingBackgroundPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            importBackgroundImage(result)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                toggleMenu(.options)
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
        .overlay {
            menuOverlay
        }
    }

    // MARK: - Меню

    private func toggleMenu(_ menu: ActiveMenu) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            activeMenu = activeMenu == menu ? nil : menu
        }
    }

    private func closeMenu() {
        withAnimation(.easeOut(duration: 0.2)) {
            activeMenu = nil
        }
    }

    @ViewBuilder
    private var menuOverlay: some View {
        if activeMenu != nil {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeMenu()
                    }

                switch activeMenu {
                case .options:
                    HStack {
                        Spacer()
                        optionsMenu
                    }
                    .padding(.top, 66)
                    .padding(.trailing, 18)

                case .speed:
                    VStack {
                        Spacer()
                        HStack {
                            speedMenu
                            Spacer()
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.bottom, 112)

                case .sleep:
                    VStack {
                        Spacer()
                        HStack {
                            sleepMenu
                            Spacer()
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.bottom, 112)

                case .none:
                    EmptyView()
                }
            }
            .transition(.opacity)
        }
    }

    private func menuHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.italic(13))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func menuContainer<Content: View>(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                menuHeader(title)
            }
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func menuRow(
        title: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22)
                }

                Text(title)
                    .font(AppFont.regular(17))
                    .foregroundStyle(.white)

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.35, green: 0.8, blue: 0.95))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionsMenu: some View {
        menuContainer {
            VStack(alignment: .leading, spacing: 0) {
                menuRow(title: "Дропнуть аудио", systemImage: "folder") {
                    closeMenu()
                    showingImporter = true
                }

                menuRow(title: "Библиотека", systemImage: "books.vertical") {
                    closeMenu()
                    refreshLibrary()
                    currentScreenIsLibrary = true
                }

                menuHeader("Сменить фон")

                menuRow(title: "Главный экран", systemImage: "iphone") {
                    closeMenu()
                    chooseBackground(for: "home")
                }

                menuRow(title: "Библиотека", systemImage: "books.vertical.fill") {
                    closeMenu()
                    chooseBackground(for: "library")
                }
            }
        }
    }

    private func setSpeed(_ value: Float) {
        speed = value
        closeMenu()
    }

    private var speedMenu: some View {
        menuContainer(title: "Скорость") {
            VStack(alignment: .leading, spacing: 0) {
                menuRow(title: "0,75×", isSelected: speed == 0.75) {
                    setSpeed(0.75)
                }
                menuRow(title: "1×", isSelected: speed == 1.0) {
                    setSpeed(1.0)
                }
                menuRow(title: "1,25×", isSelected: speed == 1.25) {
                    setSpeed(1.25)
                }
                menuRow(title: "1,5×", isSelected: speed == 1.5) {
                    setSpeed(1.5)
                }
                menuRow(title: "2×", isSelected: speed == 2.0) {
                    setSpeed(2.0)
                }
            }
        }
    }

    private func setSleep(_ minutes: Int) {
        setSleepTimer(minutes: minutes)
        closeMenu()
    }

    private var sleepMenu: some View {
        menuContainer(title: "Таймер сна") {
            VStack(alignment: .leading, spacing: 0) {
                menuRow(title: "Выкл", isSelected: sleepTimerTotal == 0) {
                    setSleep(0)
                }
                menuRow(title: "5 мин", isSelected: sleepTimerTotal == 5) {
                    setSleep(5)
                }
                menuRow(title: "10 мин", isSelected: sleepTimerTotal == 10) {
                    setSleep(10)
                }
                menuRow(title: "15 мин", isSelected: sleepTimerTotal == 15) {
                    setSleep(15)
                }
                menuRow(title: "30 мин", isSelected: sleepTimerTotal == 30) {
                    setSleep(30)
                }
                menuRow(title: "45 мин", isSelected: sleepTimerTotal == 45) {
                    setSleep(45)
                }
                menuRow(title: "1 час", isSelected: sleepTimerTotal == 60) {
                    setSleep(60)
                }
            }
        }
    }

    // MARK: - Фон

    private var background: some View {
        ZStack {
            if currentScreenIsLibrary {
                backgroundLayer(image: libraryBackground)
            } else {
                backgroundLayer(image: homeBackground)
            }
        }
        .ignoresSafeArea()
    }

    private func backgroundLayer(image: UIImage?) -> some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
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
                }
            }
            .clipped()
    }

    private func chooseBackground(for screen: String) {
        backgroundTarget = screen
        showingBackgroundPicker = true
    }

    private func importBackgroundImage(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = UIImage(contentsOfFile: url.path) else {
            errorMessage = "Не удалось открыть картинку"
            return
        }

        saveBackgroundImage(image, for: backgroundTarget)
    }

    private func saveBackgroundImage(_ image: UIImage, for screen: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Уменьшаем картинку до 1600px по большей стороне:
            // экрану этого хватает, а декодировать такое в разы быстрее
            let maxDimension: CGFloat = 1600
            var scaledImage = image
            let maxSide = max(image.size.width, image.size.height)

            if maxSide > maxDimension {
                let scale = maxDimension / maxSide
                let newSize = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
                let renderer = UIGraphicsImageRenderer(size: newSize)
                scaledImage = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }

            guard let data = scaledImage.jpegData(compressionQuality: 0.85) else { return }

            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            let name = screen == "home"
                ? "playbook.background.home.jpg"
                : "playbook.background.library.jpg"
            let url = documents.appendingPathComponent(name)

            try? data.write(to: url)

            DispatchQueue.main.async {
                if screen == "home" {
                    homeBackground = scaledImage
                } else {
                    libraryBackground = scaledImage
                }
                refreshLibrary()
            }
        }
    }

    private func loadBackgrounds() {
        DispatchQueue.global(qos: .userInitiated).async {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

            func loadImage(_ name: String) -> UIImage? {
                guard let data = try? Data(contentsOf: documents.appendingPathComponent(name)) else {
                    return nil
                }
                return UIImage(data: data)
            }

            let home = loadImage("playbook.background.home.jpg")
            let library = loadImage("playbook.background.library.jpg")

            DispatchQueue.main.async {
                homeBackground = home
                libraryBackground = library
            }
        }
    }

    // MARK: - Волна

    private func updateWaveLevel() {
        guard let player else {
            smoothLevel = max(0, smoothLevel - 0.05)
            return
        }

        if player.isMeteringEnabled {
            player.updateMeters()
        }

        if player.isPlaying {
            // AVAudioPlayer отдаёт уровень в децибелах, обычно от -160 до 0
            let db = player.averagePower(forChannel: 0)

            // Переводим в 0...1: -60 дБ — тишина, 0 дБ — максимум
            let normalized = max(0, min(1, (db + 60) / 60))

            // Степень больше 1 делает тишину спокойнее, а пики выразительнее
            let shaped = pow(normalized, 1.4)

            // Быстрая атака на громких звуках, мягкий спад на тихих
            if shaped > smoothLevel {
                smoothLevel += (shaped - smoothLevel) * 0.55
            } else {
                smoothLevel += (shaped - smoothLevel) * 0.12
            }
        } else {
            // На паузе волна плавно гаснет до лёгкого «дыхания»
            smoothLevel = max(0, smoothLevel - 0.05)
        }
    }

    // MARK: - Плеер

    private var percentCompleted: Int {
        guard duration > 0 else { return 0 }
        return Int((progress / duration * 100).rounded())
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            Text("PlayBook")
                .font(AppFont.bold(34))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            NeonWaveView(level: smoothLevel)
                .frame(height: 96)
                .padding(.top, 4)

            Text(fileName)
                .font(AppFont.regular(17))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 18)

            Spacer(minLength: 20)

            VStack(spacing: 8) {
                SlimSlider(
                    value: $progress,
                    range: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing {
                            player?.currentTime = progress
                            UserDefaults.standard.set(
                                progress,
                                forKey: "playbook.lastPosition"
                            )
                        }
                    }
                )
                .disabled(player == nil)

                HStack {
                    Text(timeString(progress))
                        .font(AppFont.regular(13).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(percentCompleted)%")
                        .font(AppFont.regular(13).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(timeString(duration))
                        .font(AppFont.regular(13).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 20)

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

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(AppFont.regular(13))
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if sleepTimerExpired {
                    Text("Таймер сработал — книга стояла на \(timeString(sleepTimerStartedPosition))")
                        .font(AppFont.italic(13))
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
        Button {
            toggleMenu(.speed)
        } label: {
            HStack(spacing: 5) {
                Text("\(speed, specifier: "%g")×")
                    .font(AppFont.regular(16))

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
        Button {
            toggleMenu(.sleep)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16, weight: .medium))

                if sleepTimerIsActive {
                    Text(sleepTimerCountdownText)
                        .font(AppFont.regular(16))
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
        .buttonStyle(.plain)
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

    // MARK: - Библиотека

    private var libraryView: some View {
        VStack(spacing: 16) {
            Text("Библиотека")
                .font(AppFont.bold(34))

            if libraryFiles.isEmpty && folders.isEmpty {
                Text("Аудиокниг пока нет")
                    .font(AppFont.regular(17))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                List {
                    if let selectedFolder {
                        Button {
                            self.selectedFolder = nil
                        } label: {
                            Label("Назад к библиотеке", systemImage: "chevron.left")
                                .font(AppFont.regular(17))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white.opacity(0.08))

                        Text(selectedFolder)
                            .font(AppFont.bold(17))
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
                                        .font(AppFont.regular(17))
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
                                .font(AppFont.regular(17))
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
            newPlayer.isMeteringEnabled = true
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
                    && !$0.lastPathComponent.hasPrefix("playbook.background")
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

// Тонкий ползунок с маленьким кружком
struct SlimSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    var knobSize: CGFloat = 16
    var trackHeight: CGFloat = 6

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = range.upperBound > range.lowerBound
                ? min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
                : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color(red: 0.20, green: 0.55, blue: 1.0))
                    .frame(width: max(0, width * fraction), height: trackHeight)

                Circle()
                    .fill(Color(red: 0.20, green: 0.55, blue: 1.0))
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: width * fraction - knobSize / 2)
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }

                        let newFraction = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: knobSize)
    }
}

// Неоновая звуковая волна: реагирует на уровень громкости аудио
struct NeonWaveView: View {
    var level: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                var graphics = ctx
                let t = timeline.date.timeIntervalSinceReferenceDate

                // Лёгкое «дыхание» на паузе, чтобы волна не умирала совсем
                let breath = 0.5 + 0.5 * sin(t * 1.2)
                let intensity = 0.06 + 0.04 * breath + level

                let lines: [(Color, Double, Double, Double, CGFloat)] = [
                    (Color(red: 0.20, green: 0.85, blue: 0.92), 0.0, 2.4, 1.1, 2.0),
                    (Color(red: 0.55, green: 0.30, blue: 0.98), 1.7, 2.1, 1.35, 1.7),
                    (Color(red: 0.30, green: 0.65, blue: 1.00), 3.4, 1.8, 1.6, 2.0),
                    (Color(red: 0.80, green: 0.45, blue: 1.00), 5.1, 1.5, 1.85, 1.7)
                ]

                for (index, line) in lines.enumerated() {
                    drawWave(
                        &graphics,
                        size: size,
                        time: t,
                        amplitude: size.height * (0.16 + 0.03 * Double(index)) * intensity,
                        color: line.0,
                        phaseOffset: line.1,
                        speed: line.2,
                        frequency: line.3,
                        lineWidth: line.4
                    )
                }
            }
        }
    }

    private func drawWave(
        _ context: inout GraphicsContext,
        size: CGSize,
        time t: Double,
        amplitude: CGFloat,
        color: Color,
        phaseOffset: Double,
        speed: Double,
        frequency: Double,
        lineWidth: CGFloat
    ) {
        let midY = size.height / 2
        let steps = 64
        var path = Path()

        for step in 0...steps {
            let p = Double(step) / Double(steps)
            let x = size.width * CGFloat(p)

            // Затухание к краям, чтобы волна не упиралась в границы
            let envelope = pow(sin(.pi * p), 0.7)

            // Основная волна плюс лёгкая вторая гармоника для «живости»
            let y = midY
                + CGFloat(
                    sin(p * frequency * 2 * .pi + t * speed + phaseOffset) * 0.75
                        + sin(p * frequency * 3.7 * 2 * .pi + t * speed * 1.6 + phaseOffset * 2.0) * 0.25
                ) * amplitude * envelope

            if step == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        // Свечение: размытая копия линии под основной
        var glow = context
        glow.blendMode = .plusLighter
        glow.addFilter(.blur(radius: 10))
        glow.stroke(
            path,
            with: .color(color.opacity(0.45)),
            style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round)
        )

        // Основная линия
        context.blendMode = .plusLighter
        context.stroke(
            path,
            with: .color(color.opacity(0.95)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        context.blendMode = .normal
    }
}
