import SwiftUI
import UniformTypeIdentifiers
import Compression

// MARK: - Типы файлов книг

enum EBookFileType {
    // Системного типа для fb2 в iOS нет — объявляем сами:
    // сначала пробуем зарегистрированный в системе (если какой-то
    // читательский app уже объявил расширение), иначе свой.
    static let fb2: UTType = {
        if let registered = UTType(filenameExtension: "fb2") {
            return registered
        }
        if let declared = try? UTType(exportedAs: "com.fictionbook.fb2", conformingTo: .xml) {
            return declared
        }
        return .xml
    }()
}

// MARK: - Модель электронной книги

struct EBook: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
}

// MARK: - Хранилище электронных книг
// Копирует файлы в Documents/EBooks, поэтому книги переживают перезапуск
// приложения и не пересекаются с аудиобиблиотекой (она сканирует корень Documents).

@MainActor
final class EBookStore: ObservableObject {
    @Published private(set) var books: [EBook] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let directory: URL
    private let indexKey = "playbook.ebooks.index"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        directory = docs[0].appendingPathComponent("EBooks", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: Персистентность

    private func loadIndex() {
        guard let data = UserDefaults.standard.data(forKey: indexKey) else { return }
        guard let decoded = try? JSONDecoder().decode([EBook].self, from: data) else { return }

        let fileManager = FileManager.default
        books = decoded.filter { book in
            fileManager.fileExists(atPath: directory.appendingPathComponent(book.fileName).path)
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: indexKey)
        }
    }

    // MARK: Импорт

    @discardableResult
    func importBook(from result: Result<[URL], Error>) -> EBook? {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return nil }

            let ext = url.pathExtension.lowercased()
            guard ext == "epub" || ext == "txt" || ext == "fb2" else {
                errorMessage = "Поддерживаются только файлы EPUB, TXT и FB2"
                return nil
            }

            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "Не удалось прочитать файл книги"
                return nil
            }

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let fileName = UUID().uuidString + "." + ext
                try data.write(to: directory.appendingPathComponent(fileName))

                isLoading = true
                let fallbackTitle = url.deletingPathExtension().lastPathComponent

                let bookTitle = EBookParser.bookTitle(
                    data: data,
                    fileExtension: ext,
                    fallback: fallbackTitle
                )

                let book = EBook(title: bookTitle, fileName: fileName)
                books.append(book)
                saveIndex()
                isLoading = false
                errorMessage = nil
                return book
            } catch {
                errorMessage = "Не удалось сохранить книгу: \(error.localizedDescription)"
                isLoading = false
                return nil
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Удаление

    func removeBook(_ book: EBook) {
        books.removeAll { $0.id == book.id }
        saveIndex()

        let url = directory.appendingPathComponent(book.fileName)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Чтение

    func text(for book: EBook) -> String? {
        let url = directory.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return EBookParser.parse(
            data: data,
            fileExtension: (book.fileName as NSString).pathExtension.lowercased()
        )
    }
}

// MARK: - Разбор EPUB и TXT

enum EBookParser {
    // MARK: Публичный API

    static func bookTitle(data: Data, fileExtension: String, fallback: String) -> String {
        if fileExtension == "epub" {
            let files = unzip(data)
            if let opfPath = opfPath(in: files), let opfData = files[opfPath] {
                let opf = decodeString(opfData)
                if let title = firstGroup(in: opf, pattern: "<dc:title[^>]*>(.*?)</dc:title>") {
                    let plain = plainText(fromHTML: title)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !plain.isEmpty {
                        return plain
                    }
                }
            }
        }

        if fileExtension == "fb2" {
            let xml = fb2String(from: data)
            if let title = firstGroup(
                in: xml,
                pattern: "<(?:\\w+:)?book-title[^>]*>(.*?)</(?:\\w+:)?book-title>"
            ) {
                let plain = plainText(fromHTML: title)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !plain.isEmpty {
                    return plain
                }
            }
        }

        return fallback
    }

    static func parse(data: Data, fileExtension: String) -> String {
        switch fileExtension {
        case "txt":
            return text(fromTXT: data)
        case "epub":
            return text(fromEPUB: data)
        case "fb2":
            return text(fromFB2: data)
        default:
            return ""
        }
    }

    // MARK: FB2 (FictionBook)

    private static func text(fromFB2 data: Data) -> String {
        let xml = fb2String(from: data)

        // Берём только первый body без атрибута name —
        // сноски хранятся в отдельных body с name="notes"
        var paragraphs: [String] = []

        if let bodyXML = firstGroup(in: xml, pattern: "<body(?:\\s[^>]*)?>(.*?)</body>") {
            paragraphs = fb2Paragraphs(bodyXML)
        }

        if paragraphs.isEmpty {
            paragraphs = fb2Paragraphs(xml)
        }

        return normalize(paragraphs.joined(separator: "\n\n"))
    }

    private static func fb2Paragraphs(_ xml: String) -> [String] {
        var result: [String] = []

        let pattern = "<p(?:\\s[^>]*)?>.*?</p>|<p(?:\\s[^>]*)?/>|<empty-line\\s*/?>"

        for match in allMatches(in: xml, pattern: pattern) {
            let lower = match.lowercased()

            if lower.contains("empty-line") {
                result.append("")
                continue
            }

            guard let content = firstGroup(in: match, pattern: "<p(?:\\s[^>]*)?>(.*?)</p>") else {
                continue
            }

            let paragraph = plainText(fromHTML: content)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !paragraph.isEmpty {
                result.append(paragraph)
            }
        }

        return result
    }

    private static func fb2String(from data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        // Windows-1251 (kCFStringEncodingWindowsCyrillic = 0x04E1)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x04E1))
        if let cyrillic = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
            return cyrillic
        }

        return String(decoding: data, as: UTF8.self)
    }

    // MARK: TXT (UTF-8 с откатом на Windows-1251)

    private static func text(fromTXT data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return normalize(utf8)
        }

        // Windows-1251 (kCFStringEncodingWindowsCyrillic = 0x04E1)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x04E1))
        if let cyrillic = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
            return normalize(cyrillic)
        }

        return String(decoding: data, as: UTF8.self)
    }

    // MARK: EPUB (лёгкий разбор ZIP без внешних зависимостей)

    private static func text(fromEPUB data: Data) -> String {
        let files = unzip(data)
        var chapterTexts: [String] = []

        if let opfPath = opfPath(in: files), let opfData = files[opfPath] {
            let opfDirectory = (opfPath as NSString).deletingLastPathComponent
            let opf = decodeString(opfData)

            var hrefs: [String: String] = [:]
            for tag in allMatches(in: opf, pattern: "<item\\b[^>]*>") {
                guard let id = attribute("id", in: tag),
                      let href = attribute("href", in: tag) else { continue }

                let mediaType = attribute("media-type", in: tag) ?? ""
                if mediaType.contains("html") || isHTMLFile(href) {
                    hrefs[id] = resolve(href: href, relativeTo: opfDirectory)
                }
            }

            for idref in allGroupMatches(in: opf, pattern: "<itemref\\b[^>]*idref\\s*=\\s*\"([^\"]+)\"") {
                guard let href = hrefs[idref], let itemData = files[href] else { continue }
                let html = decodeString(itemData)
                let plain = plainText(fromHTML: html)
                if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chapterTexts.append(plain)
                }
            }
        }

        if chapterTexts.isEmpty {
            // Резерв: склеить все HTML-файлы архива по порядку имён
            let names = files.keys.filter { isHTMLFile($0) }.sorted()
            for name in names {
                guard let itemData = files[name] else { continue }
                let html = decodeString(itemData)
                let plain = plainText(fromHTML: html)
                if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chapterTexts.append(plain)
                }
            }
        }

        return normalize(chapterTexts.joined(separator: "\n\n"))
    }

    private static func opfPath(in files: [String: Data]) -> String? {
        guard let containerData = files["META-INF/container.xml"] else { return nil }
        let container = decodeString(containerData)
        return firstGroup(in: container, pattern: "<rootfile\\b[^>]*full-path\\s*=\\s*\"([^\"]+)\"")
    }

    private static func resolve(href: String, relativeTo base: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") {
            return String(trimmed.dropFirst())
        }
        if base.isEmpty {
            return trimmed
        }
        return base + "/" + trimmed
    }

    private static func isHTMLFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "xhtml" || ext == "html" || ext == "htm"
    }

    private static func decodeString(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: ZIP

    private static func unzip(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var entries: [String: Data] = [:]
        var offset = 0

        func u32(_ index: Int) -> UInt32 {
            guard index >= 0, index + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[index])
                | (UInt32(bytes[index + 1]) << 8)
                | (UInt32(bytes[index + 2]) << 16)
                | (UInt32(bytes[index + 3]) << 24)
        }

        func u16(_ index: Int) -> UInt16 {
            guard index >= 0, index + 2 <= bytes.count else { return 0 }
            return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
        }

        while offset + 30 <= bytes.count {
            guard u32(offset) == 0x04034B50 else { break }

            let method = u16(offset + 8)
            let compressedSize = Int(u32(offset + 18))
            let uncompressedSize = Int(u32(offset + 22))
            let nameLength = Int(u16(offset + 26))
            let extraLength = Int(u16(offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLength <= bytes.count else { break }
            let nameBytes = Array(bytes[nameStart..<(nameStart + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)

            let dataStart = nameStart + nameLength + extraLength
            guard dataStart + compressedSize <= bytes.count else { break }

            if uncompressedSize > 0 {
                let payload = Data(bytes[dataStart..<(dataStart + compressedSize)])
                switch method {
                case 0:
                    entries[name] = payload
                case 8:
                    entries[name] = inflate(payload)
                default:
                    break
                }
            }

            if compressedSize == 0 {
                offset = dataStart
            } else {
                offset = dataStart + compressedSize
            }
        }

        return entries
    }

    private static func inflate(_ data: Data) -> Data? {
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            return nil
        }
    }

    // MARK: HTML -> обычный текст

    static func plainText(fromHTML html: String) -> String {
        var text = html

        text = text.replacingOccurrences(
            of: "<(script|style)[^>]*>.*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: "<br[^>]*>|</p>|</div>|</h[1-6]>|</li>|</tr>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        text = decodeNumericEntities(text)
        text = decodeNamedEntities(text)

        return text
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "&" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "#" {
                    var probe = text.index(after: next)
                    var semicolon: String.Index?
                    var steps = 0

                    while probe < text.endIndex, steps < 12 {
                        if text[probe] == ";" {
                            semicolon = probe
                            break
                        }
                        probe = text.index(after: probe)
                        steps += 1
                    }

                    if let semicolon = semicolon {
                        let bodyStart = text.index(after: next)
                        var body = String(text[bodyStart..<semicolon])
                        var radix = 10

                        if body.hasPrefix("x") || body.hasPrefix("X") {
                            body.removeFirst()
                            radix = 16
                        }

                        if let value = UInt32(body, radix: radix),
                           let scalar = Unicode.Scalar(value) {
                            output.unicodeScalars.append(scalar)
                            index = text.index(after: semicolon)
                            continue
                        }
                    }
                }
            }

            output.append(text[index])
            index = text.index(after: index)
        }

        return output
    }

    private static func decodeNamedEntities(_ text: String) -> String {
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
            "&laquo;": "«",
            "&raquo;": "»",
            "&ldquo;": "“",
            "&rdquo;": "”",
            "&lsquo;": "‘",
            "&rsquo;": "’",
            "&bdquo;": "„"
        ]

        var result = text
        for (entity, character) in entities {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        result = result.replacingOccurrences(
            of: "[ \\t\\f]+",
            with: " ",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: " ?\n ?",
            with: "\n",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Регулярные выражения

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }

    private static func firstGroup(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let expression = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)

        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let groupRange = Range(match.range(at: group), in: text) else {
            return nil
        }

        return String(text[groupRange])
    }

    private static func allGroupMatches(in text: String, pattern: String, group: Int = 1) -> [String] {
        guard let expression = regex(pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)

        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let groupRange = Range(match.range(at: group), in: text) else { return nil }
            return String(text[groupRange])
        }
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let expression = regex(pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)

        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstGroup(in: tag, pattern: "\\b" + name + "\\s*=\\s*\"([^\"]*)\"")
    }
}

// MARK: - Экран чтения

struct ReadingScreenView: View {
    @ObservedObject var store: EBookStore
    let onBack: () -> Void
    var initialBook: EBook? = nil

    @ObservedObject private var theme = PlayTheme.shared

    @State private var isMenuOpen = false
    @State private var showingImporter = false
    @State private var currentBook: EBook?
    @State private var currentText = ""

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                if store.isLoading {
                    Spacer()
                    ProgressView()
                        .tint(theme.ui)
                    Spacer()
                } else if let book = currentBook {
                    bookContent(book)
                } else {
                    libraryContent
                }
            }

            menuLayer

            if let error = store.errorMessage {
                VStack {
                    Spacer()

                    Text(error)
                        .font(AppFont.regular(13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.75))
                        .cornerRadius(12)
                        .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            if let initialBook = initialBook, currentBook == nil {
                open(initialBook)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.epub, .plainText, EBookFileType.fb2],
            allowsMultipleSelection: false
        ) { result in
            if let book = store.importBook(from: result) {
                withAnimation(.easeOut(duration: 0.2)) {
                    open(book)
                }
            }
        }
    }

    // MARK: Шапка (кнопка «Назад» слева, меню справа — стиль и отступы главного экрана)

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if currentBook != nil {
                        closeBook()
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
            .padding(.leading, 18)

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
            .padding(.trailing, 18)
        }
        .padding(.top, 12)
    }

    // MARK: Меню из трёх точек (позиция как у меню на главном экране)

    private var menuLayer: some View {
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
                                CustomMenuOption(title: "Добавить книгу", systemImage: "plus") {
                                    isMenuOpen = false

                                    // Показываем fileImporter после того,
                                    // как меню исчезнет из иерархии — иначе
                                    // SwiftUI отменяет показ диалога
                                    DispatchQueue.main.asyncAfter(
                                        deadline: .now() + 0.35
                                    ) {
                                        showingImporter = true
                                    }
                                },
                                CustomMenuOption(title: "К списку книг", systemImage: "books.vertical") {
                                    isMenuOpen = false
                                    closeBook()
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
        .allowsHitTesting(true)
    }

    // MARK: Список книг

    private var libraryContent: some View {
        ScrollView(showsIndicators: false) {
            if store.books.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(theme.ui)

                    Text("Книги не добавлены")
                        .font(AppFont.bold(22))
                        .foregroundStyle(.white)

                    Text("Добавьте EPUB или TXT через меню «⋯»")
                        .font(AppFont.regular(15))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .padding(.top, 90)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.books) { book in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                open(book)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "text.book.closed")
                                    .font(.system(size: 22))
                                    .foregroundStyle(theme.ui)
                                    .frame(width: 40, height: 40)
                                    .background(Color.white.opacity(0.12))
                                    .clipShape(Circle())

                                Text(book.title)
                                    .font(AppFont.bold(17))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(18)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
    }

    // MARK: Открытая книга

    private func bookContent(_ book: EBook) -> some View {
        VStack(spacing: 6) {
            Text(book.title)
                .font(AppFont.bold(19))
                .foregroundStyle(theme.ui)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            ScrollView(showsIndicators: false) {
                Text(currentText.isEmpty ? "Текст книги не найден" : currentText)
                    .font(AppFont.regular(18))
                    .lineSpacing(8)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Действия

    private func open(_ book: EBook) {
        currentBook = book
        currentText = store.text(for: book) ?? ""
    }

    private func closeBook() {
        currentBook = nil
        currentText = ""
    }
}
