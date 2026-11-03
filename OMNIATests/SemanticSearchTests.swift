import Foundation
import SwiftData
import Testing
@testable import OMNIA

@Suite("Search by meaning")
struct HybridSearchTests {
    private func chunks(_ texts: [String]) -> [DocumentChunk] {
        texts.enumerated().map { DocumentChunk(documentTitle: "Notes", index: $0.offset, text: $0.element) }
    }

    @Test func meaningFindsAPassageWithoutSharedWords() {
        let passages = chunks(["Quarterly revenue grew five percent.", "The kitten slept on the rug all afternoon."])
        let byMeaning = Retrieval.search("feline resting", in: passages, similarities: [0.1, 0.9], limit: 1, characterBudget: 1_000)
        #expect(byMeaning.map(\.index) == [1])
        // Keywords alone have nothing to go on and fall back to the first passage.
        let byKeywords = Retrieval.search("feline resting", in: passages, limit: 1, characterBudget: 1_000)
        #expect(byKeywords.map(\.index) == [0])
    }

    @Test func fusionFavoursWhatBothRankingsAgreeOn() {
        let passages = chunks(["Solar panels: solar panels lose efficiency in heat.", "Solar power storage at home.",
                               "Kitchen recipes for winter."])
        // Keywords rank passage 0 then 1; meaning ranks 1, then 2, then 0. Passage 1 is near the top of both.
        let found = Retrieval.search("solar panels", in: passages, similarities: [0.2, 0.8, 0.5], limit: 1, characterBudget: 1_000)
        #expect(found.map(\.index) == [1])
    }

    @Test func similaritiesOfTheWrongLengthAreIgnored() {
        let passages = chunks(["The rocket engine was stored in a vault.", "Bananas are yellow."])
        let found = Retrieval.search("rocket vault", in: passages, similarities: [0.9], limit: 1, characterBudget: 1_000)
        #expect(found.map(\.index) == [0])
    }

    @Test func vectorsSurviveHalfPrecisionStorage() {
        let vectors: [[Float]] = [[0.5, -0.25, 0.125, 0.8], [0.0, 1.0, -1.0, 0.333]]
        let restored = EmbeddingVectors.unpack(EmbeddingVectors.pack(vectors), count: 2)
        #expect(restored.count == 2)
        for (original, copy) in zip(vectors, restored) {
            #expect(zip(original, copy).allSatisfy { abs($0 - $1) < 1e-3 })
        }
        #expect(EmbeddingVectors.unpack(EmbeddingVectors.pack(vectors), count: 3).isEmpty)
    }

    @Test func passagesWithoutVectorsRankLastByMeaning() {
        let indexed = IndexedChunks(chunks: chunks(["a", "b"]), vectors: [[1, 0], nil])
        #expect(indexed.hasVectors)
        #expect(indexed.similarities(to: [1, 0]) == [1, -1])
        #expect(!IndexedChunks(chunks: chunks(["a"])).hasVectors)
    }
}

@Suite("Embeddings", .serialized, .timeLimit(.minutes(10)), .enabled(if: TestModels.available("bge-small-f16.gguf")))
struct EmbeddingRuntimeTests {
    private func load() async throws -> EmbeddingRuntime {
        try await EmbeddingRuntime.load(fileURL: try #require(TestModels.url("bge-small-f16.gguf")), contextLength: 512, threads: 2)
    }

    @Test func closenessFollowsMeaning() async throws {
        let runtime = try await load()
        let vectors = try await runtime.embed(["A cat is sleeping on the sofa.", "A kitten naps on the couch.",
                                               "The company's quarterly revenue increased."])
        await runtime.close()

        #expect(vectors.count == 3)
        #expect(vectors.allSatisfy { $0.count == runtime.dimensions && runtime.dimensions == 384 })
        for vector in vectors {
            #expect(abs(EmbeddingVectors.dot(vector, vector) - 1) < 1e-3, "vectors are normalized")
        }
        #expect(EmbeddingVectors.dot(vectors[0], vectors[1]) > EmbeddingVectors.dot(vectors[0], vectors[2]))
    }

    @Test func batchingDoesntChangeTheVectors() async throws {
        let runtime = try await load()
        let texts = ["Rivers flow to the sea.", "Mountains are tall.", "Bread is baked in an oven."]
        let together = try await runtime.embed(texts)
        var alone: [[Float]] = []
        for text in texts { alone += try await runtime.embed([text]) }
        await runtime.close()

        for (a, b) in zip(together, alone) {
            #expect(EmbeddingVectors.dot(a, b) > 0.999)
        }
    }

    @Test func cutsTextsLongerThanTheContext() async throws {
        let runtime = try await load()
        let long = String(repeating: "Every sentence here is about the same long story. ", count: 400)
        let vectors = try await runtime.embed([long, "short"])
        await runtime.close()
        #expect(vectors.count == 2)
        #expect(vectors[0].count == runtime.dimensions)
    }
}

@Suite("Library index", .serialized, .timeLimit(.minutes(10)), .enabled(if: TestModels.available("bge-small-f16.gguf")))
@MainActor
struct SemanticIndexTests {
    @Test func indexesTheLibraryAndFindsPassagesByMeaning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omnia-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: Schema(PersistenceSchema.models),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let pets = KnowledgeDocument(title: "Pets", fileName: "pets.txt", kind: .text,
                                     text: "Our cat spends the afternoon asleep on the living room rug.", byteSize: 60)
        let money = KnowledgeDocument(title: "Report", fileName: "report.txt", kind: .text,
                                      text: "Quarterly revenue rose by five percent, driven by exports.", byteSize: 60)
        context.insert(pets)
        context.insert(money)
        try context.save()

        let index = SemanticIndex(container: container, directory: directory)
        let source = try #require(TestModels.url("bge-small-f16.gguf"))
        let embedder = SemanticIndex.Embedder(id: "bge-small", name: "BGE small", fileName: "bge-small-f16.gguf", sizeBytes: 1,
                                              sha256: nil, queryPrefix: "", documentPrefix: "", contextLength: 512)
        try index.install(fileAt: source, embedder: embedder, moveFile: false)
        await index.waitForIndexing()

        #expect(pets.embeddingModelID == "bge-small" && money.embeddingModelID == "bge-small")
        #expect(pets.embeddingCount == 1)
        let indexed = index.chunks(of: [money, pets])
        #expect(indexed.chunks.count == 2 && indexed.vectors.allSatisfy { $0 != nil })

        let vector = try #require(await index.queryVector("a feline napping on the carpet"))
        let found = Retrieval.search("feline napping carpet", in: indexed.chunks, similarities: indexed.similarities(to: vector),
                                     limit: 1, characterBudget: 1_000)
        #expect(found.first?.documentTitle == "Pets")

        await index.remove()
        #expect(index.embedder == nil)
        #expect(pets.embeddingsData == nil && pets.embeddingModelID == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bge-small-f16.gguf").path(percentEncoded: false)))
    }
}
