import SwiftUI
import Compression
import UniformTypeIdentifiers

// MARK: - Хранилище электронных книг
//
// Книги копируются в Documents/EBooks, поэтому сохраняются после перезапуска
// приложения. Существующая аудиобиблиотека не затрагивается: refreshLibrary()
// читает только корень Documents и отбирает файлы по аудио-расширениям,
// а электронные книги лежат во вложенной папке EBooks.

final class EBookStore: ObservableObject {
    @Published private(set) var books: [URL] = []
    @Published private(set) var currentURL: URL?
    @Published private(set) var bookTitle = ""
    @Published private(set) var text = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage = ""

    private var loadTicket = UUID()

    static var ebooksFolder: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let folder = documents.appendingPathComponent("EBooks", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        return folder
    }

    func refresh() {
        let folder = Self.ebooksFolder

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []

        books = files
            .filter { ["epub", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }
    }

    func handleImporter(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let sourceURL = urls.first else { return }
        importEbook(from: sourceURL)
    }

    func importEbook(from sourceURL: URL) {
        let ext = sourceURL.pathExtension.lowercased()

        guard ext == "epub" || ext == "txt" else {
            errorMessage = "Поддерживаются форматы EPUB и TXT"
            return
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let folder = Self.ebooksFolder
            let baseName = sourceURL.deletingPathExtension().lastPathComponent

            var destination = folder.appendingPathComponent(sourceURL.lastPathComponent)
            var number = 2

            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(baseName) (\(number)).\(ext)")
                number += 1
            }

            try FileManager.default.copyItem(at: sourceURL, to: destination)

            refresh()
            errorMessage = ""
            open(destination)
        } catch {
            errorMessage = "Не удалось добавить книгу: \(error.localizedDescription)"
        }
    }

    func open(_ url: URL) {
        currentURL = url
        bookTitle = url.deletingPathExtension().lastPathComponent
        text = ""
        isLoading = true
        errorMessage = ""

        let ticket = UUID()
        loadTicket = ticket

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = EBookParser.load(from: url)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadTicket == ticket else { return }

                isLoading = false

                if let loaded, !loaded.text.isEmpty {
                    text = loaded.text

                    if let parsedTitle = loaded.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !parsedTitle.isEmpty {
                        bookTitle = parsedTitle
                    }
                } else {
                    text = ""
                    errorMessage = "Не удалось прочитать книгу"
                }
            }
        }
    }
}

// MARK: - Разбор электронных книг (TXT и EPUB)

struct LoadedBook {
    let text: String
    let title: String?
}

enum EBookParser {
    static func load(from url: URL) -> LoadedBook? {
        switch url.pathExtension.lowercased() {
        case "txt":
            guard let text = loadTXT(from: url) else { return nil }
            return LoadedBook(text: text, title: nil)
        case "epub":
            return loadEPUB(from: url)
        default:
            return nil
        }
    }

    // MARK: TXT

    static func loadTXT(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let text = String(data: data, encoding: .utf8) {
            return text.isEmpty ? nil : text
        }

        // Нередко txt-файлы сохранены в Windows-1251
        let cp1251 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCP1251.rawValue)
        )

        if let text = String(data: data, encoding: String.Encoding(rawValue: cp1251)) {
            return text
        }

        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: EPUB

    static func loadEPUB(from url: URL) -> LoadedBook? {
        guard let archive = try? Data(contentsOf: url) else { return nil }
        guard let entries = zipEntries(in: archive) else { return nil }

        // 1. META-INF/container.xml → путь к OPF
        guard let containerEntry = entry(named: "META-INF/container.xml", in: entries),
              let containerData = readEntry(containerEntry, from: archive),
              let containerXML = utf8(containerData),
              let opfPath = attribute("full-path", in: containerXML)
        else { return nil }

        let normalizedOPFPath = normalizePath(opfPath)

        // 2. OPF → manifest и spine
        guard let opfEntry = entry(named: normalizedOPFPath, in: entries),
              let opfData = readEntry(opfEntry, from: archive),
              let opf = utf8(opfData)
        else { return nil }

        let opfFolder = (normalizedOPFPath as NSString).deletingLastPathComponent

        // manifest: id → путь к файлу главы
        var idToHref: [String: String] = [:]
        for tag in tagContents(of: "item", in: opf) {
            if let id = attribute("id", in: tag), let href = attribute("href", in: tag) {
                idToHref[id] = href
            }
        }

        // spine: порядок чтения глав
        var chapterHrefs: [String] = []
        for tag in tagContents(of: "itemref", in: opf) {
            if let idref = attribute("idref", in: tag), let href = idToHref[idref] {
                chapterHrefs.append(href)
            }
        }

        // Запасной вариант: если spine не описан — берём все html-файлы по алфавиту
        if chapterHrefs.isEmpty {
            chapterHrefs = entries
                .map { $0.name }
                .filter {
                    $0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm")
                }
                .sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
        }

        // 3. Склеиваем главы
        var chapters: [String] = []

        for href in chapterHrefs {
            let path = resolvePath(href, relativeTo: opfFolder)

            guard let chapterEntry = entry(named: path, in: entries),
                  let chapterData = readEntry(chapterEntry, from: archive),
                  let chapterHTML = utf8(chapterData)
            else { continue }

            let chapterText = plainText(fromHTML: chapterHTML)
            if !chapterText.isEmpty {
                chapters.append(chapterText)
            }
        }

        guard !chapters.isEmpty else { return nil }

        return LoadedBook(
            text: chapters.joined(separator: "\n\n"),
            title: bookTitle(fromOPF: opf)
        )
    }

    static func bookTitle(fromOPF opf: String) -> String? {
        let title = value(ofTag: "dc:title", in: opf)
            ?? value(ofTag: "title", in: opf)

        return title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTML → обычный текст

    static func plainText(fromHTML html: String) -> String {
        var s = html

        // Комментарии, скрипты и стили убираем целиком
        s = replacing(s, pattern: "<!--[\\s\\S]*?-->", template: " ")
        s = replacing(s, pattern: "(?i)<script[\\s\\S]*?</script>", template: " ")
        s = replacing(s, pattern: "(?i)<style[\\s\\S]*?</style>", template: " ")

        // Разрывы строк и закрывающие блочные теги → переводы строк
        s = replacing(s, pattern: "(?i)<br\\s*/?>", template: "\n")
        s = replacing(
            s,
            pattern: "(?i)</(p|div|h[1-6]|li|tr|section|article|blockquote|figcaption)>",
            template: "\n\n"
        )

        // Остальные теги убираем
        s = replacing(s, pattern: "<[^>]+>", template: "")

        s = decodeEntities(s)

        // Приводим пробелы и пустые строки в порядок
        s = replacing(s, pattern: "[^\\S\\n]+", template: " ")
        s = replacing(s, pattern: "\n{3,}", template: "\n\n")

        let lines = s
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var collapsed: [String] = []
        var lastWasEmpty = false

        for line in lines {
            if line.isEmpty {
                if !lastWasEmpty {
                    collapsed.append(line)
                }
                lastWasEmpty = true
            } else {
                collapsed.append(line)
                lastWasEmpty = false
            }
        }

        return collapsed
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ input: String) -> String {
        var s = input

        let named: [(String, String)] = [
            ("&nbsp;", "\u{00A0}"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&laquo;", "«"),
            ("&raquo;", "»"),
            ("&ldquo;", "“"),
            ("&rdquo;", "”"),
            ("&lsquo;", "‘"),
            ("&rsquo;", "’"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'")
        ]

        for (entity, symbol) in named {
            s = s.replacingOccurrences(of: entity, with: symbol)
        }

        func replaceNumeric(_ string: String, pattern: String, isHex: Bool) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return string
            }

            let matches = regex.matches(
                in: string,
                range: NSRange(string.startIndex..., in: string)
            )

            var result = string

            // Заменяем с конца, чтобы индексы не съезжали
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let digitsRange = Range(match.range(at: 1), in: result)
                else { continue }

                let digits = String(result[digitsRange])
                let value = isHex ? UInt32(digits, radix: 16) : UInt32(digits)

                if let value, let scalar = Unicode.Scalar(value) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }

            return result
        }

        s = replaceNumeric(s, pattern: "&#(\\d+);", isHex: false)
        s = replaceNumeric(s, pattern: "&#x([0-9a-fA-F]+);", isHex: true)

        // &amp; — в самом конце, чтобы не раскрыть двойные последовательности
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replacing(_ source: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }

        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: template
        )
    }

    // MARK: Помощники разбора XML

    private static func value(ofTag tag: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>",
            options: .caseInsensitive
        ) else { return nil }

        let range = NSRange(xml.startIndex..., in: xml)

        guard let match = regex.firstMatch(in: xml, range: range),
              let contentRange = Range(match.range(at: 1), in: xml)
        else { return nil }

        return String(xml[contentRange])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "(?:^|[\\s\\r\\n])\(name)\\s*=\\s*\"([^\"]*)\"",
            options: .caseInsensitive
        ) else { return nil }

        let range = NSRange(tag.startIndex..., in: tag)

        guard let match = regex.firstMatch(in: tag, range: range),
              let valueRange = Range(match.range(at: 1), in: tag)
        else { return nil }

        return String(tag[valueRange])
    }

    private static func tagContents(of tagName: String, in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tagName)\\b[^>]*>",
            options: .caseInsensitive
        ) else { return [] }

        let range = NSRange(xml.startIndex..., in: xml)
        let matches = regex.matches(in: xml, range: range)

        return matches.compactMap { match in
            guard let tagRange = Range(match.range, in: xml) else { return nil }
            return String(xml[tagRange])
        }
    }

    private static func normalizePath(_ path: String) -> String {
        var components: [String] = []

        for part in path.split(separator: "/") {
            if part == "." {
                continue
            }
            if part == ".." {
                if !components.isEmpty {
                    components.removeLast()
                }
            } else {
                components.append(String(part))
            }
        }

        return components.joined(separator: "/")
    }

    private static func resolvePath(_ href: String, relativeTo base: String) -> String {
        var cleaned = href.trimmingCharacters(in: .whitespaces)

        // Убираем якорь и расшифровываем %20 и прочие экранирования
        if let anchorIndex = cleaned.firstIndex(of: "#") {
            cleaned = String(cleaned[..<anchorIndex])
        }
        cleaned = cleaned.removingPercentEncoding ?? cleaned

        if cleaned.isEmpty {
            return ""
        }

        if cleaned.hasPrefix("/") {
            return normalizePath(cleaned)
        }

        let joined = base.isEmpty ? cleaned : base + "/" + cleaned
        return normalizePath(joined)
    }

    private static func utf8(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func entry(named name: String, in entries: [ZipEntry]) -> ZipEntry? {
        guard !name.isEmpty else { return nil }
        return entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Минимальный разбор ZIP-контейнера EPUB
    // Поддержаны методы сжатия 0 (stored) и 8 (deflate) — их используют все EPUB.

    private struct ZipEntry {
        let name: String
        let method: UInt16
        let dataOffset: Int
        let compressedSize: Int
    }

    private static func zipEntries(in data: Data) -> [ZipEntry]? {
        guard data.count > 22 else { return nil }

        // Ищем EOCD-запись с конца архива
        let searchStart = max(0, data.count - 66_000)
        var eocdOffset = -1
        var index = data.count - 22

        while index >= searchStart {
            if data[index] == 0x50, data[index + 1] == 0x4B,
               data[index + 2] == 0x05, data[index + 3] == 0x06 {
                eocdOffset = index
                break
            }
            index -= 1
        }

        guard eocdOffset >= 0 else { return nil }

        let entriesCount = Int(readUInt16(data, eocdOffset + 10))
        let centralDirectorySize = Int(readUInt32(data, eocdOffset + 12))
        let centralDirectoryOffset = Int(readUInt32(data, eocdOffset + 16))

        guard centralDirectoryOffset + centralDirectorySize <= data.count else { return nil }

        var entries: [ZipEntry] = []
        var cursor = centralDirectoryOffset

        for _ in 0..<entriesCount {
            guard cursor + 46 <= data.count,
                  readUInt32(data, cursor) == 0x02014B50
            else { break }

            let method = readUInt16(data, cursor + 10)
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, cursor + 42))

            guard cursor + 46 + nameLength <= data.count else { break }

            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            if !name.isEmpty && !name.hasSuffix("/") {
                let localNameLength = Int(readUInt16(data, localHeaderOffset + 26))
                let localExtraLength = Int(readUInt16(data, localHeaderOffset + 28))
                let dataOffset = localHeaderOffset + 30 + localNameLength + localExtraLength

                if method == 0 || method == 8,
                   localHeaderOffset + 30 + localNameLength + localExtraLength <= data.count {
                    entries.append(
                        ZipEntry(
                            name: name,
                            method: method,
                            dataOffset: dataOffset,
                            compressedSize: compressedSize
                        )
                    )
                }
            }

            cursor += 46 + nameLength + extraLength + commentLength
        }

        return entries.isEmpty ? nil : entries
    }

    private static func readEntry(_ entry: ZipEntry, from data: Data) -> Data? {
        let start = entry.dataOffset
        let end = start + entry.compressedSize

        guard end <= data.count else { return nil }

        let raw = data.subdata(in: start..<end)

        switch entry.method {
        case 0:
            return raw
        case 8:
            return inflate(raw)
        default:
            return nil
        }
    }

    private static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }

        let chunkSize = 65_536
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        var output = Data()
        var succeeded = false

        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let source = raw.bindMemory(to: UInt8).baseAddress else { return }

            var stream = compression_stream(
                dst_ptr: dstBuffer,
                dst_size: 0,
                src_ptr: UnsafePointer(source),
                src_size: input.count,
                state: nil
            )

            guard compression_stream_init(
                &stream,
                COMPRESSION_STREAM_DECODE,
                COMPRESSION_ZLIB
            ) == COMPRESSION_STATUS_OK else { return }

            defer { compression_stream_destroy(&stream) }

            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            repeat {
                stream.dst_ptr = dstBuffer
                stream.dst_size = chunkSize

                let status = compression_stream_process(&stream, flags)

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = chunkSize - stream.dst_size
                    if produced > 0 {
                        output.append(dstBuffer, count: produced)
                    }
                    if status == COMPRESSION_STATUS_END {
                        succeeded = true
                        return
                    }
                default:
                    return
                }
            } while stream.src_size > 0 || stream.dst_size < chunkSize
        }

        return succeeded ? output : nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

// MARK: - Экран чтения

struct ReadingScreenView: View {
    @EnvironmentObject private var theme: PlayTheme
    @ObservedObject var store: EBookStore
    let onBack: () -> Void

    @State private var showingImporter = false
    @State private var showingMenu = false

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isLoading {
                        ProgressView()
                            .tint(theme.ui)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 140)
                    } else if let url = store.currentURL, !store.text.isEmpty {
                        Text(store.bookTitle)
                            .font(AppFont.bold(24))
                            .foregroundStyle(theme.ui)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                            .padding(.horizontal, 24)

                        Text(store.text)
                            .font(AppFont.regular(17))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineSpacing(6)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 40)
                    } else if !store.books.isEmpty {
                        VStack(spacing: 10) {
                            Text("Электронные книги")
                                .font(AppFont.bold(24))
                                .foregroundStyle(theme.ui)
                                .padding(.top, 64)

                            ForEach(store.books, id: \.self) { url in
                                Button {
                                    store.open(url)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(
                                            systemName: url.pathExtension.lowercased() == "epub"
                                                ? "book.fill"
                                                : "doc.text.fill"
                                        )
                                        .foregroundStyle(theme.ui)

                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .font(AppFont.regular(17))
                                            .foregroundStyle(.white)
                                            .multilineTextAlignment(.leading)

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
                            }
                        }
                        .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 44))
                                .foregroundStyle(theme.ui.opacity(0.7))

                            Text("Электронных книг пока нет")
                                .font(AppFont.regular(15))
                                .foregroundStyle(.white.opacity(0.7))

                            Text("Откройте меню в правом верхнем углу и выберите «Добавить книгу»")
                                .font(AppFont.regular(13))
                                .foregroundStyle(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 140)
                        .padding(.horizontal, 32)
                    }

                    if !store.errorMessage.isEmpty {
                        Text(store.errorMessage)
                            .foregroundStyle(.red)
                            .font(AppFont.regular(13))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 24)
                    }

                    Spacer(minLength: 40)
                }
            }

            // Затемнение под меню — как на главном экране
            if showingMenu {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showingMenu = false
                        }
                    }
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topLeading) {
            Button(action: onBack) {
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
        .overlay {
            if showingMenu {
                VStack {
                    HStack {
                        Spacer()

                        CustomMenu(
                            title: nil,
                            options: [
                                CustomMenuOption(
                                    title: "Добавить книгу",
                                    systemImage: "doc.badge.plus"
                                ) {
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
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showingMenu)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.epub, .plainText],
            allowsMultipleSelection: false
        ) { result in
            store.handleImporter(result)
        }
        .onAppear {
            store.refresh()
        }
    }
}
