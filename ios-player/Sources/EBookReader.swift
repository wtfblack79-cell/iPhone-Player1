import SwiftUI
import UniformTypeIdentifiers
import Compression

// MARK: - Модель электронной книги

struct EBook: Identifiable, Codable {
    let id: UUID
    let fileName: String
    var title: String
    var kind: String // "epub" или "txt"
}

struct EBookChapter: Identifiable {
    let id: Int
    let title: String
    let text: String
}

// MARK: - Хранилище электронных книг
// Книги копируются в Documents/EBooks и переживают перезапуск приложения.
// Аудиобиблиотека не затрагивается: refreshLibrary() сканирует только корень
// Documents и отбирает файлы по аудио-расширениям, а книги лежат во вложенной папке.

final class EBookStore: ObservableObject {
    @Published private(set) var books: [EBook] = []
    @Published var errorMessage: String?

    private var chapterCache: [UUID: [EBookChapter]] = [:]
    private let folderURL: URL
    private let libraryURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folderURL = documents.appendingPathComponent("EBooks", isDirectory: true)
        libraryURL = folderURL.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadIndex()
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        books = (try? JSONDecoder().decode([EBook].self, from: data)) ?? []
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(books) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    // Импорт книги: копируем файл в папку EBooks и определяем название
    @discardableResult
    func importBook(from sourceURL: URL) -> EBook? {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard ext == "epub" || ext == "txt" else {
            errorMessage = "Поддерживаются только файлы EPUB и TXT"
            return nil
        }

        do {
            let data = try Data(contentsOf: sourceURL)
            let title = guessTitle(from: data, fileExtension: ext)
                ?? sourceURL.deletingPathExtension().lastPathComponent

            let book = EBook(
                id: UUID(),
                fileName: UUID().uuidString + "." + ext,
                title: title,
                kind: ext
            )

            try data.write(to: folderURL.appendingPathComponent(book.fileName), options: .atomic)
            books.insert(book, at: 0)
            saveIndex()

            return book
        } catch {
            errorMessage = "Не удалось импортировать книгу: \(error.localizedDescription)"
            return nil
        }
    }

    private func guessTitle(from data: Data, fileExtension ext: String) -> String? {
        if ext == "epub" {
            if let opf = EBookParser.opfEntry(in: data),
               let title = EBookParser.title(in: opf.data),
               !title.isEmpty {
                return title
            }
            return nil
        }

        if ext == "txt", let text = EBookParser.decodeText(data) {
            let firstLine = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

            return firstLine.isEmpty ? nil : firstLine
        }

        return nil
    }

    // Текст книги по главам: парсится по требованию и кешируется
    func chapters(for book: EBook) -> [EBookChapter] {
        if let cached = chapterCache[book.id] {
            return cached
        }

        let url = folderURL.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }

        let parsed = book.kind == "epub"
            ? EBookParser.epubChapters(data: data)
            : EBookParser.txtChapters(data: data)

        chapterCache[book.id] = parsed
        return parsed
    }

    func deleteBook(_ book: EBook) {
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(book.fileName))
        books.removeAll { $0.id == book.id }
        chapterCache[book.id] = nil
        saveIndex()
    }
}

// MARK: - Разбор EPUB и TXT

enum EBookParser {
    // MARK: TXT

    static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        // Windows-1251: kCFStringEncodingWindowsCyrillic = 0x04E1
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x04E1))
        )
        return String(data: data, encoding: encoding)
    }

    static func txtChapters(data: Data) -> [EBookChapter] {
        guard let text = decodeText(data) else { return [] }
        return [EBookChapter(id: 0, title: "", text: text)]
    }

    // MARK: EPUB

    struct ZipEntry {
        let name: String
        let data: Data
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return Int(byte(data, offset)) | (Int(byte(data, offset + 1)) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        var value = 0
        for index in 0..<4 {
            value |= Int(byte(data, offset + index)) << (8 * index)
        }
        return value
    }

    static func zipEntries(in data: Data) -> [ZipEntry] {
        // Ищем End of Central Directory с конца файла
        var eocdStart: Int? = nil
        if data.count >= 22 {
            let lowest = max(0, data.count - 22 - 65_557)
            var i = data.count - 22
            while i >= lowest {
                if readUInt32LE(data, i) == 0x06054B50 {
                    eocdStart = i
                    break
                }
                i -= 1
            }
        }
        guard let eocd = eocdStart else { return [] }

        let entryCount = readUInt16LE(data, eocd + 10)
        let directoryOffset = readUInt32LE(data, eocd + 16)

        var entries: [ZipEntry] = []
        var offset = directoryOffset

        for _ in 0..<entryCount {
            guard readUInt32LE(data, offset) == 0x02014B50 else { break }

            let compressionMethod = readUInt16LE(data, offset + 10)
            let compressedSize = readUInt32LE(data, offset + 20)
            let nameLength = readUInt16LE(data, offset + 28)
            let extraLength = readUInt16LE(data, offset + 30)
            let commentLength = readUInt16LE(data, offset + 32)
            let localOffset = readUInt32LE(data, offset + 42)

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength

            guard nameEnd <= data.count else { break }

            let nameData = data.subdata(
                in: (data.startIndex + nameStart)..<(data.startIndex + nameEnd)
            )
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .ascii)
                ?? ""

            if let content = extractContent(
                data: data,
                localOffset: localOffset,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize
            ) {
                entries.append(ZipEntry(name: name, data: content))
            }

            offset = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private static func extractContent(
        data: Data,
        localOffset: Int,
        compressionMethod: Int,
        compressedSize: Int
    ) -> Data? {
        guard readUInt32LE(data, localOffset) == 0x04034B50 else { return nil }

        let localNameLength = readUInt16LE(data, localOffset + 26)
        let localExtraLength = readUInt16LE(data, localOffset + 28)

        let dataStart = localOffset + 30 + localNameLength + localExtraLength
        let dataEnd = dataStart + compressedSize

        guard dataStart >= 0, dataStart <= data.count, dataEnd <= data.count else { return nil }

        let chunk = data.subdata(
            in: (data.startIndex + dataStart)..<(data.startIndex + dataEnd)
        )

        // 0 — без сжатия, 8 — DEFLATE (сырой поток zlib)
        if compressionMethod == 0 {
            return chunk
        }
        if compressionMethod == 8 {
            do {
                return try (chunk as NSData).decompressed(using: .zlib)
            } catch {
                return nil
            }
        }
        return nil
    }

    // META-INF/container.xml -> путь к OPF
    static func opfEntry(in data: Data) -> ZipEntry? {
        let entries = zipEntries(in: data)

        guard let container = entries.first(where: {
            normalized($0.name) == "meta-inf/container.xml"
        }) else { return nil }

        let containerXML = String(data: container.data, encoding: .utf8) ?? ""
        guard let opfPath = attributeValue(in: containerXML, "full-path") else { return nil }

        return entries.first { normalized($0.name) == normalized(opfPath) }
    }

    // Заголовок книги из OPF (dc:title)
    static func title(in opfData: Data) -> String? {
        guard let xml = String(data: opfData, encoding: .utf8) else { return nil }

        let pattern = "<(?:dc:)?title[^>]*>([\\s\\S]*?)</(?:dc:)?title>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range),
              let group = Range(match.range(at: 1), in: xml) else { return nil }

        var text = String(xml[group])
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }

    // Главы в порядке spine
    static func epubChapters(data: Data) -> [EBookChapter] {
        guard let opf = opfEntry(in: data) else { return [] }
        guard let opfXML = String(data: opf.data, encoding: .utf8) else { return [] }

        let opfDir = directoryComponent(of: opf.name)
        let entries = zipEntries(in: data)

        var manifest: [String: String] = [:]
        for tag in tags(named: "item", in: opfXML) {
            guard let id = attributeValue(in: tag, "id"),
                  let href = attributeValue(in: tag, "href") else { continue }

            let mediaType = attributeValue(in: tag, "media-type") ?? ""
            guard mediaType.isEmpty || mediaType.lowercased().contains("html") else { continue }

            manifest[id] = href
        }

        var idrefs: [String] = []
        for tag in tags(named: "itemref", in: opfXML) {
            if let idref = attributeValue(in: tag, "idref") {
                idrefs.append(idref)
            }
        }

        var chapters: [EBookChapter] = []

        for idref in idrefs {
            guard let href = manifest[idref] else { continue }

            let path = joinPath(opfDir, href)
            guard let entry = entries.first(where: { normalized($0.name) == normalized(path) }),
                  let text = plainText(fromHTML: entry.data) else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let chapterName = chapterTitle(from: trimmed, index: chapters.count)
            chapters.append(EBookChapter(id: chapters.count, title: chapterName, text: trimmed))
        }

        return chapters
    }

    private static func chapterTitle(from text: String, index: Int) -> String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""

        if !firstLine.isEmpty, firstLine.count <= 60 {
            return firstLine
        }
        return "Глава \(index + 1)"
    }

    // Преобразование HTML в обычный текст
    static func plainText(fromHTML data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }

        text = text.replacingOccurrences(
            of: "<br[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</p>",
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]*>",
            with: " ",
            options: .regularExpression
        )

        text = decodeEntities(text)

        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n[ ]+", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let namedEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": "\u{00A0}",
        "mdash": "—",
        "ndash": "–",
        "hellip": "…",
        "laquo": "«",
        "raquo": "»",
        "ldquo": "“",
        "rdquo": "”",
        "lsquo": "‘",
        "rsquo": "’"
    ]

    private static func decodeEntities(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]

            if char == "&" {
                if let semicolon = text[index...].firstIndex(of: ";"),
                   text.distance(from: index, to: semicolon) <= 10 {
                    let entity = String(text[text.index(after: index)..<semicolon])

                    var handled = false

                    if entity.hasPrefix("#") {
                        let numberPart = entity.dropFirst().lowercased()
                        let code: Int?
                        if numberPart.hasPrefix("x") {
                            code = Int(numberPart.dropFirst(), radix: 16)
                        } else {
                            code = Int(numberPart)
                        }

                        if let code, code > 0, let scalar = UnicodeScalar(code) {
                            result.append(Character(scalar))
                            handled = true
                        }
                    } else if let replacement = namedEntities[entity.lowercased()] {
                        result.append(replacement)
                        handled = true
                    }

                    if handled {
                        index = text.index(after: semicolon)
                        continue
                    }
                }
            }

            result.append(char)
            index = text.index(after: index)
        }

        return result
    }

    // MARK: Вспомогательные функции

    private static func tags(named name: String, in xml: String) -> [String] {
        let pattern = "<\\s*\(name)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(xml.startIndex..., in: xml)
        let matches = regex.matches(in: xml, options: [], range: range)

        return matches.compactMap { match in
            Range(match.range, in: xml).map { String(xml[$0]) }
        }
    }

    private static func attributeValue(in tag: String, _ attribute: String) -> String? {
        let pattern = "\\b\(attribute)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range) else { return nil }

        if let group = Range(match.range(at: 1), in: tag) {
            return decodeEntities(String(tag[group]))
        }
        if let group = Range(match.range(at: 2), in: tag) {
            return decodeEntities(String(tag[group]))
        }

        return nil
    }

    private static func normalized(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        return value.lowercased()
    }

    private static func directoryComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func joinPath(_ dir: String, _ file: String) -> String {
        dir.isEmpty ? file : dir + "/" + file
    }
}

// MARK: - Экран чтения

struct ReadingScreenView: View {
    @ObservedObject var store: EBookStore
    let onBack: () -> Void

    @ObservedObject private var theme = PlayTheme.shared

    @State private var selectedBook: EBook?
    @State private var chapters: [EBookChapter] = []
    @State private var showingImporter = false
    @State private var showingMenu = false

    var body: some View {
        ZStack {
            if let book = selectedBook {
                bookView(book)
            } else {
                bookListView
            }
        }
        .overlay(alignment: .topTrailing) {
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
            .padding(.top, 12)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if selectedBook != nil {
                        selectedBook = nil
                        chapters = []
                    } else {
                        onBack()
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
            .padding(.top, 12)
            .padding(.leading, 18)
        }
        .overlay {
            if showingMenu {
                menuView
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType.epub, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if let book = store.importBook(from: url) {
                    openBook(book)
                }
            case .failure:
                break
            }
        }
        .alert(
            "Ошибка",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: Список книг

    private var bookListView: some View {
        VStack(spacing: 0) {
            if store.books.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 44))
                        .foregroundStyle(theme.ui.opacity(0.7))

                    Text("Книг пока нет")
                        .font(AppFont.bold(20))

                    Text("Нажмите на меню «⋯» вверху справа и выберите «Добавить книгу»")
                        .font(AppFont.regular(14))
                        .opacity(0.7)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.books) { book in
                            Button {
                                openBook(book)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: book.kind == "epub" ? "text.book.closed" : "doc.text")
                                        .font(.system(size: 22))
                                        .foregroundStyle(theme.ui)
                                        .frame(width: 44, height: 44)
                                        .background(Color.white.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(book.title)
                                            .font(AppFont.bold(17))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)

                                        Text(book.kind.uppercased())
                                            .font(AppFont.regular(12))
                                            .opacity(0.6)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .opacity(0.5)
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 76)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    // MARK: Чтение книги

    private func bookView(_ book: EBook) -> some View {
        VStack(spacing: 0) {
            Text(book.title)
                .font(AppFont.bold(20))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 66)
                .padding(.horizontal, 70)
                .padding(.bottom, 10)

            if chapters.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(theme.ui.opacity(0.7))

                    Text("Не удалось прочитать книгу")
                        .font(AppFont.bold(17))
                        .opacity(0.8)

                    Text("Файл повреждён или формат не поддерживается")
                        .font(AppFont.regular(13))
                        .opacity(0.6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(chapters) { chapter in
                            if !chapter.title.isEmpty {
                                Text(chapter.title)
                                    .font(AppFont.bold(22))
                                    .foregroundStyle(theme.ui)
                            }

                            Text(chapter.text)
                                .font(AppFont.regular(17))
                                .lineSpacing(6)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: Меню из трёх точек (тот же стиль и отступы, что на главном экране)

    private var menuView: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
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
                            CustomMenuOption(title: "Добавить книгу", systemImage: "plus.circle.fill") {
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

    private func openBook(_ book: EBook) {
        chapters = store.chapters(for: book)
        selectedBook = book
    }
}
