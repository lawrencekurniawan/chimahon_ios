import Foundation
import CHoshiDicts
import CxxStdlib

// MARK: - C++ string bridging (via the CxxStdlib overlay)

enum Cpp {
    static func str(_ s: String) -> std.string {
        std.string(s)
    }

    static func swift(_ s: std.string) -> String {
        String(s)
    }
}

/// Owns the non-copyable C++ engine objects.
/// @unchecked Sendable: in this spike, import mutates `query` once on a background
/// task before any lookup runs; afterwards reads happen on the main actor only.
final class EngineBox: @unchecked Sendable {
    static let shared = EngineBox()
    var query = DictionaryQuery()
    var deinflector = Deinflector()
    private init() {}
}

/// One lookup hit surfaced to SwiftUI.
struct LookupEntry: Identifiable {
    let id = UUID()
    let expression: String
    let reading: String
    let glossaries: [String]
    let frequencies: [String]
    let pitchPositions: [Int]
    let deinflectedFrom: String?
    let trace: [String]
}

struct KanjiEntryModel: Identifiable {
    let id = UUID()
    let character: String
    let onyomi: String
    let kunyomi: String
    let definitions: [String]
    let stats: [String: String]
}

enum ImportState: Equatable {
    case idle
    case importing
    case done(title: String, terms: Int)
    case failed(String)
}

@MainActor
@Observable
final class DictionaryStore {
    var importState: ImportState = .idle

    func bootstrap() async {
        guard importState == .idle else { return }
        importState = .importing
        do {
            let (terms, title) = try await Task.detached(priority: .userInitiated) {
                try Self.importBundledDictionary()
            }.value
            importState = .done(title: title, terms: terms)
        } catch {
            importState = .failed(String(describing: error))
        }
    }

    nonisolated private static func importBundledDictionary() throws -> (terms: Int, title: String) {
        guard let zipURL = Bundle.main.url(forResource: "spike-dict", withExtension: "zip") else {
            throw NSError(domain: "spike", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "spike-dict.zip missing from bundle"])
        }
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicts", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let result = dictionary_importer.`import`(Cpp.str(zipURL.path), Cpp.str(outDir), false)
        guard result.success else {
            let errs = result.errors.map { Cpp.swift($0) }.joined(separator: "; ")
            throw NSError(domain: "spike", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "import failed: \(errs)"])
        }

        // One imported folder serves every entry type it contains: register it under
        // all four query vectors (mirrors Android's DictionaryPaths/DictionaryTypes).
        let dictPath = (outDir as NSString).appendingPathComponent(Cpp.swift(result.title))
        let cppPath = Cpp.str(dictPath)
        EngineBox.shared.query.add_term_dict(cppPath)
        if result.freq_count > 0 { EngineBox.shared.query.add_freq_dict(cppPath) }
        if result.pitch_count > 0 { EngineBox.shared.query.add_pitch_dict(cppPath) }
        if result.kanji_count > 0 { EngineBox.shared.query.add_kanji_dict(cppPath) }
        return (terms: Int(result.term_count), title: Cpp.swift(result.title))
    }

    func lookup(_ text: String) -> [LookupEntry] {
        guard !text.isEmpty else { return [] }
        let box = EngineBox.shared
        let engine = Lookup(&box.query, &box.deinflector)
        let results = engine.lookup(Cpp.str(text), 16, 16)
        return results.map { r in
            let term = r.term
            return LookupEntry(
                expression: Cpp.swift(term.expression),
                reading: Cpp.swift(term.reading),
                glossaries: term.glossaries.map { Self.renderGlossary(Cpp.swift($0.glossary)) },
                frequencies: term.frequencies.flatMap { entry in
                    entry.frequencies.map { Cpp.swift($0.display_value) }
                },
                pitchPositions: term.pitches.flatMap { entry in entry.pitch_positions.map { Int($0) } },
                deinflectedFrom: Cpp.swift(r.deinflected) == text ? nil : Cpp.swift(r.deinflected),
                trace: r.trace.map { "\(Cpp.swift($0.name)): \(Cpp.swift($0.description))" }
            )
        }
    }

    func kanjiLookup(_ text: String) -> [KanjiEntryModel] {
        let chars = Array(text)
        guard chars.count == 1 else { return [] }
        let box = EngineBox.shared
        let result = box.query.query_kanji(Cpp.str(text))
        guard !result.character.empty() else { return [] }
        return result.entries.map { e in
            // e.stats is std::unordered_map<std::string,std::string>, which Swift C++
            // interop cannot iterate — omitted in the spike.
            let stats: [String: String] = [:]
            return KanjiEntryModel(
                character: Cpp.swift(result.character),
                onyomi: Cpp.swift(e.onyomi),
                kunyomi: Cpp.swift(e.kunyomi),
                definitions: e.definitions.map { Cpp.swift($0) },
                stats: stats
            )
        }
    }

    /// Glossary raw JSON → display strings (sample dict uses string arrays;
    /// real Yomitan dicts can also carry structured-content objects).
    private nonisolated static func renderGlossary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return trimmed
        }
        if let arr = obj as? [Any] {
            return arr.map { renderGlossaryItem($0) }.joined(separator: "\n")
        }
        return renderGlossaryItem(obj)
    }

    private nonisolated static func renderGlossaryItem(_ obj: Any) -> String {
        if let s = obj as? String { return s }
        if let dict = obj as? [String: Any] {
            if let text = dict["text"] as? String { return text }
            if dict["type"] as? String == "structured-content",
               let content = dict["content"] as? [Any] {
                return content.map { renderGlossaryItem($0) }.joined()
            }
            if let s = dict["glossary"] as? String { return s }
        }
        return String(describing: obj)
    }
}
