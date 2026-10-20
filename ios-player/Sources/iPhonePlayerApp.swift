import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

// Шрифты приложения — Shantell Sans
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

// Собственные всплывающие меню вместо системных
private enum MenuKind {
    case options
    case background
    case speed
    case sleepTimer
}

private struct PopupMenuRow: View {
    let title: String
    let systemImage: String?
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 22)
                } else {
                    Color.clear
                        .frame(width: 22, height: 1)
                }

                Text(title)
                    .font(AppFont.regular(17))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.35, green: 0.8, blue: 0.95))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @State private var sleepTimerTotal: Int = 0
    @State private var sleepTimerRemaining: TimeInterval = 0
    @State private var sleepTimerStartedAt: Date?
    @State private var sleepTimerExpired = false
    @State private var sleepTimerStartedPosition: Double = 0

    // Ползунок
    @State private var isSeeking = false

    // Фон
    @State private var homeBackground: UIImage?
    @State private var libraryBackground: UIImage?
    @State private var showingBackgroundPicker = false
    @State private var backgroundTarget = "home"

    // Свои меню
    @State private var activeMenu: MenuKind? = nil

    // Уровень громкости для волны (0...1, сглаженный)
    @State private var waveLevel: Double = 0

    private let timer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    // Замер громкости для волны: 20 раз в секунду
    private let meterTimer = Timer.publish(
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
        .onReceive(meterTimer) { _ in
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
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    activeMenu = activeMenu == .options ? nil : .options
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
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

    // MARK: - Свои меню

    private var menuOverlay: some View {
        ZStack {
            if activeMenu != nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            activeMenu = nil
                        }
                    }
            }

            if activeMenu == .options {
                popupMenu(title: nil, anchor: .topTrailing) {
                    VStack(alignment: .leading, spacing: 2) {
                        PopupMenuRow(title: "Дропнуть аудио", systemImage: "folder") {
                            withAnimation(nil) { activeMenu = nil }
                            showingImporter = true
                        }
                        PopupMenuRow(title: "Библиотека", systemImage: "books.vertical") {
                            withAnimation(nil) { activeMenu = nil }
                            refreshLibrary()
                            currentScreenIsLibrary = true
                        }
                        PopupMenuRow(title: "Сменить фон", systemImage: "photo") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                activeMenu = .background
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 66)
                .padding(.trailing, 18)
            }

            if activeMenu == .background {
                popupMenu(title: "Сменить фон", anchor: .topTrailing) {
                    VStack(alignment: .leading, spacing: 2) {
                        PopupMenuRow(title: "Главный экран", systemImage: "iphone") {
                            withAnimation(nil) {
                                activeMenu = nil
                                chooseBackground(for: "home")
                            }
                        }
                        PopupMenuRow(title: "Библиотека", systemImage: "books.vertical.fill") {
                            withAnimation(nil) {
                                activeMenu = nil
                                chooseBackground(for: "library")
                            }
                        }
                        PopupMenuRow(title: "Назад", systemImage: "chevron.left") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                activeMenu = .options
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 66)
                .padding(.trailing, 18)
            }

            if activeMenu == .speed {
                popupMenu(title: "Скорость", anchor: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            PopupMenuRow(
                                title: speedLabel(value),
                                systemImage: nil,
                                isSelected: abs(speed - value) < 0.001
                            ) {
                                speed = value
                                player?.rate = value
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    activeMenu = nil
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 24)
                .padding(.bottom, 96)
            }

            if activeMenu == .sleepTimer {
                popupMenu(title: "Таймер сна", anchor: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(
                            [(0, "Выкл"), (5, "5 мин"), (10, "10 мин"), (15, "15 мин"),
                             (30, "30 мин"), (45, "45 мин"), (60, "1 час")],
                            id: \.0
                        ) { minutes, label in
                            PopupMenuRow(
                                title: label,
                                systemImage: nil,
                                isSelected: sleepTimerTotal == minutes
                            ) {
                                withAnimation(nil) {
                                    sleepTimerTotal = minutes
                                    setSleepTimer(minutes: minutes)
                                }
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    activeMenu = nil
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 108)
                .padding(.bottom, 96)
            }
        }
    }

    private func popupMenu<Content: View>(
        title: String?,
        anchor: UnitPoint,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(AppFont.italic(14))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            content()
        }
        .frame(width: 224, alignment: .leading)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.07, green: 0.09, blue: 0.17).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .transition(.scale(scale: 0.9, anchor: anchor).combined(with: .opacity))
    }

    private func speedLabel(_ value: Float) -> String {
        String(format: "%g×", value).replacingOccurrences(of: ".", with: ",")
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

            NeonWaveView(level: waveLevel, isPlaying: isPlaying)
                .frame(height: 96)
                .padding(.top, 4)

            Text(fileName)
                .font(AppFont.regular(17))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.top, 14)

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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                activeMenu = activeMenu == .speed ? nil : .speed
            }
        } label: {
            HStack(spacing: 5) {
                Text(speedLabel(speed))
                    .font(AppFont.regular(16))

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
        .buttonStyle(.plain)
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                activeMenu = activeMenu == .sleepTimer ? nil : .sleepTimer
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16, weight: .medium))

                if sleepTimerIsActive {
                    Text(sleepTimerCountdownText)
                        .font(AppFont.regular(16).monospacedDigit())
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

    // MARK: - Волна: замер громкости

    private func updateWaveLevel() {
        guard let player else {
            waveLevel *= 0.9
            return
        }

        player.updateMeters()

        // averagePower возвращает децибелы примерно от -160 (тишина) до 0 (максимум).
        // Рабочий диапазон для голоса диктора — примерно -50...-3 дБ.
        let db = Double(player.averagePower(forChannel: 0))

        var shaped: Double = 0
        if db.isFinite {
            shaped = (db + 50.0) / 47.0
            shaped = min(max(shaped, 0), 1)
            shaped = pow(shaped, 1.4)
        }

        if !player.isPlaying {
            shaped = 0
        }

        if shaped > waveLevel {
            // Быстрая атака: на громкие звуки волна отзывается живо
            waveLevel += (shaped - waveLevel) * 0.55
        } else {
            // Мягкий спад: на паузах между фразами не дёргается
            waveLevel += (shaped - waveLevel) * 0.12
        }

        if !player.isPlaying {
            // На паузе волна плавно затихает до лёгкого «дыхания»
            waveLevel *= 0.92
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
            newPlayer.enableRate = true
            newPlayer.isMeteringEnabled = true
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

// MARK: - Неоновая звуковая волна

struct NeonWaveView: View {
    var level: Double
    var isPlaying: Bool

    @State private var phase: Double = 0

    // Перерисовка волны: 30 кадров в секунду
    private let phaseTimer = Timer.publish(
        every: 1.0 / 30.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let maxAmplitude = size.height * 0.42

            // На паузе остаётся лёгкое «дыхание», при воспроизведении — реакция на громкость
            let idle: Double = isPlaying ? 0.06 : 0.14
            let base: Double = Double(maxAmplitude) * (idle + level * 0.9)

            let lines: [(color: Color, amp: Double, freq: Double, phaseOffset: Double)] = [
                (Color(red: 0.20, green: 0.85, blue: 0.90), 1.00, 1.00, 0.0),
                (Color(red: 0.20, green: 0.85, blue: 0.90), 0.68, 1.70, 1.3),
                (Color(red: 0.70, green: 0.42, blue: 1.00), 0.85, 1.35, 2.1),
                (Color(red: 0.70, green: 0.42, blue: 1.00), 0.55, 2.10, 0.7)
            ]

            for line in lines {
                let amplitude = CGFloat(base * line.amp)
                let path = wavePath(
                    size: size,
                    midY: midY,
                    amplitude: amplitude,
                    freq: line.freq,
                    phase: phase + line.phaseOffset
                )

                // Свечение: размытая копия линии в режиме plusLighter
                var glow = context
                glow.blendMode = .plusLighter
                glow.addFilter(.blur(radius: 7))
                glow.stroke(
                    path,
                    with: .color(line.color.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                )

                // Чёткая сердцевина линии
                context.stroke(
                    path,
                    with: .color(line.color.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
            }
        }
        .onReceive(phaseTimer) { _ in
            phase += isPlaying ? 0.10 : 0.025
        }
    }

    private func wavePath(
        size: CGSize,
        midY: CGFloat,
        amplitude: CGFloat,
        freq: Double,
        phase: Double
    ) -> Path {
        var path = Path()
        let steps = 64
        let width = size.width

        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = width * CGFloat(t)

            // Затухание у краёв, чтобы волна не упиралась в границы экрана
            let edge = pow(sin(CGFloat(t) * .pi), 0.85)

            let y1 = sin(t * .pi * 2.0 * freq + phase)
            let y2 = sin(t * .pi * 2.0 * freq * 2.3 + phase * 1.6)

            let y = midY
                + CGFloat(y1) * amplitude * edge
                + CGFloat(y2) * amplitude * 0.22 * edge

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
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
