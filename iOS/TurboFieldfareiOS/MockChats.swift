import Foundation
import TurboFieldfare
import TurboFieldfareAppCore

/// Test chats for looking at the chat list, written by launch argument.
///
/// `--seed-mock-chats` writes thirty short conversations, one question and one
/// answer each, spread from minutes to weeks ago so every day group shows.
/// `--remove-mock-chats` deletes them again. Nothing else in the store is
/// touched: the mock chats have fixed IDs, and only those are written or
/// removed, so running either twice does nothing new.
///
/// They go through `ConversationStore` like a real turn, so they are stored in
/// the real format. They carry no tokens, so sending into one reads it as
/// having no replay and starts over; they are for looking at, not continuing.
///
/// Runs before `AppModel` exists, because the model's store takes the writer
/// lock when it activates, and this store has to have let go of it by then.
enum MockChats {
    static func applyLaunchArguments(modelDirectory: URL) {
        let arguments = LaunchArguments.all
        let seeds = arguments.contains("--seed-mock-chats")
        let removes = arguments.contains("--remove-mock-chats")
        guard seeds || removes else { return }

        let root = ConversationStoreLocation.url(forModelDirectory: modelDirectory)
        let identity = (try? ConversationIdentity.forModelDirectory(modelDirectory))
            ?? ConversationIdentity(modelID: "google/gemma-4-26B-A4B-it",
                                    sourceSnapshotHash: "mock",
                                    templateIdentity: GFTokenizer.chatTemplateIdentity,
                                    imageProcessingVersion: VisionImageProcessing.version)
        // Blocks launch for the few hundred milliseconds thirty small writes
        // take, which is what keeps the lock handover ordered.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let store = ConversationStore(rootURL: root)
            do {
                try await store.activate()
                if removes {
                    for index in chats.indices {
                        try? await store.delete(id: id(index))
                    }
                } else {
                    try await seed(store, identity: identity)
                }
            } catch {
                Suspension.log.error("mock chats: \(String(describing: error), privacy: .public)")
            }
            done.signal()
        }
        done.wait()
    }

    private static func seed(_ store: ConversationStore,
                             identity: ConversationIdentity) async throws {
        let existing = Set(try await store.list().map(\.id))
        let session = ConversationSessionSettings(
            contextTokens: 8_192, expertCacheSlots: 24,
            visionResidencyPolicy: "onDemand")
        let now = Date()
        for (index, chat) in chats.enumerated() where !existing.contains(id(index)) {
            let at = now.addingTimeInterval(-chat.hoursAgo * 3_600)
            _ = try await store.create(id: id(index), title: chat.title,
                                       identity: identity, session: session,
                                       sampling: .windowDefaults, now: at)
            try await store.append([
                .turn(ConversationTurnRecord(role: .user, at: at, text: chat.question)),
                .turn(ConversationTurnRecord(role: .assistant,
                                             at: at.addingTimeInterval(20),
                                             text: chat.answer,
                                             stopReason: "endOfTurn")),
            ], to: id(index))
        }
    }

    /// Fixed, and recognisable on disk by their all-zero first part.
    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
    }

    private struct Chat {
        let hoursAgo: Double
        let title: String
        let question: String
        let answer: String
    }

    private static let chats: [Chat] = [
        Chat(hoursAgo: 0.2, title: "Sourdough starter smells like acetone",
             question: "My sourdough starter smells like nail polish remover. Is it ruined?",
             answer: "No. That smell means it is hungry: the yeast has run out of food and is producing acetone-like by-products. Feed it twice a day at a higher ratio, say 1:5:5, and it should smell sweet and tangy again within two or three days."),
        Chat(hoursAgo: 1.5, title: "Swift actor reentrancy",
             question: "What does actor reentrancy mean in Swift?",
             answer: "An actor method that awaits can be suspended, and while it is, other calls into the same actor may run. So any state you read before an `await` may have changed after it. Re-check assumptions after each suspension point, or do the whole update without awaiting."),
        Chat(hoursAgo: 4, title: "Packing list for a weekend hike",
             question: "What should I pack for a two-day hike in early autumn?",
             answer: "Layers above all: a base layer, a fleece and a waterproof shell. Add a warm hat, a head torch, a map, water filtering, a first-aid kit, and more food than you think. Nights in autumn get cold quickly once the sun is down."),
        Chat(hoursAgo: 7, title: "Explain the Monty Hall problem",
             question: "Why should you switch doors in the Monty Hall problem?",
             answer: "Your first pick is right one time in three. The host always opens a losing door from the other two, so the remaining closed door carries the other two thirds. Switching wins exactly when your first pick was wrong, which is two times in three."),
        Chat(hoursAgo: 27, title: "Translate a short note to Spanish",
             question: "Translate: \u{201C}Thanks for dinner, see you next week.\u{201D}",
             answer: "\u{201C}Gracias por la cena, nos vemos la próxima semana.\u{201D}"),
        Chat(hoursAgo: 31, title: "Why is the sky blue",
             question: "Why is the sky blue and not violet?",
             answer: "Shorter wavelengths scatter more, so violet scatters most. But sunlight has less violet than blue, some violet is absorbed high in the atmosphere, and our eyes are much more sensitive to blue. Together those make the sky look blue."),
        Chat(hoursAgo: 52, title: "Git: undo the last commit",
             question: "How do I undo my last commit but keep the changes?",
             answer: "`git reset --soft HEAD~1` moves the branch back one commit and leaves the changes staged. Use `--mixed` instead to leave them unstaged. If you already pushed, prefer `git revert` so you don't rewrite shared history."),
        Chat(hoursAgo: 76, title: "Houseplant with yellow leaves",
             question: "My pothos has yellow leaves at the bottom. What's wrong?",
             answer: "Most often overwatering. Let the top few centimetres of soil dry before watering again, and make sure the pot drains. A few yellow lower leaves on an older plant can also just be normal ageing."),
        Chat(hoursAgo: 101, title: "Birthday message for a colleague",
             question: "Write a short birthday message for a colleague I don't know well.",
             answer: "Happy birthday! Wishing you a great day and a year ahead full of good things. Hope there's cake involved."),
        Chat(hoursAgo: 128, title: "Metric to imperial for a recipe",
             question: "How much is 250 g of flour in cups?",
             answer: "About 2 cups of all-purpose flour, spooned and levelled. A kitchen scale is more reliable, since a scooped cup can weigh 20% more than a spooned one."),
        Chat(hoursAgo: 158, title: "What is a Bloom filter",
             question: "Explain a Bloom filter in two sentences.",
             answer: "A Bloom filter is a bit array with several hash functions that answers \u{201C}definitely not in the set\u{201D} or \u{201C}probably in the set\u{201D}. It uses very little memory, at the price of occasional false positives and no way to remove items."),
        Chat(hoursAgo: 210, title: "Stretching routine for desk work",
             question: "Give me a five-minute stretching routine for working at a desk.",
             answer: "One minute each: neck tilts side to side, shoulder rolls, a doorway chest stretch, a seated hip-flexor lunge on each side, and a standing forward fold. Breathe slowly and don't bounce."),
        Chat(hoursAgo: 260, title: "Summary of the French Revolution",
             question: "Summarise the French Revolution in a paragraph.",
             answer: "Beginning in 1789 with a fiscal crisis and the Estates-General, it overthrew the absolute monarchy, abolished feudal privileges and proclaimed the rights of man. Radicalisation led to the Republic, the Terror and war with Europe, and it ended with Napoleon's coup in 1799."),
        Chat(hoursAgo: 330, title: "Best way to learn a language",
             question: "What's the most effective way to learn a new language as an adult?",
             answer: "Daily contact beats long sessions: spaced-repetition vocabulary, lots of listening to material you mostly understand, and speaking early, even badly. A weekly conversation with a tutor or partner keeps you honest."),
        Chat(hoursAgo: 410, title: "SQL: find duplicate emails",
             question: "How do I find duplicate emails in a users table?",
             answer: "`SELECT email, COUNT(*) FROM users GROUP BY email HAVING COUNT(*) > 1;` Add `lower(email)` in both places if case shouldn't matter."),
        Chat(hoursAgo: 520, title: "Ideas for a rainy Saturday",
             question: "Ideas for a rainy Saturday at home with two kids?",
             answer: "Build a blanket fort, bake something simple together, run an indoor treasure hunt with clues, or put on a play with costumes from the wardrobe. A board-game tournament with a homemade trophy works well too."),
        Chat(hoursAgo: 640, title: "How do vaccines work",
             question: "How do vaccines train the immune system?",
             answer: "They show the immune system a harmless piece or copy of a pathogen, so it builds antibodies and memory cells without the illness. If the real pathogen arrives later, the response is fast enough to stop it or make it much milder."),
        Chat(hoursAgo: 820, title: "Rename files in bulk on macOS",
             question: "How do I rename many files at once on a Mac?",
             answer: "Select them in Finder, right-click and choose Rename. You can replace text, add text, or format them with a name and a counter. For anything fancier, a short shell loop with `mv` does the job."),
        Chat(hoursAgo: 1_050, title: "Chess opening for beginners",
             question: "Which chess opening should a beginner learn first?",
             answer: "The Italian Game: 1.e4 e5 2.Nf3 Nc6 3.Bc4. It follows the basic principles, control the centre, develop pieces and castle early, without much theory to memorise."),
        Chat(hoursAgo: 1_400, title: "Difference between weather and climate",
             question: "What's the difference between weather and climate?",
             answer: "Weather is what the atmosphere does over hours and days. Climate is the long-run pattern of weather in a place, usually averaged over thirty years or more."),
        Chat(hoursAgo: 0.6, title: "Regex for a UK postcode",
             question: "What's a simple regex for a UK postcode?",
             answer: "`^[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}$`, matched case-insensitively. It accepts every real format, and a few strings that aren't real postcodes; check against the official list if that matters."),
        Chat(hoursAgo: 10, title: "Cold brew ratio",
             question: "What coffee-to-water ratio should I use for cold brew?",
             answer: "Start at 1:8 by weight, coarsely ground, steeped 14 to 18 hours in the fridge. That makes a concentrate; dilute it about one to one with water or milk to taste."),
        Chat(hoursAgo: 40, title: "Polite way to decline a meeting",
             question: "How do I politely decline a meeting I don't need to attend?",
             answer: "Keep it short and offer an alternative: \u{201C}Thanks for including me. I don't think I'm needed for this one, but I'm happy to read the notes and follow up on anything for me.\u{201D}"),
        Chat(hoursAgo: 64, title: "Why do onions make you cry",
             question: "Why do onions make you cry?",
             answer: "Cutting an onion breaks its cells, and an enzyme turns sulphur compounds into a gas, syn-propanethial-S-oxide. It reaches your eyes and irritates them, so they make tears to wash it away. A sharp knife and a cold onion both help."),
        Chat(hoursAgo: 90, title: "Python list vs tuple",
             question: "When should I use a tuple instead of a list in Python?",
             answer: "Use a tuple for a fixed group of values that belong together, like a coordinate or a database row, and a list for a collection that grows or changes. Tuples are immutable, so they can be dictionary keys."),
        Chat(hoursAgo: 180, title: "Train vs plane from Amsterdam to Paris",
             question: "Is the train or the plane better from Amsterdam to Paris?",
             answer: "Usually the train: about three and a half hours centre to centre, with no airport transfers or security queues. Door to door the plane is rarely faster, and the train emits far less."),
        Chat(hoursAgo: 290, title: "How compound interest works",
             question: "Explain compound interest with a simple example.",
             answer: "You earn interest on your interest. 1,000 at 5% a year becomes 1,050 after one year, then 1,102.50 after two, because the second year's 5% is on 1,050. After 14 years it has roughly doubled."),
        Chat(hoursAgo: 460, title: "Fixing a squeaky door hinge",
             question: "How do I stop a door hinge from squeaking?",
             answer: "Lift the hinge pin out, clean it, coat it lightly with petroleum jelly or a silicone lubricant, and tap it back in. Swing the door a few times to spread it. Avoid cooking oil, which goes sticky."),
        Chat(hoursAgo: 720, title: "Books like The Martian",
             question: "I loved The Martian. What should I read next?",
             answer: "Project Hail Mary by the same author is the obvious next one. Then try Seveneves by Neal Stephenson, The Expanse series starting with Leviathan Wakes, or Red Mars by Kim Stanley Robinson for slower, deeper science."),
        Chat(hoursAgo: 1_200, title: "What a VPN does",
             question: "What does a VPN actually do?",
             answer: "It encrypts your traffic to a server the VPN runs and sends it on from there. Your network provider sees only that you talk to the VPN, and websites see the VPN's address instead of yours. It does not make you anonymous to the VPN itself."),
    ]
}
