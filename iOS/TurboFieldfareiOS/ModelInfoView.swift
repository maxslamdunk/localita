import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation

/// What one model is, opened from its row in Settings → Models.
///
/// The two models this project pins get a description written here and the
/// speed measured on the phone. A community model gets what the app already
/// knows about it. Every model also gets its model card's metadata, read from
/// the Hugging Face API at the pinned revision: the license, base model and
/// languages are fields there already, so nothing is parsed out of the card's
/// prose. Offline, that section says so and the rest of the sheet is unchanged.
struct ModelInfoView: View {
    let descriptor: AppModelInstallDescriptor
    /// Downloaded, part-downloaded or not, as the row says it.
    let storedLabel: String
    /// Nil when there is nothing on the phone to delete.
    let deletion: Deletion?
    @Environment(\.dismiss) private var dismiss
    @State private var card: CardState = .loading
    @State private var isConfirmingDeletion = false

    struct Deletion {
        let isEnabled: Bool
        let message: String
        let perform: () -> Void
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(about)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detailsSection
                cardSection
                sourceSection
                if let deletion {
                    Section {
                        Button("Delete Model", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                        .disabled(!deletion.isEnabled)
                    }
                    .confirmationDialog("Delete \(descriptor.shortName)?",
                                        isPresented: $isConfirmingDeletion,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive, action: deletion.perform)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(deletion.message)
                    }
                }
            }
            .navigationTitle(descriptor.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { card = await CardState.fetch(descriptor) }
    }

    // MARK: - Known here

    private var about: String {
        switch descriptor.key {
        case AppModelInstallDescriptor.default.key:
            return "Google's Gemma 4 26B-A4B in its instruction-tuned release, "
                + "converted to MLX 4-bit by mlx-community. It is a mixture of "
                + "experts: 26 billion parameters in all, of which about 4 billion "
                + "work on each word, which is what lets it run on an iPhone. It "
                + "reads text and photos. This app is built and measured around it."
        case AppModelInstallDescriptor.supergemma4.key:
            return "A community fine-tune of Gemma 4 26B-A4B by Jiunsong, released "
                + "as uncensored: it turns down fewer requests than Gemma 4. Its "
                + "author reports better code, logic and Korean than Gemma 4; those "
                + "are the author's figures, not checked here. It has the same size "
                + "and layout as Gemma 4 and runs the same way. It has no image "
                + "model of its own and uses Gemma 4's image pack. Tested on this "
                + "iPhone, with photos too."
        default:
            return "Added from a Hugging Face link. Its files have Gemma 4's "
                + "layout, which the app checked before adding it, so it runs the "
                + "same way. It has not been tested here: its replies may be "
                + "worse than Gemma 4's, or broken. For photos it uses Gemma 4's "
                + "image pack."
        }
    }

    /// Short, medium and long benchmark cases at default settings, rounded.
    /// Gemma 4: 7.07 / 5.55 / 5.73 tok/s
    /// (`benchmark-results-2026-10-03-ios-expert-read-nocache/`). SuperGemma 4:
    /// 7.09 / 6.37 / 5.75 tok/s (`benchmark-results-2026-10-04-ios-supergemma4-guess/`).
    private var measuredSpeed: String? {
        switch descriptor.key {
        case AppModelInstallDescriptor.default.key: "About 5.5–7 tok/s"
        case AppModelInstallDescriptor.supergemma4.key: "About 5.8–7 tok/s"
        default: nil
        }
    }

    private var detailsSection: some View {
        Section {
            LabeledContent("On this iPhone", value: storedLabel)
            LabeledContent("Download", value: MetricFormat.storage(
                descriptor.approximateDownloadBytes))
            LabeledContent("Size installed", value: MetricFormat.storage(
                descriptor.installedBytes))
            LabeledContent("Photos", value: descriptor.key == AppModelInstallDescriptor.default.key
                           ? "Yes" : "With Gemma 4's image pack")
            if let measuredSpeed {
                LabeledContent("Speed", value: measuredSpeed)
            }
        } footer: {
            if measuredSpeed != nil {
                Text("Speed was measured on an iPhone 17 at the default 24 expert "
                     + "slots, over short, medium and long replies. Longer chats "
                     + "run slower.")
            } else if descriptor.key != AppModelInstallDescriptor.default.key {
                Text("Photos need Gemma 4 and its image pack on the iPhone.")
            }
        }
    }

    private var sourceSection: some View {
        Section {
            LabeledContent("Repository") {
                Text(descriptor.repoID)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Revision") {
                Text(String(descriptor.revision.prefix(7)))
                    .monospaced()
                    .textSelection(.enabled)
            }
            if let url = URL(string: "https://huggingface.co/\(descriptor.repoID)") {
                Link(destination: url) {
                    Label("Open on Hugging Face", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            Text("Source")
        } footer: {
            Text("The app downloads this revision, so a later change to the "
                 + "repository does not change the model.")
        }
    }

    // MARK: - From the model card

    @ViewBuilder
    private var cardSection: some View {
        Section {
            switch card {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading the model card…").foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("Hugging Face could not be reached.")
                    .foregroundStyle(.secondary)
            case .loaded(let fields) where fields.isEmpty:
                Text("The model card lists no license, base model or language.")
                    .foregroundStyle(.secondary)
            case .loaded(let fields):
                if let license = fields.license {
                    LabeledContent("License", value: license)
                }
                if let link = fields.licenseLink {
                    Link("License Terms", destination: link)
                }
                if !fields.baseModels.isEmpty {
                    LabeledContent("Based on") {
                        Text(fields.baseModels.joined(separator: "\n"))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !fields.languages.isEmpty {
                    LabeledContent("Languages", value: fields.languages.joined(separator: ", "))
                }
            }
        } header: {
            Text("Model Card")
        } footer: {
            Text("As the model's publisher states it on Hugging Face.")
        }
    }

    enum CardState {
        case loading, unavailable
        case loaded(CardFields)

        /// `GET /api/models/<repo>/revision/<sha>`: `cardData` is the card's
        /// metadata header, already split into fields.
        static func fetch(_ descriptor: AppModelInstallDescriptor) async -> CardState {
            guard let url = URL(string: "https://huggingface.co/api/models/"
                                + "\(descriptor.repoID)/revision/\(descriptor.revision)"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .unavailable }
            return .loaded(CardFields(json["cardData"] as? [String: Any] ?? [:]))
        }
    }

    struct CardFields {
        let license: String?
        let licenseLink: URL?
        let baseModels: [String]
        let languages: [String]

        /// Hugging Face's ids for the licenses these models usually carry.
        /// Any other id is shown as it is.
        private static let licenseNames = [
            "apache-2.0": "Apache 2.0", "mit": "MIT", "gemma": "Gemma",
        ]

        var isEmpty: Bool {
            license == nil && licenseLink == nil && baseModels.isEmpty && languages.isEmpty
        }

        /// Each field may be a string or a list of them; anything else is
        /// left out rather than guessed at.
        init(_ card: [String: Any]) {
            func strings(_ key: String) -> [String] {
                if let one = card[key] as? String { return [one] }
                return card[key] as? [String] ?? []
            }
            // "other" means the real name is in `license_name`.
            let named = strings("license").first
            let id = named == "other" ? strings("license_name").first ?? named : named
            license = id.map { Self.licenseNames[$0] ?? $0 }
            licenseLink = strings("license_link").first.flatMap(URL.init(string:))
            baseModels = strings("base_model")
            languages = strings("language").map {
                Locale.current.localizedString(forLanguageCode: $0) ?? $0
            }
        }
    }
}
