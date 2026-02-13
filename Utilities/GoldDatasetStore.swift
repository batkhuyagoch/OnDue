import Foundation

enum GoldDatasetStore {
    static let obligationsFilename = "obligation-gold-dataset.json"
    static let nearMissFilename = "non-obligation-gold-dataset.json"
    static let stratifiedFilename = "gold-dataset-stratified.json"

    static func load(filename: String) -> GoldDatasetExport? {
        let url = documentsURL().appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GoldDatasetExport.self, from: data)
    }

    static func save(export: GoldDatasetExport, filename: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        let url = documentsURL().appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
