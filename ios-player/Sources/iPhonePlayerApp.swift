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

// MARK: - Тема (единый источник цветов всего интерфейса)

final class PlayTheme: ObservableObject {
    static let shared = PlayTheme()

    // Фирменный цвет PlayBook по умолчанию
    static let defaultAccent = Color(red: 0.20, green: 0.55, blue: 1.0)

    // Готовые цветовые варианты
    static let presets: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 1.00), // фирменный синий
        Color(red: 0.30, green: 0.85, blue: 0.95), // циан
        Color(red: 0.30, green: 0.90, blue: 0.60), // мята
        Color(red: 0.55, green: 0.90, blue: 0.40), // зелёный
        Color(red: 0.95, green: 0.80, blue: 0.35), // золотистый
        Color(red: 1.00, green: 0.60, blue: 0.35), // оранжевый
        Color(red: 0.95, green: 0.45, blue: 0.55), // розовый
        Color(red: 0.80, green: 0.45, blue: 1.00), // сиреневый
        Color(red: 0.55, green: 0.55, blue: 0.95), // индиго
        Color(red: 1.00, green: 0.35, blue: 0.35)  // красный
    ]

    @Published var accentColor: Color

    private init() {
        if let hex = UserDefaults.standard.string(forKey: "playbook.accentColor"),
           let color = Color(hex: hex) {
            accentColor = color
        } else {
            accentColor = Self.defaultAccent
        }
    }

    func saveAccent() {
        UserDefaults.standard.set(accentColor.toHex(), forKey: "playbook.accentColor")
    }

    func resetAccent() {
        UserDefaults.standard.removeObject(forKey: "playbook.accentColor")
        accentColor = Self.defaultAccent
    }

    var isDefaultAccent: Bool {
        accentColor.toHex() == Self.defaultAccent.toHex()
    }

    // Вариант цвета, гарантированно читаемый на тёмном фоне
    var ui: Color {
        Self.readable(accentColor)
    }

    static func luminance(of color: Color) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
    }

    // Если цвет слишком тёмный — осветляем до минимальной яркости,
    // чтобы текст и значки оставались читаемыми
    static func readable(_ color: Color) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let luma = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        let minLuminance = 0.62

        guard luma < minLuminance else { return color }

        let t = (minLuminance - luma) / (1.0 - luma)
        return mix(color, .white, t)
    }

    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = CGFloat(min(max(t, 0), 1))

        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)

        return Color(
            red: Double(ar + (br - ar) * t),
            green: Double(ag + (bg - ag) * t),
            blue: Double(ab + (bb - ab) * t)
        )
    }
}

// MARK: - HEX-представление цвета

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    func toHex() -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}

@main
struct iPhonePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

enum ActiveMenu {
    case none
    case main
    case speed
    case sleep
    case bookmark
}

struct ContentView: View {
    @ObservedObject private var theme = PlayTheme.shared
    @StateObject private var ebookStore = EBookStore()

    @State private var player: AVAudioPlayer?
    @State private var fileName = "Аудиокнига не выбрана"
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var speed: Float = 1.0
    @State private var showingImporter = false
    @State private var showingEbookImporter = false
    @State private var libraryFiles: [URL] = []
    @State private var currentScreenIsLibrary = false
    @State private var currentScreenIsSettings = false
    @State private var currentScreenIsColor = false
    @State private var currentScreenIsReading = false
    @State private var readingBook: EBook?
    @State private var readingOriginIsLibrary = false
    @State private var isDesignSectionExpanded = false
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
    @State private var sleepBookmarkPosition: Double = 0
    @State private var sleepBookmarkFileName: String = ""

    // Ползунок
    @State private var isSeeking = false

    // Фон
    @State private var homeBackground: UIImage?
    @State private var libraryBackground: UIImage?
    @State private var settingsBackground: UIImage?
    @State private var showingBackgroundPicker = false
    @State private var backgroundTarget = "home"

    // Собственные меню
    @State private var activeMenu: ActiveMenu = .none

    // Волна
    @State private var waveLevel: Double = 0
    @State private var smoothLevel: Double = 0

    private let timer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common
    ).autoconnect()

    private let waveTimer = Timer.publish(
        every: 0.05,
        on: .main,
        in: .common
    ).autoconnect()

    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac",
        "wav", "aiff", "caf", "flac"
    ]

    private let speedOptions: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let sleepOptions: [Int] = [0, 5, 10, 15, 30, 45, 60]

    var body: some View {
        ZStack {
            background

            if currentScreenIsColor {
                colorSettingsView
            } else if currentScreenIsLibrary {
                libraryView
            } else if currentScreenIsSettings {
                settingsView
            } else if currentScreenIsReading {
                ReadingScreenView(
                    store: ebookStore,
                    initialBook: readingBook
                ) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        currentScreenIsReading = false

                        if readingOriginIsLibrary {
                            currentScreenIsLibrary = true
                        }

                        readingBook = nil
                        readingOriginIsLibrary = false
                    }
                }
            } else {
                playerView
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            loadBackgrounds()

            sleepBookmarkPosition = UserDefaults.standard.double(
                forKey: "playbook.sleepBookmarkPosition"
            )
            sleepBookmarkFileName = UserDefaults.standard.string(
                forKey: "playbook.sleepBookmarkFileName"
            ) ?? ""

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
            if currentScreenIsReading {
                EmptyView()
            } else {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        activeMenu = activeMenu == .main ? .none : .main
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.ui)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .padding(.top, 12)
                .padding(.trailing, 18)
            }
        }
        .overlay(alignment: .topLeading) {
            if currentScreenIsColor {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        currentScreenIsColor = false
                    }
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.ui)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.leading, 18)
            } else if currentScreenIsLibrary || currentScreenIsSettings {
                Button {
                    if currentScreenIsSettings {
                        currentScreenIsSettings = false
                        currentScreenIsColor = false
                        isDesignSectionExpanded = false
                    } else {
                        currentScreenIsLibrary = false
                    }
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.ui)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .padding(.leading, 18)
            } else if !currentScreenIsReading {
                Button {
                    refreshLibrary()
                    currentScreenIsLibrary = true
                } label: {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.ui)
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
        .onChange(of: theme.accentColor) { _ in
            theme.saveAccent()
        }
        .environmentObject(theme)
    }

    // MARK: - Меню

    @ViewBuilder
    private var menuOverlay: some View {
        ZStack {
            if activeMenu != .none {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            activeMenu = .none
                        }
                    }
            }

            switch activeMenu {
            case .main:
                VStack {
                    HStack {
                        Spacer()
                        mainMenu
                    }
                    .padding(.top, 66)
                    .padding(.trailing, 18)

                    Spacer()
                }
            case .speed:
                VStack {
                    Spacer()
                    HStack {
                        speedMenu
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.bottom, 108)
                }
            case .sleep:
                VStack {
                    Spacer()
                    HStack {
                        sleepMenu
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.bottom, 108)
                }
            case .bookmark:
                VStack {
                    Spacer()
                    HStack {
                        bookmarkMenu
                        Spacer()
                    }
                    .padding(.leading, 24)
                    .padding(.bottom, 108)
                }
            case .none:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: activeMenu)
    }

    private var mainMenu: some View {
        CustomMenu(
            title: nil,
            options: [
                CustomMenuOption(title: "Настройки", systemImage: "gearshape") {
                    activeMenu = .none
                    isDesignSectionExpanded = false
                    currentScreenIsColor = false
                    currentScreenIsSettings = true
                }
            ],
            selectedIndex: nil,
            onSelect: { _ in },
            onClose: {
                withAnimation(.easeOut(duration: 0.2)) {
                    activeMenu = .none
                }
            }
        )
    }

    private var speedMenu: some View {
        CustomMenu(
            title: "Скорость",
            options: speedOptions.map { value in
                CustomMenuOption(
                    title: String(format: "%g×", Double(value)),
                    systemImage: "gauge"
                ) {
                    speed = value
                    player?.rate = value
                    withAnimation(.easeOut(duration: 0.2)) {
                        activeMenu = .none
                    }
                }
            },
            selectedIndex: speedOptions.firstIndex(of: speed),
            onSelect: { _ in },
            onClose: {
                withAnimation(.easeOut(duration: 0.2)) {
                    activeMenu = .none
                }
            }
        )
    }

    private var sleepMenu: some View {
        CustomMenu(
            title: "Таймер сна",
            options: sleepOptions.map { minutes in
                CustomMenuOption(
                    title: minutes == 0 ? "Выкл" : (minutes >= 60 ? "1 час" : "\(minutes) мин"),
                    systemImage: "moon.zzz"
                ) {
                    sleepTimerTotal = minutes
                    setSleepTimer(minutes: minutes)
                    withAnimation(.easeOut(duration: 0.2)) {
                        activeMenu = .none
                    }
                }
            },
            selectedIndex: sleepOptions.firstIndex(of: sleepTimerTotal),
            onSelect: { _ in },
            onClose: {
                withAnimation(.easeOut(duration: 0.2)) {
                    activeMenu = .none
                }
            }
        )
    }

    private var bookmarkMenu: some View {
        CustomMenu(
            title: "Закладка",
            options: [
                CustomMenuOption(
                    title: sleepBookmarkFileName.isEmpty
                        ? "Пока нет сохранённой позиции"
                        : "Таймер сна был включён в \(timeString(sleepBookmarkPosition))",
                    systemImage: "bookmark"
                ) {
                    goToSleepBookmark()
                }
            ],
            selectedIndex: nil,
            onSelect: { _ in },
            onClose: {
                withAnimation(.easeOut(duration: 0.2)) {
                    activeMenu = .none
                }
            }
        )
    }

    // MARK: - Фон

    private func backgroundFileName(for screen: String) -> String {
        switch screen {
        case "library":
            return "playbook.background.library.jpg"
        case "settings":
            return "playbook.background.settings.jpg"
        default:
            return "playbook.background.home.jpg"
        }
    }

    private var background: some View {
        ZStack {
            if currentScreenIsColor || currentScreenIsSettings {
                backgroundLayer(image: settingsBackground)
            } else if currentScreenIsReading {
                backgroundLayer(image: homeBackground)
            } else if currentScreenIsLibrary {
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

            let name = backgroundFileName(for: screen)
            let url = documents.appendingPathComponent(name)

            try? data.write(to: url)

            DispatchQueue.main.async {
                switch screen {
                case "home":
                    homeBackground = scaledImage
                case "library":
                    libraryBackground = scaledImage
                default:
                    settingsBackground = scaledImage
                }
                refreshLibrary()
            }
        }
    }

    private func resetBackground(for screen: String) {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let name = backgroundFileName(for: screen)
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))

        switch screen {
        case "home":
            homeBackground = nil
        case "library":
            libraryBackground = nil
        default:
            settingsBackground = nil
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

            let home = loadImage(backgroundFileName(for: "home"))
            let library = loadImage(backgroundFileName(for: "library"))
            let settings = loadImage(backgroundFileName(for: "settings"))

            DispatchQueue.main.async {
                homeBackground = home
                libraryBackground = library
                settingsBackground = settings
            }
        }
    }

    // MARK: - Волна

    private func updateWaveLevel() {
        guard let player, player.isPlaying else {
            // На паузе волна плавно затухает до лёгкого «дыхания»
            smoothLevel *= 0.92
            if smoothLevel < 0.005 {
                smoothLevel = 0
            }
            waveLevel = smoothLevel
            return
        }

        player.updateMeters()
        let db = Double(player.averagePower(forChannel: 0))

        // Порог -60 дБ: реагируем даже на тихую речь
        var shaped = max(0, (db + 60.0) / 60.0)
        shaped = min(shaped, 1.0)
        shaped = pow(shaped, 1.4) * 1.5
        shaped = min(shaped, 1.0)

        if shaped > smoothLevel {
            smoothLevel += (shaped - smoothLevel) * 0.65
        } else {
            smoothLevel += (shaped - smoothLevel) * 0.16
        }

        waveLevel = smoothLevel
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
                .foregroundStyle(theme.ui)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            NeonWaveView(level: waveLevel)
                .padding(.top, 14)

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
                        .foregroundStyle(theme.ui.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(timeString(duration))
                        .font(AppFont.regular(13).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 20)

            ZStack(alignment: .trailing) {
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
                        .foregroundStyle(theme.ui)
                    }
                    .disabled(player == nil)

                    seekButton(seconds: 15, symbol: "goforward.15")
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button {
                    readingBook = nil
                    readingOriginIsLibrary = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        currentScreenIsReading = true
                    }
                } label: {
                    Image(systemName: "book.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.ui)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
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
                    bookmarkButton
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                activeMenu = activeMenu == .speed ? .none : .speed
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(speed, specifier: "%g")×")
                    .font(AppFont.regular(16))

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.ui)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(theme.ui.opacity(0.8), lineWidth: 1)
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

    private var sleepTimerButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                activeMenu = activeMenu == .sleep ? .none : .sleep
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
            .foregroundStyle(theme.ui)
            .padding(.horizontal, sleepTimerIsActive ? 16 : 14)
            .frame(height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(theme.ui.opacity(0.8), lineWidth: 1)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: sleepTimerIsActive)
        }
        .buttonStyle(.plain)
    }

    private var bookmarkButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                activeMenu = activeMenu == .bookmark ? .none : .bookmark
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bookmark")
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(theme.ui)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(theme.ui.opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func goToSleepBookmark() {
        withAnimation(.easeOut(duration: 0.2)) {
            activeMenu = .none
        }

        guard !sleepBookmarkFileName.isEmpty else {
            errorMessage = "Пока нет сохранённой позиции"
            return
        }

        guard let player else {
            errorMessage = "Сначала выберите аудиокнигу"
            return
        }

        guard fileName == sleepBookmarkFileName else {
            errorMessage = "Закладка относится к другой книге"
            return
        }

        let target = max(0, min(sleepBookmarkPosition, player.duration))

        player.currentTime = target
        progress = target

        UserDefaults.standard.set(target, forKey: "playbook.lastPosition")
        UserDefaults.standard.set(fileName, forKey: "playbook.lastFileName")
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

        // Закладка: позиция последнего включения таймера сна
        sleepBookmarkPosition = sleepTimerStartedPosition
        sleepBookmarkFileName = fileName

        UserDefaults.standard.set(
            sleepBookmarkPosition,
            forKey: "playbook.sleepBookmarkPosition"
        )
        UserDefaults.standard.set(
            sleepBookmarkFileName,
            forKey: "playbook.sleepBookmarkFileName"
        )
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
                .foregroundStyle(theme.ui)

            if libraryFiles.isEmpty && folders.isEmpty && ebookStore.books.isEmpty {
                Text("Пока нет книг")
                    .font(AppFont.regular(15))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                List {
                    if let selectedFolder {
                        Button {
                            self.selectedFolder = nil
                        } label: {
                            Label("Назад к библиотеке", systemImage: "chevron.left")
                                .font(AppFont.regular(16))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white.opacity(0.08))

                        Text(selectedFolder)
                            .font(AppFont.bold(17))
                            .foregroundStyle(theme.ui)
                            .listRowBackground(Color.white.opacity(0.08))
                    } else {
                        ForEach(folders, id: \.self) { folder in
                            Button {
                                selectedFolder = folder
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(theme.ui)
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

                    if selectedFolder == nil && !ebookStore.books.isEmpty {
                        Text("Электронные книги")
                            .font(AppFont.italic(13))
                            .foregroundStyle(.white.opacity(0.55))
                            .listRowBackground(Color.clear)

                        ForEach(ebookStore.books) { book in
                            Button {
                                readingBook = book
                                readingOriginIsLibrary = true
                                currentScreenIsLibrary = false
                                withAnimation(.easeOut(duration: 0.2)) {
                                    currentScreenIsReading = true
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(theme.ui)

                                    Text(book.title)
                                        .font(AppFont.regular(17))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.white.opacity(0.08))
                            .contextMenu {
                                Button(role: .destructive) {
                                    ebookStore.removeBook(book)
                                } label: {
                                    Label("Удалить книгу", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }

            if let error = ebookStore.errorMessage {
                Text(error)
                    .font(AppFont.regular(13))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.75))
                    .cornerRadius(12)
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
                        .foregroundStyle(theme.ui)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay {
                            Capsule()
                                .stroke(
                                    theme.ui.opacity(0.8),
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)

                Button {
                    showingEbookImporter = true
                } label: {
                    Image(systemName: "book.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.ui)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay {
                            Capsule()
                                .stroke(
                                    theme.ui.opacity(0.8),
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
        .fileImporter(
            isPresented: $showingEbookImporter,
            allowedContentTypes: [.epub, .plainText, EBookFileType.fb2],
            allowsMultipleSelection: false
        ) { result in
            ebookStore.importBook(from: result)
        }
        .onAppear {
            loadFolders()
        }
    }

    // MARK: - Настройки

    private var settingsView: some View {
        VStack(spacing: 16) {
            Text("Настройки")
                .font(AppFont.bold(34))
                .foregroundStyle(theme.ui)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isDesignSectionExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("ДИЗАЙН")
                        .font(AppFont.regular(17))
                        .foregroundStyle(theme.ui)

                    Spacer()

                    Image(systemName: isDesignSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            if isDesignSectionExpanded {
                VStack(spacing: 2) {
                    backgroundRow("Фон главного экрана", target: "home")
                    backgroundRow("Фон библиотеки", target: "library")
                    backgroundRow("Фон настроек", target: "settings")
                }
                .transition(.opacity)
            }

            Button {
                currentScreenIsColor = true
            } label: {
                HStack {
                    Text("ЦВЕТ")
                        .font(AppFont.regular(17))
                        .foregroundStyle(theme.ui)

                    Spacer()

                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                        .padding(.trailing, 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Строка выбора фона: тап — открыть Файлы, длинное нажатие — сбросить фон
    private func backgroundRow(_ title: String, target: String) -> some View {
        Button {
            chooseBackground(for: target)
        } label: {
            HStack {
                Text(title)
                    .font(AppFont.regular(16))
                    .foregroundStyle(.white)

                Spacer()

                if backgroundImage(for: target) != nil {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.ui.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                resetBackground(for: target)
            } label: {
                Label("Вернуть стандартный градиент", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func backgroundImage(for screen: String) -> UIImage? {
        switch screen {
        case "home":
            return homeBackground
        case "library":
            return libraryBackground
        default:
            return settingsBackground
        }
    }

    // MARK: - Настройка цвета

    private var colorSettingsView: some View {
        VStack(spacing: 16) {
            Text("ЦВЕТ")
                .font(AppFont.bold(34))
                .foregroundStyle(theme.ui)

            // Текущий выбранный цвет
            HStack(spacing: 12) {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.5), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Текущий цвет")
                        .font(AppFont.regular(13))
                        .foregroundStyle(.white.opacity(0.7))

                    Text(theme.accentColor.toHex())
                        .font(AppFont.regular(16).monospacedDigit())
                        .foregroundStyle(.white)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
            )

            // Готовые цветовые варианты
            VStack(alignment: .leading, spacing: 10) {
                Text("Готовые цвета")
                    .font(AppFont.regular(13))
                    .foregroundStyle(.white.opacity(0.7))

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12),
                        count: 5
                    ),
                    spacing: 12
                ) {
                    ForEach(Array(PlayTheme.presets.enumerated()), id: \.offset) { _, color in
                        Button {
                            theme.accentColor = color
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(color)
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                                    )

                                if theme.accentColor.toHex() == color.toHex() {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(
                                            PlayTheme.luminance(of: color) > 0.6
                                                ? Color.black
                                                : Color.white
                                        )
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
            )

            // Произвольный цвет через системный селектор
            HStack {
                Text("Свой цвет")
                    .font(AppFont.regular(16))
                    .foregroundStyle(.white)

                Spacer()

                ColorPicker("", selection: $theme.accentColor, supportsOpacity: false)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
            )

            // Возврат к стандартным цветам PlayBook
            Button {
                theme.resetAccent()
            } label: {
                HStack {
                    Text("Вернуть стандартные цвета PlayBook")
                        .font(AppFont.regular(16))
                        .foregroundStyle(theme.ui)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(theme.isDefaultAccent)
            .opacity(theme.isDefaultAccent ? 0.5 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func seekButton(seconds: Double, symbol: String) -> some View {
        Button {
            seek(by: seconds)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(theme.ui)
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

        guard audioExtensions.contains(url.pathExtension.lowercased()) else {
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

        guard audioExtensions.contains(url.pathExtension.lowercased()) else {
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

// MARK: - Неоновая волна

struct NeonWaveView: View {
    @EnvironmentObject private var theme: PlayTheme

    let level: Double

    @State private var phase: Double = 0

    private let strandCount = 22
    private let viewHeight: CGFloat = 96
    private let amplitudeShare: CGFloat = 0.40

    private let phaseTimer = Timer.publish(
        every: 1.0 / 30.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        ZStack {
            glowCanvas
            sharpCanvas
        }
        .frame(height: viewHeight)
        .onReceive(phaseTimer) { _ in
            phase += 0.085
        }
    }

    private var sharpCanvas: some View {
        Canvas { context, size in
            drawStrands(context: context, size: size)
        }
        .frame(height: viewHeight)
    }

    private var glowCanvas: some View {
        Canvas { context, size in
            drawStrands(context: context, size: size)
        }
        .frame(height: viewHeight)
        .blur(radius: 7)
        .blendMode(.plusLighter)
        .opacity(0.85)
    }

    private func drawStrands(context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let width = max(size.width, 1)
        let levelAmp = CGFloat(level) * amplitudeShare * size.height
        let idleAmp = size.height * 0.045

        for i in 0..<strandCount {
            let t = CGFloat(i) / CGFloat(strandCount - 1)
            let spread = t - 0.5
            let phaseOffset = t * 1.7
            let wobble = abs(sin(phase * 0.7 + t * 3.1))

            let amp = levelAmp * (0.55 + 0.45 * wobble)
                + idleAmp * (0.5 + 0.5 * abs(spread))

            var path = Path()
            let steps = 64
            for step in 0...steps {
                let x = width * CGFloat(step) / CGFloat(steps)
                let edgeFade = sin(.pi * CGFloat(step) / CGFloat(steps))

                let y = midY
                    + sin(phase + x * 0.016 + phaseOffset) * amp * edgeFade
                    + sin(phase * 1.6 + x * 0.029 + spread * 2.4) * amp * 0.45 * edgeFade
                    + spread * size.height * (0.10 + 0.14 * CGFloat(level))

                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(
                path,
                with: .color(strandColor(t).opacity(0.7)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
            )
        }
    }

    private func strandColor(_ t: CGFloat) -> Color {
        // Плавный переход от выбранного цвета к его светлому оттенку
        PlayTheme.mix(theme.accentColor, .white, Double(t) * 0.75)
    }
}

// MARK: - Меню

struct CustomMenuOption {
    let title: String
    let systemImage: String
    let action: () -> Void
}

struct CustomMenu: View {
    @EnvironmentObject private var theme: PlayTheme

    let title: String?
    let options: [CustomMenuOption]
    let selectedIndex: Int?
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(AppFont.italic(13))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }

            ForEach(options.indices, id: \.self) { index in
                Button {
                    onSelect(index)
                    options[index].action()
                } label: {
                    HStack {
                        Label(options[index].title, systemImage: options[index].systemImage)
                            .font(AppFont.regular(15))

                        Spacer()

                        if index == selectedIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.ui)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.06, green: 0.07, blue: 0.16).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(theme.ui.opacity(0.25), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 18)
        .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
    }
}

// Тонкий ползунок с маленьким кружком
struct SlimSlider: View {
    @EnvironmentObject private var theme: PlayTheme

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
                    .fill(theme.accentColor)
                    .frame(width: max(0, width * fraction), height: trackHeight)

                Circle()
                    .fill(theme.accentColor)
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
