import Foundation

enum GoldDatasetStore {
    static let obligationsFilename = "obligation-gold-dataset.json"
    static let nearMissFilename = "non-obligation-gold-dataset.json"
    static let stratifiedFilename = "gold-dataset-stratified.json"
    static let selectedDatasetDefaultsKey = "goldDataset.selectedFilename"

    static func load(filename: String) -> GoldDatasetExport? {
        let url = documentsURL().appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GoldDatasetExport.self, from: data)
    }

    static func load(url: URL) -> GoldDatasetExport? {
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

    static func availableDatasetFilenames() -> [String] {
        let url = documentsURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files
            .map { $0.lastPathComponent }
            .filter { $0.lowercased().hasSuffix(".json") }
            .sorted()
    }

    static func defaultDatasetFilename() -> String? {
        let preferredOrder = [
            selectedDatasetFilename(),
            obligationsFilename,
            stratifiedFilename,
            nearMissFilename
        ].compactMap { $0 }

        let available = Set(availableDatasetFilenames())
        for name in preferredOrder where available.contains(name) {
            return name
        }
        return available.sorted().first
    }

    static func setSelectedDatasetFilename(_ filename: String) {
        UserDefaults.standard.set(filename, forKey: selectedDatasetDefaultsKey)
    }

    static func selectedDatasetFilename() -> String? {
        let value = UserDefaults.standard.string(forKey: selectedDatasetDefaultsKey)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
