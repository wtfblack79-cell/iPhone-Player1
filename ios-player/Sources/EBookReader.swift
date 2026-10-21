import SwiftUI
import UniformTypeIdentifiers

// MARK: - Модель электронной книги

struct EBook: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let title: String
    let addedDate: Date

    init(fileName: String, title: String) {
        self.id = UUID()
        self.fileName = fileName
        self.title = title
        self.addedDate = Date()
    }
}

// MARK: - Хранилище электронных книг

@MainActor
final class EBookStore: ObservableObject {
    @Published var books: [EBook] = []
    @Published var isLoading = false
    @Published var errorMessage = ""

    private let directory: URL
    private let indexURL: URL
    private var chapterCache: [UUID: [String]] = [:]

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        directory = documents.appendingPathComponent("EBooks", isDirectory: true)
        indexURL = directory.appendingPathComponent("library.json")
        loadLibrary()
    }

    private func loadLibrary() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let stored = try JSONDecoder().decode([EBook].self, from: data)
            books = stored.filter { book in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(book.fileName).path
                )
            }
        } catch {
            books = []
        }
    }

    private func persist() {
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            let data = try JSONEncoder().encode(books)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            errorMessage = "Не удалось сохранить библиотеку книг: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func importBook(from sourceURL: URL) -> EBook? {
        isLoading = true
        defer { isLoading = false }

        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if granted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }

            let baseName = (sourceURL.lastPathComponent as NSString).deletingPathExtension
            let ext = sourceURL.pathExtension.lowercased()

            var finalURL = directory.appendingPathComponent("\(baseName).\(ext)")
            var counter = 1
            while FileManager.default.fileExists(atPath: finalURL.path) {
                finalURL = directory.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
                counter += 1
            }

            try FileManager.default.copyItem(at: sourceURL, to: finalURL)

            let book = EBook(fileName: finalURL.lastPathComponent, title: baseName)
            books.insert(book, at: 0)
            persist()
            return book
        } catch {
            errorMessage = "Не удалось добавить книгу: \(error.localizedDescription)"
            return nil
        }
    }

    func removeBook(_ book: EBook) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(book.fileName)
        )
        books.removeAll { $0.id == book.id }
        chapterCache[book.id] = nil
        persist()
    }

    func chapters(for book: EBook) -> [String] {
        if let cached = chapterCache[book.id] {
            return cached
        }

        let url = directory.appendingPathComponent(book.fileName)
        let ext = (book.fileName as NSString).pathExtension.lowercased()

        var chapters: [String] = []
        if let data = try? Data(contentsOf: url) {
            chapters = EBookParser.parse(data: data, fileExtension: ext)
        }

        if chapters.isEmpty {
            chapters = ["Не удалось прочитать содержимое книги."]
        }

        chapterCache[book.id] = chapters
        return chapters
    }
}

// MARK: - Разбор EPUB и TXT

enum EBookParser {
    static func parse(data: Data, fileExtension: String) -> [String] {
        if fileExtension == "epub" {
            return parseEpub(data: data)
        }
        if let text = decodeText(data) {
            return splitChapters(text)
        }
        return []
    }

    // MARK: Текстовые форматы

    static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // Windows-1251 (kCFStringEncodingWindowsCyrillic = 0x04E1)
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x04E1))
        let encoding = String.Encoding(rawValue: raw)
        return String(data: data, encoding: encoding)
    }

    static func splitChapters(_ source: String) -> [String] {
        let text = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return []
        }

        // Попытка найти заголовки глав
        if let regex = try? NSRegularExpression(
            pattern: "(?im)^[ \\t]{0,3}(глава|часть|гл\\.?|chapter|part)[^\\n]{0,80}$"
        ) {
            let full = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: full)

            if matches.count >= 2 {
                var chapters: [String] = []
                let nsText = text as NSString

                for index in 0..<matches.count {
                    let headingRange = matches[index].range
                    let headingEnd = headingRange.location + headingRange.length

                    let bodyStart: Int
                    if index + 1 < matches.count {
                        bodyStart = matches[index + 1].range.location
                    } else {
                        bodyStart = full.location + full.length
                    }

                    let bodyLength = max(0, bodyStart - headingEnd)
                    let body = nsText.substring(
                        with: NSRange(location: headingEnd, length: bodyLength)
                    ).trimmingCharacters(in: .whitespacesAndNewlines)

                    chapters.append(nsText.substring(with: headingRange) + "\n\n" + body)
                }

                return chapters
            }
        }

        // Резервная нарезка по абзацам
        let paragraphs = text.components(separatedBy: "\n\n")
        if paragraphs.count <= 80 {
            return [text]
        }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if !current.isEmpty {
                current += "\n\n"
            }
            current += paragraph

            if current.components(separatedBy: "\n").count >= 100 {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: EPUB

    private struct ZipEntry {
        let name: String
        let data: Data
    }

    private static func parseEpub(data: Data) -> [String] {
        let entries = zipEntries(in: data)
        guard !entries.isEmpty else {
            return []
        }

        // container.xml → путь OPF
        guard let containerEntry = entries.first(where: { $0.name == "META-INF/container.xml" }),
              let containerXML = String(data: containerEntry.data, encoding: .utf8) else {
            return []
        }

        let opfPaths = captureGroups(
            in: containerXML,
            pattern: "full-path\\s*=\\s*[\"]([^\"]+)[\"]"
        )
        guard let opfPath = opfPaths.first,
              let opfEntry = entries.first(where: { $0.name == opfPath }),
              let opfXML = String(data: opfEntry.data, encoding: .utf8) else {
            return []
        }

        // manifest: id → href (в теге <item ...>)
        var manifest: [String: String] = [:]
        for tag in matches(in: opfXML, pattern: "<item\\b[^>]*>") {
            guard let id = firstGroup(in: tag, pattern: "\\bid\\s*=\\s*[\"]([^\"]+)[\"]"),
                  let href = firstGroup(in: tag, pattern: "\\bhref\\s*=\\s*[\"]([^\"]+)[\"]") else {
                continue
            }
            manifest[id] = href
        }

        // spine: порядок чтения
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        let spineIds = captureGroups(
            in: opfXML,
            pattern: "<itemref\\b[^>]*\\bidref\\s*=\\s*[\"]([^\"]+)[\"]"
        )

        var chapters: [String] = []
        for id in spineIds {
            guard let href = manifest[id] else {
                continue
            }
            let decodedHref = href.removingPercentEncoding ?? href
            let fullPath = opfDirectory.isEmpty
                ? decodedHref
                : opfDirectory + "/" + decodedHref

            guard let htmlEntry = entries.first(where: { $0.name == fullPath }),
                  let html = String(data: htmlEntry.data, encoding: .utf8) else {
                continue
            }

            let chapterText = htmlToText(html)
            if !chapterText.isEmpty {
                chapters.append(chapterText)
            }
        }

        // Резерв: все HTML-файлы архива
        if chapters.isEmpty {
            let htmlEntries = entries
                .filter { entry in
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    return ext == "xhtml" || ext == "html" || ext == "htm"
                }
                .sorted { $0.name < $1.name }

            for entry in htmlEntries {
                guard let html = String(data: entry.data, encoding: .utf8) else {
                    continue
                }
                let chapterText = htmlToText(html)
                if !chapterText.isEmpty {
                    chapters.append(chapterText)
                }
            }
        }

        return chapters
    }

    // MARK: HTML → обычный текст

    private static func htmlToText(_ html: String) -> String {
        var text = html

        // переводы строк на блочных тегах
        text = text.replacingOccurrences(
            of: "<(br|p|div|h[1-6]|li|tr)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</(p|div|h[1-6]|li|tr)>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // скрипты и стили целиком
        text = text.replacingOccurrences(
            of: "<(script|style)[^>]*>[\\s\\S]*?</(script|style)>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        // остальные теги
        text = text.replacingOccurrences(
            of: "<[^>]*>",
            with: "",
            options: [.regularExpression]
        )

        text = decodeEntities(text)

        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: [.regularExpression]
        )
        text = text.replacingOccurrences(
            of: "[ \\t]{2,}",
            with: " ",
            options: [.regularExpression]
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text

        let named: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
            "&laquo;": "«",
            "&raquo;": "»",
            "&sect;": "§",
            "&bull;": "•",
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™"
        ]

        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // числовые сущности
        result = decodeNumericEntities(result, pattern: "&#x([0-9a-fA-F]{1,6});", radix: 16)
        result = decodeNumericEntities(result, pattern: "&#([0-9]{1,6});", radix: 10)

        return result
    }

    private static func decodeNumericEntities(_ text: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, options: [], range: range)
        if found.isEmpty {
            return text
        }

        let nsText = text as NSString
        var output = ""
        var cursor = 0

        for match in found {
            output += nsText.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )

            if let groupRange = Range(match.range(at: 1), in: text),
               let value = UInt32(String(text[groupRange]), radix: radix),
               let scalar = Unicode.Scalar(value) {
                output += String(Character(scalar))
            }

            cursor = match.range.location + match.range.length
        }

        output += nsText.substring(from: cursor)
        return output
    }

    // MARK: Помощники для регулярных выражений

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, options: [], range: range)
        let nsText = text as NSString

        return found.map { nsText.substring(with: $0.range) }
    }

    private static func captureGroups(in text: String, pattern: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, options: [], range: range)

        var result: [String] = []
        for match in found {
            if match.numberOfRanges > group, let subRange = Range(match.range(at: group), in: text) {
                result.append(String(text[subRange]))
            }
        }
        return result
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        captureGroups(in: text, pattern: pattern).first
    }

    // MARK: Чтение ZIP-контейнера EPUB

    private static func byte(_ data: Data, _ index: Int) -> UInt8 {
        guard index >= 0, data.startIndex + index < data.endIndex else {
            return 0
        }
        return data[data.index(data.startIndex, offsetBy: index)]
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, data.startIndex + offset + 1 < data.endIndex else {
            return nil
        }
        return UInt16(byte(data, offset)) | (UInt16(byte(data, offset + 1)) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, data.startIndex + offset + 3 < data.endIndex else {
            return nil
        }
        var value: UInt32 = 0
        for shift in 0..<4 {
            value |= UInt32(byte(data, offset + shift)) << UInt32(8 * shift)
        }
        return value
    }

    private static func subdata(_ data: Data, _ start: Int, _ length: Int) -> Data {
        guard start >= 0, length > 0, data.startIndex + start + length <= data.endIndex else {
            return Data()
        }
        let lower = data.index(data.startIndex, offsetBy: start)
        let upper = data.index(data.startIndex, offsetBy: start + length)
        return data.subdata(in: lower..<upper)
    }

    private static func findEOCD(in data: Data) -> Int {
        guard data.count >= 22 else {
            return -1
        }

        var offset = data.count - 22
        while offset >= 0 {
            if byte(data, offset) == 0x50,
               byte(data, offset + 1) == 0x4B,
               byte(data, offset + 2) == 0x05,
               byte(data, offset + 3) == 0x06 {
                return offset
            }
            offset -= 1
        }
        return -1
    }

    private static func zipEntries(in data: Data) -> [ZipEntry] {
        var entries: [ZipEntry] = []

        let eocdOffset = findEOCD(in: data)
        guard eocdOffset >= 0 else {
            return entries
        }

        let entryCount = Int(readUInt16LE(data, offset: eocdOffset + 10) ?? 0)
        var offset = Int(readUInt32LE(data, offset: eocdOffset + 16) ?? 0)

        for _ in 0..<entryCount {
            guard readUInt32LE(data, offset: offset) == 0x02014B50 else {
                break
            }

            let compressionMethod = Int(readUInt16LE(data, offset: offset + 10) ?? 0)
            let compressedSize = Int(readUInt32LE(data, offset: offset + 20) ?? 0)
            let nameLength = Int(readUInt16LE(data, offset: offset + 28) ?? 0)
            let extraLength = Int(readUInt16LE(data, offset: offset + 30) ?? 0)
            let commentLength = Int(readUInt16LE(data, offset: offset + 32) ?? 0)
            let localOffset = Int(readUInt32LE(data, offset: offset + 42) ?? 0)

            let nameData = subdata(data, offset + 46, nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            if !name.isEmpty, compressedSize > 0 {
                let localNameLength = Int(readUInt16LE(data, offset: localOffset + 26) ?? 0)
                let localExtraLength = Int(readUInt16LE(data, offset: localOffset + 28) ?? 0)
                let dataStart = localOffset + 30 + localNameLength + localExtraLength

                let raw = subdata(data, dataStart, compressedSize)
                var payload = raw
                if compressionMethod == 8 {
                    payload = inflate(raw)
                }

                entries.append(ZipEntry(name: name, data: payload))
            }

            offset = offset + 46 + nameLength + extraLength + commentLength
        }

        return entries
    }

    // COMPRESSION_ZLIB в платформенном фреймворке — это raw DEFLATE, как в ZIP
    private static func inflate(_ compressed: Data) -> Data {
        if let result = try? (compressed as NSData).decompressed(using: .zlib) as Data {
            return result
        }
        return compressed
    }
}

// MARK: - Экран чтения

struct ReadingScreenView: View {
    @ObservedObject private var theme = PlayTheme.shared
    @ObservedObject var store: EBookStore
    let onBack: () -> Void

    @State private var selectedBook: EBook?
    @State private var chapterIndex = 0
    @State private var showingImporter = false
    @State private var activeMenu = false

    var body: some View {
        ZStack {
            if let book = selectedBook {
                readerContent(book)
            } else {
                bookList
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
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
            .padding(.top, 12)
            .padding(.leading, 18)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    activeMenu = true
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
        .overlay {
            ZStack {
                if activeMenu {
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                activeMenu = false
                            }
                        }
                }

                VStack {
                    HStack {
                        Spacer()
                        readingMenu
                    }
                    .padding(.top, 66)
                    .padding(.trailing, 18)

                    Spacer()
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: activeMenu)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.epub, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                if let book = store.importBook(from: url) {
                    chapterIndex = 0
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedBook = book
                        activeMenu = false
                    }
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Не удалось обработать книгу",
            isPresented: Binding(
                get: { !store.errorMessage.isEmpty },
                set: { if !$0 { store.errorMessage = "" } }
            )
        ) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(store.errorMessage)
        }
    }

    private var readingMenu: some View {
        CustomMenu(
            title: nil,
            options: [
                CustomMenuOption(title: "Добавить книгу", systemImage: "doc.badge.plus") {
                    showingImporter = true
                }
            ],
            selectedIndex: nil,
            onSelect: { _ in },
            onClose: {
                withAnimation(.easeOut(duration: 0.2)) {
                    activeMenu = false
                }
            }
        )
    }

    private var bookList: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "book.closed")
                .font(.system(size: 54))
                .foregroundStyle(theme.ui.opacity(0.85))

            Text(store.books.isEmpty ? "Книг пока нет" : "Выберите книгу")
                .font(AppFont.bold(22))

            Text("Меню «⋯» → «Добавить книгу»\nПоддерживаются EPUB и TXT")
                .font(AppFont.regular(15))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            if !store.books.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.books) { book in
                            Button {
                                chapterIndex = 0
                                selectedBook = book
                            } label: {
                                HStack {
                                    Image(systemName: "text.book.closed")
                                        .font(.system(size: 20))
                                        .foregroundStyle(theme.ui)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(book.title)
                                            .font(AppFont.regular(17))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)

                                        Text("Добавлена \(book.addedDate.formatted(date: .abbreviated, time: .omitted))")
                                            .font(AppFont.regular(13))
                                            .foregroundStyle(.white.opacity(0.6))
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxHeight: 260)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func readerContent(_ book: EBook) -> some View {
        let chapters = store.chapters(for: book)
        let safeIndex = min(max(chapterIndex, 0), max(chapters.count - 1, 0))
        let chapterText = chapters.isEmpty ? "" : chapters[safeIndex]

        return VStack(spacing: 0) {
            Spacer().frame(height: 74)

            ScrollView {
                Text(chapterText)
                    .font(AppFont.regular(17))
                    .foregroundStyle(.white)
                    .lineSpacing(7)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if chapters.count > 1 {
                HStack {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            chapterIndex = max(safeIndex - 1, 0)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(theme.ui)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(safeIndex == 0)
                    .opacity(safeIndex == 0 ? 0.4 : 1)

                    Spacer()

                    Text("Глава \(safeIndex + 1) из \(chapters.count)")
                        .font(AppFont.regular(14))
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            chapterIndex = min(safeIndex + 1, chapters.count - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(theme.ui)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(safeIndex >= chapters.count - 1)
                    .opacity(safeIndex >= chapters.count - 1 ? 0.4 : 1)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
    }
}
