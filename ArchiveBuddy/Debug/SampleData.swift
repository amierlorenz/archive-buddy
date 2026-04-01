#if DEBUG
import Foundation
import SVDB

/// Seeds the database with sample archives and pages for development testing.
/// This entire file is excluded from Release builds at compile time.
///
/// To force a reseed: bump `currentVersion`. On next launch the old archives
/// are wiped and fresh data is inserted.
enum SampleData {

    // Bump this when you change the seed content. The seeder compares this
    // against the stored UserDefaults value and wipes+reseeds if they differ.
    static let currentVersion = 1
    private static let userDefaultsKey = "sampleDataVersion"

    static func seedIfNeeded(db: DatabaseManager) async {
        let storedVersion = UserDefaults.standard.integer(forKey: userDefaultsKey)
        let needsSeed: Bool

        if storedVersion != currentVersion {
            // Version mismatch — wipe existing sample archives and reseed
            wipeExistingArchives(db: db)
            needsSeed = true
        } else {
            // Same version — only seed if the DB is empty
            needsSeed = (try? db.fetchAllArchives())?.isEmpty == true
        }

        guard needsSeed else { return }

        await insertSampleData(db: db)
        UserDefaults.standard.set(currentVersion, forKey: userDefaultsKey)
    }

    // MARK: - Wipe

    private static func wipeExistingArchives(db: DatabaseManager) {
        let archives = (try? db.fetchAllArchives()) ?? []
        for archive in archives {
            SVDB.shared.getCollection(archive.svdbCollectionName)?.clear()
            SVDB.shared.releaseCollection(archive.svdbCollectionName)
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let file = dir.appendingPathComponent("SVDB/\(archive.svdbCollectionName).json")
                try? FileManager.default.removeItem(at: file)
            }
            try? db.deleteArchive(id: archive.id)
        }
    }

    // MARK: - Insert

    private static func insertSampleData(db: DatabaseManager) async {
        for spec in archiveSpecs {
            let archive = Archive(
                id: spec.id,
                title: spec.title,
                description: spec.description,
                createdAt: spec.createdAt
            )
            guard (try? db.insertArchive(archive)) != nil else { continue }

            let rag = RAGModel(collectionName: archive.svdbCollectionName)
            await rag.loadCollection()

            for pageDraft in spec.pages {
                guard let page = try? db.insertPage(
                    PageDraft(
                        archiveId: archive.id,
                        userDefinedDate: pageDraft.date,
                        finalText: pageDraft.text
                    )
                ) else { continue }

                let chunks = DocumentProcessor.chunkText(page.finalText)
                for (index, chunkText) in chunks.enumerated() {
                    let metadata = ChunkMetadata(
                        pageId: page.id,
                        archiveId: archive.id,
                        archiveTitle: archive.title,
                        pageNumber: page.pageNumber,
                        userDefinedDate: page.userDefinedDate
                    )
                    await rag.addEntry(chunkText: chunkText, metadata: metadata)
                    if let chunkId = try? db.insertPageChunk(
                        pageId: page.id,
                        archiveId: archive.id,
                        chunkText: chunkText,
                        chunkIndex: index
                    ) {
                        try? db.markChunkAsEmbedded(chunkId)
                    }
                }
                try? db.markPageAsEmbedded(page.id)
            }
        }
    }

    // MARK: - Spec types

    private struct ArchiveSpec {
        let id: UUID
        let title: String
        let description: String?
        let createdAt: Date
        let pages: [PageSpec]
    }

    private struct PageSpec {
        let date: Date
        let text: String
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return Calendar.current.date(from: c) ?? Date()
    }

    // MARK: - Sample content

    // Each page is 300–500 words to ensure 2+ chunks per page and exercise
    // multi-chunk retrieval in the RAG pipeline.

    private static let archiveSpecs: [ArchiveSpec] = [

        // ARCHIVE 1 — Travel journal
        ArchiveSpec(
            id: UUID(uuidString: "A1A1A1A1-0000-0000-0000-000000000001")!,
            title: "Italy Trip — June 2023",
            description: "Two weeks travelling Rome, Florence, and the Amalfi Coast.",
            createdAt: date(2023, 6, 1),
            pages: [
                PageSpec(date: date(2023, 6, 3), text: """
                    Arrived in Rome yesterday evening after a brutal connection through Zurich. The apartment is on a narrow street in Trastevere — ancient cobblestones outside the window, laundry strung between balconies, a cat asleep on a Vespa. Exactly what I hoped for.

                    This morning we walked to the Pantheon before the crowds arrived. Got there at eight and had maybe twenty minutes of near-solitude inside. The oculus was filled with flat grey light from an overcast sky, which made the whole space feel even more solemn than I expected. I have seen photographs of the Pantheon hundreds of times but nothing prepared me for the scale of the dome or the sense that the building is completely indifferent to the two thousand years that have passed around it. It has simply been standing here, watching empires rise and collapse.

                    In the afternoon we visited the Borghese Gallery — you have to book tickets weeks in advance and they only let you in for two hours, which is actually a perfect constraint. It forces you to slow down rather than shuffling through room after room until everything blurs together. The Bernini sculptures stopped me cold. The Apollo and Daphne piece in particular — the moment of transformation captured in marble, her fingers already becoming laurel leaves, his hand pressing into bark that was a second ago warm skin. I stood in front of it for probably fifteen minutes and still felt I had not seen it properly.

                    Dinner at a place with no English menu and only six tables. We pointed at things and ended up with cacio e pepe and a carafe of house white that cost four euros. Both were perfect. I am already dreading going back to cooking for myself.

                    Notes for next time: book Borghese first thing — it sells out months ahead. The tourist areas around the Colosseum are exhausting and the food is terrible. Walk fifteen minutes in any direction and everything improves dramatically.
                    """),
                PageSpec(date: date(2023, 6, 7), text: """
                    Florence after four days in Rome feels quieter and more manageable, though I am not sure that is actually true — it is just smaller. We are staying near Santa Croce, which puts us close to the leather market and a twenty-minute walk from the Uffizi.

                    Spent the morning at the Accademia to see the David. I expected to be underwhelmed — another overhyped tourist monument — but was not. What strikes you first is not the face or the famous proportions but the hands, which are enormous and oddly tense, knuckles prominent, fingers curled slightly. Michelangelo apparently made them large deliberately to be visible from a distance, but close up they read as nervous energy coiled before action. The boy is terrified and absolutely still at the same time. That contradiction is what makes the piece work.

                    In the afternoon we crossed the Arno to the Oltrarno neighborhood, which felt more like a place where people actually live. Visited the Brancacci Chapel — small, dark, and almost entirely covered in Masaccio frescoes that somehow survived five hundred years and a fire. The Expulsion of Adam and Eve stopped me: both figures bent double with shame, Eve covering her face, Adam covering his eyes, neither able to look at the world they are being cast into. It is not grand or heroic. It just looks like grief.

                    Had aperitivo at a bar near the Ponte Vecchio — Aperol spritz and little plates of olives and bread — and watched the light go gold on the hills across the river. This is the hour the city is most beautiful. Everything softens.

                    Tomorrow: the hill towns. We rented a car, which was a mistake I am already anticipating but cannot avoid.
                    """),
                PageSpec(date: date(2023, 6, 12), text: """
                    The Amalfi Coast is one of the most beautiful places I have ever been and also one of the most stressful to drive through. The road is a single lane cut into cliffs above a vertical drop to the sea, and buses come at you from both directions around blind corners. By the time we reached Ravello I needed a drink.

                    Ravello sits above the coast on a ridge and you reach it by a series of switchbacks that feel genuinely dangerous even by Amalfi standards. The reward is gardens and silence and a view across the water that seems to go on forever. We visited Villa Cimbrone in the afternoon, which has a terrace at the edge of the ridge called the Terrace of Infinity. The name is not an exaggeration. You stand at the balustrade and the sea stretches away to the horizon without interruption. Gore Vidal lived up here for thirty years, which suddenly seemed like a completely reasonable life decision.

                    Walked down to the village of Atrani, which is tucked into a fold in the cliffs and is so small you can see the whole thing from a single spot. A piazza the size of a tennis court, a church, a few restaurants with tables outside. We ate grilled fish and pasta with bottarga and drank local white wine that cost nothing and tasted of the sea. The man at the next table was feeding scraps to a dog who had the look of someone who had been eating well off tourists for years.

                    The water here is a colour I have no good word for — somewhere between turquoise and green, deep and very clear. I swam off a small beach below the road in the late afternoon when the worst of the heat had gone. The water was cold despite the air temperature. Coming out felt like waking up.

                    This was the last full day. Flying home tomorrow morning from Naples. Already composing excuses to come back.
                    """)
            ]
        ),

        // ARCHIVE 2 — Book notes
        ArchiveSpec(
            id: UUID(uuidString: "A2A2A2A2-0000-0000-0000-000000000002")!,
            title: "Book Notes — Thinking, Fast and Slow",
            description: "Reading notes from Daniel Kahneman's book on cognition and decision-making.",
            createdAt: date(2024, 1, 10),
            pages: [
                PageSpec(date: date(2024, 1, 12), text: """
                    Kahneman opens by introducing the two-system model that organises the entire book. System 1 is fast, automatic, associative, and largely unconscious — it is what fires when you recognise a face, feel disgust, or understand the sentence "two plus two." System 2 is slow, effortful, deliberate, and capacity-limited — it engages when you multiply 23 by 17, park in a tight space, or try to stay awake during a dull meeting.

                    The key insight, which Kahneman hammers throughout the early chapters, is that System 1 is not a fallback or a degraded form of System 2. It is the primary mode of cognition. System 2 believes it is running the show, but mostly it is just endorsing whatever System 1 has already decided. This is useful — efficient, even — because most of life can be navigated by pattern recognition without deliberate reasoning. But it is also the source of a long list of systematic errors.

                    The anchoring effect is one of the earliest examples he develops. If you ask people to spin a wheel that stops on a number and then ask them to estimate the percentage of African countries in the UN, their estimates are skewed toward whatever number the wheel showed, even when they know the wheel is random. The mind latches onto the number it was given and adjusts insufficiently from there. This happens in salary negotiations, price estimates, legal sentencing — anywhere a number is mentioned first and a judgment follows.

                    There is also the affect heuristic: we tend to make judgments about risk and benefit based on how we feel about something rather than careful calculation. People who like nuclear energy think it is both safer and more beneficial than people who dislike it. The preference comes first. The risk assessment follows and is shaped by the preference. Kahneman notes that this is not stupidity — it is cognitive efficiency gone wrong in situations that demand real deliberation.

                    What I find most useful so far is not any specific bias but the meta-point: that knowing about cognitive biases does not make you immune to them. Kahneman is explicit that he himself is subject to all the effects he describes, and that awareness rarely produces protection in the moment. The corrective is not vigilance but process — checklists, pre-mortems, deliberate procedures that force System 2 to engage before the decision is made.
                    """),
                PageSpec(date: date(2024, 1, 18), text: """
                    Chapters on prospect theory today. This is Kahneman and Tversky's central contribution to economics — the work that eventually won Kahneman the Nobel Prize — and it is genuinely elegant once you grasp the core insight.

                    Standard economic theory assumes people evaluate outcomes in terms of absolute levels of wealth or utility. Prospect theory says no: people evaluate outcomes relative to a reference point, and the function is not linear — losses loom larger than equivalent gains. Losing one hundred dollars feels roughly twice as painful as gaining one hundred dollars feels good. This asymmetry, which Kahneman calls loss aversion, is remarkably consistent across populations and contexts.

                    The implications ramble well beyond individual psychology. Loss aversion helps explain why people hold losing stocks too long — selling feels like locking in a loss, while holding open keeps the reference point ambiguous. It explains why negotiators make concessions reluctantly even when the concession costs them nothing in absolute terms. It explains the endowment effect: once you own something, you value it more than you would to acquire it, simply because parting with it is framed as a loss.

                    There is also an important asymmetry in how people respond to probabilities near the extremes. We overweight small probabilities, which is why lotteries and insurance both work — people pay above expected value to win an unlikely prize or avoid an unlikely catastrophe. We underweight moderate-to-high probabilities, which creates the preference reversal: the same person who buys lottery tickets will also sell insurance-like sure gains for gambles that look almost as certain. The probability weighting function is S-shaped and crosses certainty equivalence at different points than a simple expected-value calculation would predict.

                    What I keep coming back to: these are not occasional glitches. They are features of how the mind processes risk and reward, baked in deeply enough that awareness does not reliably correct them. The honest takeaway is not a set of rules to be smarter, but humility about the conditions under which your judgment can be trusted.
                    """)
            ]
        ),

        // ARCHIVE 3 — Personal diary
        ArchiveSpec(
            id: UUID(uuidString: "A3A3A3A3-0000-0000-0000-000000000003")!,
            title: "Personal Diary — Spring 2024",
            description: "Day-to-day personal writing from March through May 2024.",
            createdAt: date(2024, 3, 1),
            pages: [
                PageSpec(date: date(2024, 3, 14), text: """
                    Ran six miles this morning, first time over five since the knee problem in January. It held. The path along the river was empty at seven and the light was that particular pale yellow that belongs only to early spring mornings, before the air has had time to warm up. I forget every year how good it feels to move. Three months off and I had convinced myself I did not miss it.

                    Had coffee with Marcus in the afternoon. We talked for three hours in a way that only happens once or twice a year — the kind of conversation where you say things you did not know you thought until you heard yourself saying them. He is going through something with his work that I recognised from two years ago when I was grinding through the same wall. Told him what helped then, which was mostly that it passed, which is not useful advice but is honest.

                    The thing I keep thinking about: how much of what feels like personality is actually just accumulated habit, and how hard it is to distinguish between the two from the inside. I am trying to spend less time in the evenings doing nothing in particular in front of a screen and more time reading or writing or sitting with the discomfort of an unoccupied mind. It is much harder than I expected. The pull of frictionless passive consumption is not a moral failure, I think, but a genuine design problem — the path of least resistance has been professionally engineered to be exactly frictionless.

                    Started the new Ishiguro tonight. Fifty pages in. Already the familiar quality of his prose: everything is stated gently and once, which means you have to read slowly or you will miss what the book is actually doing. His narrators never say directly what they feel, which would be too easy. They say something adjacent to it and trust the reader to close the gap.

                    Tomorrow: dentist, which I have been rescheduling since November. Also need to finish the section on pricing before the Thursday call.
                    """),
                PageSpec(date: date(2024, 4, 2), text: """
                    Easter weekend. Went to my parents' house for three days, which is always a mixture of warmth and mild strangeness — the sensation of sliding back into an older version of yourself that does not quite fit anymore, like a coat you last wore at twenty-two.

                    My father is eighty-one and slowing down in ways that are hard to watch if you are paying attention. Not dramatically, just the accumulation of small things: he gets up more carefully from chairs, loses the thread of a story and retraces it, falls asleep after lunch. He was always a man of tremendous physical energy and it seems to confuse him that this is no longer straightforwardly true. We did not talk about it. I am not sure what there is to say.

                    My mother made lamb, which she has made at Easter for as long as I can remember. I have eaten that meal in this house probably thirty-five times, and it still tastes like something specific and unrepeatable. I wonder sometimes whether what makes food taste like memory is some objective quality of the cooking or purely the accumulation of associations — whether it would taste the same to someone who had never eaten it before.

                    My sister brought her two children, four and six. Watching them is its own kind of instruction. The six-year-old has developed a consuming interest in how everything works — engines, rain, digestion, where thoughts come from. He asks questions without embarrassment, in the expectation that adults know the answers and will share them willingly. I tried to explain how rain forms and got about halfway through before realising I did not actually know the full mechanism, only the broad outline.

                    The drive back on Monday evening took three hours in Easter traffic. Listened to a long documentary about the Voyager probes, which are now so far from Earth that a radio signal takes over twenty-two hours to reach them. Still transmitting. I found this unexpectedly moving.
                    """)
            ]
        )
    ]
}
#endif
