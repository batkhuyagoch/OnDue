import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @State private var exportPath: String?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var stratifiedExportPath: String?
    @State private var stratifiedExportURL: URL?
    @State private var stratifiedExportError: String?
    @State private var nearMissExportPath: String?
    @State private var nearMissExportURL: URL?
    @State private var nearMissExportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy & Data") {
                    if let privacyPolicyURL = AppPrivacyConfiguration.privacyPolicyURL {
                        Link(destination: privacyPolicyURL) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Privacy policy")
                                    .font(.subheadline.weight(.semibold))
                                Text("Review what data is accessed, stored, and how deletion works")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        ConnectGmailView()
                            .environmentObject(environment)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect Gmail & data controls")
                                .font(.subheadline.weight(.semibold))
                            Text("Connect account, view disclosures, reset cache, or delete all account data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

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
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export failed: \(exportError)")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Text("Tap Export gold dataset above to try again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                                stratifiedExportPath = url.path
                                stratifiedExportURL = url
                                stratifiedExportError = nil
                            } catch {
                                stratifiedExportError = error.localizedDescription
                            }
                        }
                    }
                    if let stratifiedExportPath {
                        Text(stratifiedExportPath)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let stratifiedExportError {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export failed: \(stratifiedExportError)")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Text("Tap the stratified export button above to retry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let stratifiedExportURL {
                        ShareLink(item: stratifiedExportURL) {
                            Label("Share stratified export", systemImage: "square.and.arrow.up")
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export failed: \(nearMissExportError)")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Text("Tap the near-miss export button above to retry.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
