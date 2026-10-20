import Foundation
import SwiftUI

/// One piece of open-source software compiled into the app, with its license
/// text as it appears in the package at the pinned revision.
///
/// The list is `Acknowledgements.json`, which
/// `Scripts/generate_acknowledgements.rb` writes from `Package.resolved` and
/// the package checkouts. Edit the script, not the JSON.
struct Acknowledgement: Decodable, Identifiable {
    let name: String
    /// The package's version, or its revision when it is pinned by one.
    let version: String?
    /// A sentence for an entry that is not a plain package.
    let about: String?
    let url: URL
    let license: String
    /// Per-item copyright lines, for an entry that covers several works.
    let notes: [String]?
    let texts: [LicenseText]

    var id: String { name }

    struct LicenseText: Decodable, Identifiable {
        let title: String
        let body: String

        var id: String { title }
    }

    static let all: [Acknowledgement] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Acknowledgement].self, from: data)
        else {
            assertionFailure("Acknowledgements.json is missing or malformed")
            return []
        }
        return entries
    }()
}

/// Settings → Generation → Acknowledgements: the open-source code inside the
/// app and its licenses, which Apache-2.0 and MIT ask a binary to carry.
struct AcknowledgementsView: View {
    static let sourceURL = URL(string: "https://github.com/maxslamdunk/localita")!

    var body: some View {
        Form {
            Section {
                Text("Localita is open source under the Apache 2.0 license.")
                Link(destination: Self.sourceURL) {
                    Label("Source Code", systemImage: "arrow.up.right.square")
                }
            }
            Section {
                ForEach(Acknowledgement.all) { entry in
                    NavigationLink {
                        AcknowledgementDetailView(entry: entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text([entry.version, entry.license]
                                .compactMap { $0 }
                                .joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Built Into the App")
            } footer: {
                Text("The open-source code built into the app, and its licenses. "
                     + "Models are downloaded separately and are not part of the "
                     + "app; each one's license is on its page in Settings → "
                     + "Models. Gemma is a trademark of Google LLC.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementDetailView: View {
    let entry: Acknowledgement

    var body: some View {
        Form {
            Section {
                if let about = entry.about {
                    Text(about)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let version = entry.version {
                    LabeledContent("Version", value: version)
                }
                LabeledContent("License", value: entry.license)
                Link(destination: entry.url) {
                    Label("Source", systemImage: "arrow.up.right.square")
                }
            }
            if let notes = entry.notes {
                Section("Copyright") {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(entry.texts) { text in
                Section(text.title) {
                    // Verbatim, line breaks included: it is the license text.
                    Text(text.body)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
