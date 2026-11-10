import Foundation
import Testing
@testable import BirthCore

/// BirthCore's strings tables: the same lockstep rule as BirthUI's
/// (AppStateTests.localizationTablesStayInLockstep) — identical key sets
/// across languages, matching format-specifier types per key. Living in
/// BirthCoreTests keeps `Bundle.module` unambiguous. Languages are
/// listed manually: core cannot see BirthUI's AppLanguage — keep the
/// list in sync when a language lands.
@Suite("Core localization tables")
struct CoreLocalizationTests {
    @Test func tablesStayInLockstep() throws {
        let languages = ["en", "de", "es", "fr", "ja", "zh-Hans"]
        var tables: [String: [String: String]] = [:]
        for language in languages {
            let path = try #require(Bundle.module.path(
                forResource: "Localizable", ofType: "strings",
                inDirectory: nil, forLocalization: language
            ), "BirthCore: missing \(language) table")
            tables[language] = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        }
        let reference = Set(tables[languages[0]]!.keys)
        for language in languages.dropFirst() {
            let keys = Set(tables[language]!.keys)
            #expect(keys == reference, "BirthCore key sets differ — \(languages[0])-only: \(reference.subtracting(keys).sorted()), \(language)-only: \(keys.subtracting(reference).sorted())")
        }
        for key in reference {
            let variants = Set(languages.compactMap { language in
                tables[language]?[key].map { value in
                    value.matches(of: /%(\d+\$)?(@|lld)/).map { String($0.2) }.sorted().joined(separator: ",")
                }
            })
            #expect(variants.count <= 1, "BirthCore/\(key): format specifiers differ across languages")
        }
    }
}
