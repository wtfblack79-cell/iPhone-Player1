import SwiftUI
import UniformTypeIdentifiers
import Compression

// MARK: - Модель электронной книги

struct EBook: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let title: String
}

// MARK: - Хранилище электронных книг

@MainActor
final class EBookStore: ObservableObject {
    @Published private(set) var books: [EBook] = []
    @Published var lastError: String?

    // Книги лежат в отдельной подпапке Documents, чтобы не попадать
    // в сканирование аудиобиблиотеки (оно смотрит только корень Documents)
    static let booksDirectory: URL = {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let directory = documents.appendingPathComponent("EBooks", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        return directory
    }()

    private var manifestURL: URL {
        Self.booksDirectory.appendingPathComponent("library.json")
    }

    init() {
        loadManifest()
    }

    func reload() {
        loadManifest()
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL) else {
            books = []
            return
        }

        books = (try? JSONDecoder().decode([EBook].self, from: data)) ?? []
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(books) else {
            return
        }

        try? data.write(to: manifestURL, options: .atomic)
    }

    @discardableResult
    func importBook(from sourceURL: URL) -> EBook? {
        lastError = nil

        let needsAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let rawName = sourceURL.lastPathComponent
        let ext = (rawName as NSString).pathExtension.lowercased()

        guard ext == "epub" || ext == "txt" else {
            lastError = "Поддерживаются только книги в форматах EPUB и TXT"
            return nil
        }

        guard let data = try? Data(contentsOf: sourceURL) else {
            lastError = "Не удалось прочитать файл книги"
            return nil
        }

        guard let parsed = EBookParser.parse(data: data, fileExtension: ext) else {
            lastError = "Не удалось разобрать книгу. Возможно, файл повреждён"
            return nil
        }

        // Уникальное имя файла, чтобы книги с одинаковыми названиями не конфликтовали
        let storedName = UUID().uuidString + "." + ext
        let destination = Self.booksDirectory.appendingPathComponent(storedName)

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            lastError = "Не удалось сохранить книгу"
            return nil
        }

        let book = EBook(
            id: UUID(),
            fileName: storedName,
            title: parsed.title.isEmpty
                ? (rawName as NSString).deletingPathExtension
                : parsed.title
        )

        books.append(book)
        saveManifest()

        return book
    }

    func removeBook(_ book: EBook) {
        let url = Self.booksDirectory.appendingPathComponent(book.fileName)
        try? FileManager.default.removeItem(at: url)

        books.removeAll { $0.id == book.id }
        saveManifest()
    }

    // Текст книги: массив глав по порядку spine (для TXT — одна глава)
    func loadContent(for book: EBook) -> [String] {
        let url = Self.booksDirectory.appendingPathComponent(book.fileName)

        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        let ext = (book.fileName as NSString).pathExtension.lowercased()

        guard let parsed = EBookParser.parse(data: data, fileExtension: ext) else {
            return []
        }

        return parsed.chapters
    }
}

// MARK: - Разбор EPUB и TXT

enum EBookParser {
    struct ParsedBook {
        let title: String
        let chapters: [String]
    }

    static func parse(data: Data, fileExtension: String) -> ParsedBook? {
        switch fileExtension.lowercased() {
        case "txt":
            return parseTXT(data: data)
        case "epub":
            return parseEPUB(data: data)
        default:
            return nil
        }
    }

    // MARK: TXT

    private static func parseTXT(data: Data) -> ParsedBook? {
        guard let text = decodeText(data) else {
            return nil
        }

        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return nil
        }

        let firstLine = cleaned
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""

        let title = firstLine.isEmpty ? "Книга" : String(firstLine.prefix(80))

        return ParsedBook(title: title, chapters: [cleaned])
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        // Откат на Windows-1251 (частая кодировка русских TXT)
        let cp1251 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(0x04E1)
        )

        return String(data: data, encoding: String.Encoding(rawValue: cp1251))
    }

    // MARK: EPUB

    private static func parseEPUB(data: Data) -> ParsedBook? {
        guard let entries = ZIPArchive.read(data: data) else {
            return nil
        }

        var files: [String: Data] = [:]

        for entry in entries {
            if entry.name.hasSuffix("/") {
                continue
            }

            files[normalizePath(entry.name)] = entry.data
        }

        // 1. container.xml -> путь к OPF
        guard
            let containerData = files["META-INF/container.xml"],
            let container = decodeText(containerData)
        else {
            return nil
        }

        let opfPath = firstAttribute(
            in: container,
            tag: "rootfile",
            attribute: "full-path"
        )

        guard !opfPath.isEmpty else {
            return nil
        }

        let normalizedOPFPath = normalizePath(opfPath)

        guard let opfData = files[normalizedOPFPath], let opf = decodeText(opfData) else {
            return nil
        }

        let basePath = (normalizedOPFPath as NSString).deletingLastPathComponent

        // 2. Манифест: id -> путь к документу
        var manifest: [String: String] = [:]

        for tag in tagMatches(in: opf, tag: "item") {
            let id = attribute(in: tag, name: "id")
            let href = attribute(in: tag, name: "href")
            let type = attribute(in: tag, name: "media-type")

            guard !id.isEmpty, !href.isEmpty else { continue }
            guard type.isEmpty || type.contains("html") || type.contains("xml") else { continue }

            manifest[id] = href
        }

        // 3. Spine: порядок глав
        guard let spineBlock = firstTagBlock(in: opf, tag: "spine") else {
            return nil
        }

        var chapterPaths: [String] = []

        for tag in tagMatches(in: spineBlock, tag: "itemref") {
            let idref = attribute(in: tag, name: "idref")

            guard let href = manifest[idref] else { continue }

            let joined = basePath.isEmpty ? href : basePath + "/" + href
            chapterPaths.append(normalizePath(joined))
        }

        // 4. Название книги
        var title = ""

        if let titleBlock = firstTagBlock(in: opf, tag: "dc:title") {
            title = decodeEntities(titleBlock).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 5. Текст глав
        var chapters: [String] = []

        for path in chapterPaths {
            guard let htmlData = files[path] else { continue }

            let text = extractText(from: htmlData)

            if !text.isEmpty {
                chapters.append(text)
            }
        }

        guard !chapters.isEmpty else {
            return nil
        }

        return ParsedBook(title: title, chapters: chapters)
    }

    // MARK: Извлечение текста из HTML

    private static func extractText(from data: Data) -> String {
        guard var html = decodeText(data) else {
            return ""
        }

        let replacements: [(String, String)] = [
            ("(?is)<style\\b[^>]*>.*?</style>", " "),
            ("(?is)<script\\b[^>]*>.*?</script>", " "),
            ("(?is)<head\\b[^>]*>.*?</head>", " "),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(?:p|div|h[1-6]|li|tr|blockquote)>", "\n")
        ]

        for (pattern, replacement) in replacements {
            html = regexReplace(html, pattern: pattern, with: replacement)
        }

        // Все оставшиеся теги удаляем
        html = regexReplace(html, pattern: "<[^>]*>", with: "")

        let text = decodeEntities(html)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    // MARK: HTML-сущности

    private static func decodeNumericEntities(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while let amp = text.range(of: "&#", range: index..<text.endIndex) {
            result += String(text[index..<amp.lowerBound])

            guard let semicolon = text.range(of: ";", range: amp.upperBound..<text.endIndex) else {
                result += "&#"
                index = amp.upperBound
                continue
            }

            let digits = text[amp.upperBound..<semicolon.lowerBound]

            var codePoint: Int?

            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                codePoint = Int(digits.dropFirst(), radix: 16)
            } else {
                codePoint = Int(digits)
            }

            if let codePoint, let value = UInt32(exactly: codePoint), let scalar = Unicode.Scalar(value) {
                result += String(Character(scalar))
            } else {
                result += String(text[amp.lowerBound..<semicolon.upperBound])
            }

            index = semicolon.upperBound
        }

        result += String(text[index...])
        return result
    }

    private static func decodeNamedEntities(_ text: String) -> String {
        let map: [String: String] = [
            "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
            "apos": "'", "mdash": "—", "ndash": "–", "hellip": "…",
            "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”",
            "lsquo": "‘", "rsquo": "’", "bull": "•", "middot": "·"
        ]

        var result = text

        for (entity, replacement) in map {
            result = result.replacingOccurrences(of: "&\(entity);", with: replacement)
            result = result.replacingOccurrences(of: "&\(entity.uppercased());", with: replacement)
        }

        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        decodeNamedEntities(decodeNumericEntities(text))
    }

    // MARK: Вспомогательный разбор XML

    private static func normalizePath(_ path: String) -> String {
        var components: [String] = []

        for component in path.split(separator: "/") {
            if component == "." {
                continue
            }

            if component == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
            } else {
                components.append(String(component))
            }
        }

        return components.joined(separator: "/")
    }

    private static func firstTagBlock(in text: String, tag: String) -> String? {
        guard let openRange = text.range(of: "<\(tag)", options: .caseInsensitive) else {
            return nil
        }

        guard let closeRange = text.range(
            of: ">",
            options: .caseInsensitive,
            range: openRange.upperBound..<text.endIndex
        ) else {
            return nil
        }

        guard let endRange = text.range(
            of: "</\(tag)>",
            options: .caseInsensitive,
            range: closeRange.upperBound..<text.endIndex
        ) else {
            return nil
        }

        return String(text[closeRange.upperBound..<endRange.lowerBound])
    }

    // Все открывающие теги с указанным именем (с проверкой границы имени,
    // чтобы "<item" не ловил "<itemref")
    private static func tagMatches(in text: String, tag: String) -> [String] {
        var results: [String] = []
        var searchStart = text.startIndex

        let openToken = "<\(tag)"

        while searchStart < text.endIndex,
              let openRange = text.range(
                  of: openToken,
                  options: .caseInsensitive,
                  range: searchStart..<text.endIndex
              ) {
            let afterOpen = openRange.upperBound

            var isBoundary: Bool

            if afterOpen < text.endIndex {
                let character = text[afterOpen]
                isBoundary = character == " "
                    || character == "\t"
                    || character == "\n"
                    || character == "\r"
                    || character == "/"
            } else {
                isBoundary = true
            }

            if isBoundary,
               let closeRange = text.range(
                   of: ">",
                   options: .caseInsensitive,
                   range: afterOpen..<text.endIndex
               ) {
                results.append(String(text[openRange.lowerBound..<closeRange.upperBound]))
                searchStart = closeRange.upperBound
            } else {
                searchStart = afterOpen
            }
        }

        return results
    }

    private static func firstAttribute(in text: String, tag: String, attribute name: String) -> String {
        guard let openRange = text.range(of: "<\(tag)", options: .caseInsensitive) else {
            return ""
        }

        guard let closeRange = text.range(
            of: ">",
            options: .caseInsensitive,
            range: openRange.upperBound..<text.endIndex
        ) else {
            return ""
        }

        let tagString = String(text[openRange.lowerBound..<closeRange.upperBound])
        return attribute(in: tagString, name: name)
    }

    private static func attribute(in tagString: String, name: String) -> String {
        for delimiter in ["\"", "'"] {
            let token = "\(name)=\(delimiter)"

            guard let tokenRange = tagString.range(of: token, options: .caseInsensitive) else {
                continue
            }

            let valueStart = tokenRange.upperBound

            guard let valueRange = tagString.range(
                of: delimiter,
                range: valueStart..<tagString.endIndex
            ) else {
                continue
            }

            return String(tagString[valueStart..<valueRange.lowerBound])
        }

        return ""
    }
}

// MARK: - Минимальный читатель ZIP (для EPUB)

private enum ZIPArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    static func read(data: Data) -> [Entry]? {
        guard let eocdOffset = findEOCD(in: data) else {
            return nil
        }

        let centralCount = readUInt16LE(data, offset: eocdOffset + 10) ?? 0
        let centralOffset = readUInt32LE(data, offset: eocdOffset + 16) ?? 0

        var entries: [Entry] = []
        var offset = centralOffset

        for _ in 0..<centralCount {
            guard readUInt32LE(data, offset: offset) == 0x02014B50 else {
                break
            }

            let compressionMethod = readUInt16LE(data, offset: offset + 10) ?? 0
            let compressedSize = readUInt32LE(data, offset: offset + 20) ?? 0
            let nameLength = readUInt16LE(data, offset: offset + 28) ?? 0
            let extraLength = readUInt16LE(data, offset: offset + 30) ?? 0
            let commentLength = readUInt16LE(data, offset: offset + 32) ?? 0
            let localOffset = readUInt32LE(data, offset: offset + 42) ?? 0

            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)

            guard nameEnd <= data.count else {
                break
            }

            let name = String(
                data: data.subdata(in: nameStart..<nameEnd),
                encoding: .utf8
            ) ?? ""

            // Локальный заголовок: пропускаем имя и доп. поле, читаем содержимое
            let localNameLength = readUInt16LE(data, offset: Int(localOffset) + 26) ?? 0
            let localExtraLength = readUInt16LE(data, offset: Int(localOffset) + 28) ?? 0
            let dataStart = Int(localOffset) + 30 + Int(localNameLength) + Int(localExtraLength)
            let dataEnd = dataStart + Int(compressedSize)

            var entryData: Data?

            if compressionMethod == 0 {
                if dataEnd <= data.count {
                    entryData = data.subdata(in: dataStart..<dataEnd)
                }
            } else if compressionMethod == 8, dataEnd <= data.count {
                entryData = decompress(data.subdata(in: dataStart..<dataEnd))
            }

            if let entryData, !name.isEmpty {
                entries.append(Entry(name: name, data: entryData))
            }

            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }

        return entries.isEmpty ? nil : entries
    }

    private static func findEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let scanSize = min(66_000, data.count)
        let lowerBound = data.count - scanSize

        var index = data.count - 22

        while index >= lowerBound {
            var matched = true

            for (delta, byte) in signature.enumerated() {
                if data[data.startIndex + index + delta] != byte {
                    matched = false
                    break
                }
            }

            if matched {
                return index
            }

            index -= 1
        }

        return nil
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else {
            return nil
        }

        let bytes = [UInt8](data.subdata(in: offset..<(offset + 2)))
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }

        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    // COMPRESSION_ZLIB в системном Compression — это raw DEFLATE без заголовка,
    // что совпадает с форматом записей ZIP
    private static func decompress(_ compressed: Data) -> Data? {
        do {
            let raw = try (compressed as NSData).decompressed(using: .zlib)
            return raw as Data
        } catch {
            return nil
        }
    }
}

// MARK: - Экран чтения

struct ReadingScreenView: View {
    @ObservedObject var store: EBookStore
    let onClose: () -> Void

    @ObservedObject private var theme = PlayTheme.shared

    @State private var selectedBook: EBook?
    @State private var chapters: [String] = []
    @State private var currentChapter = 0
    @State private var showingImporter = false
    @State private var showingMenu = false
    @State private var showingError = false

    init(store: EBookStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if selectedBook != nil {
                            selectedBook = nil
                        } else {
                            onClose()
                        }
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

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showingMenu = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.ui)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
            .padding(.horizontal, 18)

            if let book = selectedBook {
                bookContent(book)
            } else {
                bookList
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.epub, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importBook(result)
        }
        .overlay {
            if showingMenu {
                menuOverlay
            }
        }
        .alert("Ошибка", isPresented: $showingError) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text(store.lastError ?? "Не удалось открыть книгу")
        }
    }

    // MARK: Список книг

    private var bookList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Электронные книги")
                    .font(AppFont.bold(24))
                    .foregroundStyle(theme.ui)
                    .padding(.top, 24)

                if store.books.isEmpty {
                    Text("Книг пока нет. Нажмите на три точки справа сверху и выберите «Добавить книгу».")
                        .font(AppFont.regular(15))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                } else {
                    ForEach(store.books) { book in
                        Button {
                            openBook(book)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "text.book.closed")
                                    .font(.system(size: 20))
                                    .foregroundStyle(theme.ui)
                                    .frame(width: 40, height: 40)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Circle())

                                Text(book.title)
                                    .font(AppFont.regular(16))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: Открытая книга

    private func bookContent(_ book: EBook) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(book.title)
                        .font(AppFont.bold(22))
                        .foregroundStyle(theme.ui)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if chapters.indices.contains(currentChapter) {
                        Text(chapters[currentChapter])
                            .font(AppFont.regular(17))
                            .lineSpacing(6)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Не удалось загрузить текст книги")
                            .font(AppFont.regular(16))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            if chapters.count > 1 {
                HStack {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if currentChapter > 0 {
                                currentChapter -= 1
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(currentChapter > 0 ? theme.ui : theme.ui.opacity(0.3))
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentChapter == 0)

                    Spacer()

                    Text("\(currentChapter + 1) / \(chapters.count)")
                        .font(AppFont.regular(14))
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if currentChapter < chapters.count - 1 {
                                currentChapter += 1
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(
                                currentChapter < chapters.count - 1
                                    ? theme.ui
                                    : theme.ui.opacity(0.3)
                            )
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentChapter >= chapters.count - 1)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: Меню из трёх точек (стиль и отступы как на главном экране)

    private var menuOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showingMenu = false
                    }
                }

            VStack {
                HStack {
                    Spacer()

                    CustomMenu(
                        title: nil,
                        options: [
                            CustomMenuOption(title: "Добавить книгу", systemImage: "plus") {
                                showingMenu = false
                                showingImporter = true
                            }
                        ],
                        selectedIndex: nil,
                        onSelect: { _ in },
                        onClose: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showingMenu = false
                            }
                        }
                    )
                }
                .padding(.top, 66)
                .padding(.trailing, 18)

                Spacer()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showingMenu)
    }

    // MARK: Действия

    private func importBook(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            if let book = store.importBook(from: url) {
                openBook(book)
            } else {
                showingError = true
            }

        case .failure:
            store.lastError = "Не удалось получить доступ к файлу"
            showingError = true
        }
    }

    private func openBook(_ book: EBook) {
        selectedBook = book
        chapters = store.loadContent(for: book)
        currentChapter = 0
    }
}
