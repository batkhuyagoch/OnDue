import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @State private var exportPath: String?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var nearMissExportPath: String?
    @State private var nearMissExportURL: URL?
    @State private var nearMissExportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Notifications") {
                    NavigationLink {
                        DigestSettingsView()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Daily Digest")
                                .font(.subheadline.weight(.semibold))
                            Text("Get notified about items needing review")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
#if DEBUG
                Section("Debug") {
                    Button("Export gold dataset") {
                        Task {
                            do {
                                let url = try await GoldDatasetExporter.export(environment: environment.value)
                                exportPath = url.path
                                exportURL = url
                                exportError = nil
                            } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }
                    if let exportPath {
                        Text(exportPath)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share export", systemImage: "square.and.arrow.up")
                        }
                    }

                    Button("Export stratified gold dataset") {
                        Task {
                            do {
                                let url = try await GoldDatasetExporter.exportStratified(environment: environment.value)
                                exportPath = url.path
                                exportURL = url
                                exportError = nil
                            } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }

                    Button("Export non-obligation near-misses") {
                        Task {
                            do {
                                let url = try await GoldDatasetExporter.exportNearMisses(environment: environment.value)
                                nearMissExportPath = url.path
                                nearMissExportURL = url
                                nearMissExportError = nil
                            } catch {
                                nearMissExportError = error.localizedDescription
                            }
                        }
                    }
                    if let nearMissExportPath {
                        Text(nearMissExportPath)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let nearMissExportError {
                        Text(nearMissExportError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let nearMissExportURL {
                        ShareLink(item: nearMissExportURL) {
                            Label("Share near-miss export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
#endif
            }
            .navigationTitle("Settings")
        }
    }
}
