import SwiftUI
import UniformTypeIdentifiers
import Compression

// MARK: - Модель электронной книги

struct EBook: Identifiable, Equatable {
    let id: String        // имя файла в хранилище
    let title: String     // читаемое название
    let fileName: String
}

enum EBookError: LocalizedError {
    case unsupported
    case damaged
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Формат файла не поддерживается"
        case .damaged:
            return "Файл книги повреждён"
        case .empty:
            return "В книге не найден текст"
        }
    }
}

// MARK: - Хранилище электронных книг

// Книги копируются в Documents/EBooks и переживают перезапуск приложения.
// Аудиобиблиотека не затрагивается: refreshLibrary() сканирует только корень
// Documents и отбирает файлы по аудио-расширениям, а книги лежат в подпапке.
@MainActor
final class EBookStore: ObservableObject {
    @Published var books: [EBook] = []

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var libraryURL: URL {
        documentsURL.appendingPathComponent("EBooks", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: true
        )
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil
        )) ?? []

        books = files
            .filter { ["epub", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }
            .map { url in
                EBook(
                    id: url.lastPathComponent,
                    title: url.deletingPathExtension().lastPathComponent,
                    fileName: url.lastPathComponent
                )
            }
    }

    // Копирует выбранный файл в постоянное хранилище и возвращает книгу
    func importBook(from sourceURL: URL) throws -> EBook {
        let ext = sourceURL.pathExtension.lowercased()

        guard ext == "epub" || ext == "txt" else {
            throw EBookError.unsupported
        }

        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent

        // Если книга с таким именем уже есть — добавляем суффикс
        var target = libraryURL.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 1

        while FileManager.default.fileExists(atPath: target.path) {
            target = libraryURL.appendingPathComponent(
                "\(baseName) (\(counter)).\(ext)"
            )
            counter += 1
        }

        try FileManager.default.copyItem(at: sourceURL, to: target)
        reload()

        return EBook(
            id: target.lastPathComponent,
            title: baseName,
            fileName: target.lastPathComponent
        )
    }

    // Возвращает текст книги по главам
    func loadChapters(for book: EBook) throws -> [String] {
        let url = libraryURL.appendingPathComponent(book.fileName)
        let data = try Data(contentsOf: url)

        switch url.pathExtension.lowercased() {
        case "txt":
            let text = EBookParser.parseTXT(data)
            guard !text.isEmpty else {
                throw EBookError.empty
            }
            return [text]
        case "epub":
            let chapters = try EBookParser.parseEPUB(data)
            guard !chapters.isEmpty else {
                throw EBookError.empty
            }
            return chapters
        default:
            throw EBookError.unsupported
        }
    }
}

// MARK: - Разбор электронных книг

enum EBookParser {
    // Кодировка Windows-1251 как резерв для TXT
    private static let cp1251 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCP1251.rawValue)
        )
    )

    static func parseTXT(_ data: Data) -> String {
        let text = decodeString(data)
        return normalizePlainText(text)
    }

    // MARK: EPUB

    // Лёгкий разбор EPUB (ZIP-контейнер) без сторонних зависимостей:
    // container.xml -> OPF -> порядок глав из spine -> чистый текст
    static func parseEPUB(_ data: Data) throws -> [String] {
        guard let files = readZipEntries(data), !files.isEmpty else {
            throw EBookError.damaged
        }

        guard
            let containerData = files["META-INF/container.xml"],
            let container = decodeString(containerData),
            !container.isEmpty,
            let opfPath = firstGroup(in: container, pattern: "full-path\\s*=\\s*\"([^\"]+)\""),
            let opfData = lookup(files, opfPath)
        else {
            throw EBookError.damaged
        }

        let opf = decodeString(opfData)
        let opfDirectory = opfPath.contains("/")
            ? String(opfPath[..<opfPath.lastIndex(of: "/")!])
            : ""

        // Манифест: id -> href и media-type
        var manifest: [String: (href: String, mediaType: String)] = [:]

        for tag in regexMatches(in: opf, pattern: "<item\\b[^>]*>") {
            guard
                let id = attribute("id", in: tag),
                let href = attribute("href", in: tag)
            else {
                continue
            }

            manifest[id] = (href, attribute("media-type", in: tag) ?? "")
        }

        // Порядок глав из spine
        var chapterPaths: [String] = []

        for tag in regexMatches(in: opf, pattern: "<itemref\\b[^>]*>") {
            guard let idref = attribute("idref", in: tag) else {
                continue
            }

            if let item = manifest[idref] {
                chapterPaths.append(item.href)
            }
        }

        // Резерв: если spine не найден — берём все HTML-файлы по алфавиту
        if chapterPaths.isEmpty {
            chapterPaths = files.keys
                .filter {
                    let ext = ($0 as NSString).pathExtension.lowercased()
                    return ["xhtml", "html", "htm"].contains(ext)
                }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        var chapters: [String] = []

        for href in chapterPaths {
            let resolved = resolvePath(base: opfDirectory, href: href)

            guard let fileData = lookup(files, resolved) else {
                continue
            }

            let text = stripHTML(decodeString(fileData))

            if !text.isEmpty {
                chapters.append(text)
            }
        }

        return chapters
    }

    // MARK: Разбор ZIP (минимальный, только то, что нужно для EPUB)

    private static func readZipEntries(_ data: Data) -> [String: Data]? {
        guard
            let eocdOffset = findEOCD(in: data),
            let totalEntries = readUInt16(data, at: eocdOffset + 10),
            let centralOffset = readUInt32(data, at: eocdOffset + 16)
        else {
            return nil
        }

        var result: [String: Data] = [:]
        var position = Int(centralOffset)

        for _ in 0..<Int(totalEntries) {
            guard
                position + 46 <= data.count,
                readUInt32(data, at: position) == 0x02014b50,
                let method = readUInt16(data, at: position + 10),
                let compressedSize = readUInt32(data, at: position + 20),
                let nameLength = readUInt16(data, at: position + 28),
                let extraLength = readUInt16(data, at: position + 30),
                let commentLength = readUInt16(data, at: position + 32),
                let headerOffset = readUInt32(data, at: position + 42)
            else {
                break
            }

            let nameStart = position + 46
            let nameEnd = nameStart + Int(nameLength)

            if nameEnd <= data.count,
               let rawName = data.subdata(in: nameStart..<nameEnd),
               let name = decodeZipName(rawName),
               !compressedSize.isNullMax,
               let entryData = extractFile(
                   data,
                   headerOffset: Int(headerOffset),
                   method: method,
                   compressedSize: Int(compressedSize)
               )
            {
                result[name] = entryData
            }

            position = nameEnd + Int(extraLength) + Int(commentLength)
        }

        return result.isEmpty ? nil : result
    }

    private static func findEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let searchLimit = max(0, data.count - 22 - 65_536)

        var index = data.count - 22

        while index >= searchLimit {
            if data[index] == signature[0],
               data[index + 1] == signature[1],
               data[index + 2] == signature[2],
               data[index + 3] == signature[3]
            {
                return index
            }

            index -= 1
        }

        return nil
    }

    private static func extractFile(
        _ data: Data,
        headerOffset: Int,
        method: UInt16,
        compressedSize: Int
    ) -> Data? {
        guard headerOffset + 30 <= data.count else {
            return nil
        }

        guard readUInt32(data, at: headerOffset) == 0x04034b50 else {
            return nil
        }

        guard
            let nameLength = readUInt16(data, at: headerOffset + 26),
            let extraLength = readUInt16(data, at: headerOffset + 28)
        else {
            return nil
        }

        let start = headerOffset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + compressedSize

        guard start <= data.count, end <= data.count else {
            return nil
        }

        let chunk = data.subdata(in: start..<end)

        switch method {
        case 0:
            return chunk
        case 8:
            return inflate(chunk)
        default:
            return nil
        }
    }

    // Распаковка deflate (метод ZIP 8) через системный Compression
    private static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else {
            return Data()
        }

        var outputCapacity = max(64 * 1024, input.count * 4)

        while outputCapacity <= 128 * 1024 * 1024 {
            var output = Data(count: outputCapacity)
            var status = COMPRESSION_STATUS_OK
            var written = 0

            input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                    guard
                        let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                        let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress
                    else {
                        status = COMPRESSION_STATUS_ERROR
                        return
                    }

                    var stream = compression_stream(
                        dst_ptr: destinationBase,
                        dst_size: outputCapacity,
                        src_ptr: sourceBase,
                        src_size: input.count,
                        state: nil
                    )

                    status = compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE)
                    )
                    written = outputCapacity - stream.dst_size
                }
            }

            if status == COMPRESSION_STATUS_END {
                return output.prefix(written)
            }

            if status == COMPRESSION_STATUS_OK && written == outputCapacity {
                outputCapacity *= 2
                continue
            }

            return nil
        }

        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else {
            return nil
        }

        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }

        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func decodeZipName(_ data: Data) -> String? {
        if let name = String(data: data, encoding: .utf8) {
            return name
        }

        return String(data: data, encoding: cp1251)
    }

    // Поиск по архиву с нормализацией и резервом по регистру
    private static func lookup(_ files: [String: Data], _ path: String) -> Data? {
        if let exact = files[path] {
            return exact
        }

        let normalized = normalizePath(path)

        if let hit = files[normalized] {
            return hit
        }

        let lowered = normalized.lowercased()

        for (key, value) in files where key.lowercased() == lowered {
            return value
        }

        return nil
    }

    private static func resolvePath(base: String, href: String) -> String {
        var cleaned = href.removingPercentEncoding ?? href

        if cleaned.hasPrefix("/") {
            cleaned.removeFirst()
        }

        if base.isEmpty {
            return cleaned
        }

        return normalizePath(base + "/" + cleaned)
    }

    private static func normalizePath(_ path: String) -> String {
        var result: [String] = []

        for part in path.split(separator: "/").map(String.init) {
            if part == ".." {
                result.removeLast()
            } else if part != "." && !part.isEmpty {
                result.append(part)
            }
        }

        return result.joined(separator: "/")
    }

    // MARK: Текст

    private static func decodeString(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let text = String(data: data, encoding: cp1251) {
            return text
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func normalizePlainText(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = result
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(
                    of: "\\s+",
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            }

        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Превращает XHTML/HTML главу в читаемый текст
    static func stripHTML(_ html: String) -> String {
        var result = html

        result = result.replacingOccurrences(
            of: "(?is)<(script|style|head)[^>]*>.*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)</(p|div|h[1-6]|li|tr|blockquote)>",
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)<br[^>]*>",
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        result = decodeEntities(result)

        let lines = result
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(
                    of: "\\s+",
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n\n")
    }

    private static func decodeEntities(_ string: String) -> String {
        var result = replaceRegex(string, pattern: "&#(\\d+);") { value in
            guard let code = UInt32(value), let scalar = Unicode.Scalar(code) else {
                return ""
            }
            return String(Character(scalar))
        }

        result = replaceRegex(result, pattern: "&#x([0-9a-fA-F]+);") { value in
            guard
                let code = UInt32(value, radix: 16),
                let scalar = Unicode.Scalar(code)
            else {
                return ""
            }
            return String(Character(scalar))
        }

        let named: [String: String] = [
            "amp": "&",
            "lt": "<",
            "gt": ">",
            "quot": "\"",
            "apos": "'",
            "nbsp": "\u{00A0}",
            "mdash": "\u{2014}",
            "ndash": "\u{2013}",
            "hellip": "\u{2026}",
            "laquo": "\u{00AB}",
            "raquo": "\u{00BB}",
            "ldquo": "\u{201C}",
            "rdquo": "\u{201D}",
            "lsquo": "\u{2018}",
            "rsquo": "\u{2019}",
            "middot": "\u{00B7}",
            "bull": "\u{2022}"
        ]

        result = replaceRegex(result, pattern: "&([a-zA-Z]+);") { value in
            named[value] ?? ""
        }

        return result
    }

    private static func replaceRegex(
        _ string: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            !string.isEmpty
        else {
            return string
        }

        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var pieces: [String] = []
        var cursor = 0

        for match in regex.matches(in: string, range: range) {
            pieces.append(
                nsString.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            )
            pieces.append(transform(nsString.substring(with: match.range(at: 1))))
            cursor = match.range.location + match.range.length
        }

        pieces.append(nsString.substring(from: cursor))

        return pieces.joined()
    }

    private static func regexMatches(in string: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsString = string as NSString
        return regex
            .matches(
                in: string,
                range: NSRange(location: 0, length: nsString.length)
            )
            .map { nsString.substring(with: $0.range) }
    }

    private static func firstGroup(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsString = string as NSString

        guard
            let match = regex.firstMatch(
                in: string,
                range: NSRange(location: 0, length: nsString.length)
            ),
            match.range(at: 1).location != NSNotFound
        else {
            return nil
        }

        return nsString.substring(with: match.range(at: 1))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstGroup(
            in: tag,
            pattern: #"\b\#(name)\s*=\s*"([^"]*)""#
        ) ?? firstGroup(
            in: tag,
            pattern: #"\b\#(name)\s*=\s*'([^']*)'"#
        )
    }
}

extension UInt32 {
    // 0xFFFFFFFF в поле размера — признак ZIP64, такие записи пропускаем
    var isNullMax: Bool {
        self == 0xFFFFFFFF
    }
}

// MARK: - Экран чтения электронных книг

struct ReadingScreenView: View {
    @ObservedObject var store: EBookStore
    let onBack: () -> Void

    @EnvironmentObject private var theme: PlayTheme

    @State private var selectedBook: EBook?
    @State private var chapters: [String] = []
    @State private var isMenuOpen = false
    @State private var isShowingImporter = false
    @State private var isBusy = false
    @State private var errorMessage = ""

    // EPUB объявляем по UTI, чтобы не зависеть от варианта SDK
    private let bookTypes: [UTType] = [
        UTType("org.idpf.epub-container"),
        .plainText
    ]
    .compactMap { $0 }

    var body: some View {
        ZStack {
            if let book = selectedBook {
                readerView(book: book)
            } else {
                bookListView
            }

            if isBusy {
                ZStack {
                    Color.black.opacity(0.35)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(theme.ui)
                        .scaleEffect(1.3)
                }
                .transition(.opacity)
            }

            menuOverlay
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: isBusy)
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: bookTypes,
            allowsMultipleSelection: false
        ) { result in
            importBook(result)
        }
    }

    // MARK: Кнопки верхней панели

    private var backOverlay: some View {
        VStack {
            HStack {
                Button {
                    if selectedBook != nil {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedBook = nil
                            chapters = []
                        }
                    } else {
                        onBack()
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

                Spacer()
            }
            .padding(.top, 12)
            .padding(.horizontal, 18)

            Spacer()
        }
    }

    private var dotsOverlay: some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isMenuOpen.toggle()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.ui)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 18)

            Spacer()
        }
    }

    // Меню из трёх точек — в том же стиле и с теми же отступами,
    // что и меню на главном экране (top 66 / trailing 18)
    private var menuOverlay: some View {
        ZStack {
            if isMenuOpen {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isMenuOpen = false
                        }
                    }
            }

            VStack {
                HStack {
                    Spacer()

                    if isMenuOpen {
                        CustomMenu(
                            title: nil,
                            options: [
                                CustomMenuOption(
                                    title: "Добавить книгу",
                                    systemImage: "doc.badge.plus"
                                ) {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isMenuOpen = false
                                    }
                                    isShowingImporter = true
                                }
                            ],
                            selectedIndex: nil,
                            onSelect: { _ in },
                            onClose: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isMenuOpen = false
                                }
                            }
                        )
                    }
                }
                .padding(.top, 66)
                .padding(.trailing, 18)

                Spacer()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isMenuOpen)
    }

    // MARK: Список книг

    private var bookListView: some View {
        ZStack {
            backOverlay
            dotsOverlay

            VStack(alignment: .leading, spacing: 0) {
                Text("Мои книги")
                    .font(AppFont.bold(26))
                    .foregroundStyle(.white)
                    .padding(.top, 72)

                if store.books.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.ui.opacity(0.7))

                        Text("Пока нет электронных книг")
                            .font(AppFont.bold(17))
                            .foregroundStyle(.white.opacity(0.9))

                        Text("Нажмите на меню \u{22EF} сверху\nи выберите «Добавить книгу»")
                            .font(AppFont.regular(14))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 90)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.books) { book in
                                bookRow(book)
                            }
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 40)
                    }
                    .padding(.top, 8)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(AppFont.regular(13))
                        .padding(.top, 10)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private func bookRow(_ book: EBook) -> some View {
        Button {
            open(book)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: book.fileName.hasSuffix(".epub") ? "book.closed" : "doc.text")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.ui)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(AppFont.bold(16))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(book.fileName.hasSuffix(".epub") ? "EPUB" : "TXT")
                        .font(AppFont.regular(12))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Чтение книги

    private func readerView(book: EBook) -> some View {
        ZStack {
            VStack(spacing: 0) {
                // Название книги в центре верхней панели
                Text(book.title)
                    .font(AppFont.italic(15))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.top, 16)
                    .padding(.horizontal, 68)

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(chapters.indices, id: \.self) { index in
                            if chapters.count > 1 {
                                Text("Глава \(index + 1)")
                                    .font(AppFont.bold(17))
                                    .foregroundStyle(theme.ui)
                            }

                            Text(chapters[index])
                                .font(AppFont.regular(17))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineSpacing(7)
                        }
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 60)
                    .padding(.horizontal, 24)
                }
            }

            backOverlay
            dotsOverlay
        }
    }

    // MARK: Действия

    private func open(_ book: EBook) {
        isBusy = true
        errorMessage = ""

        Task {
            do {
                let loaded = try store.loadChapters(for: book)

                withAnimation(.easeOut(duration: 0.2)) {
                    chapters = loaded
                    selectedBook = book
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            isBusy = false
        }
    }

    private func importBook(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            isBusy = true
            errorMessage = ""

            Task {
                do {
                    let book = try store.importBook(from: url)
                    let loaded = try store.loadChapters(for: book)

                    withAnimation(.easeOut(duration: 0.2)) {
                        chapters = loaded
                        selectedBook = book
                    }
                } catch {
                    store.reload()
                    errorMessage = error.localizedDescription
                }

                isBusy = false
            }
        case .failure:
            errorMessage = "Не удалось выбрать файл"
        }
    }
}
