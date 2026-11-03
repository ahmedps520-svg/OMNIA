import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMNIA

/// Pictures drawn in code, encoded like files a user would attach.
enum TestImages {
    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        body(context)
        return try #require(context.makeImage())
    }

    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func solid(width: Int = 64, height: Int = 64, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let image = try draw(width: width, height: height) { context in
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try encode(image, as: .png)
    }
}

/// Minimal GGUF files: just the header keys OMNIA reads, no tensors.
enum FakeGGUF {
    enum Value {
        case string(String)
        case bool(Bool)
        case uint32(UInt32)
    }

    static func write(_ entries: [(String, Value)], to url: URL) throws {
        var data = Data("GGUF".utf8)
        data.append(littleEndian(UInt32(3)))
        data.append(littleEndian(UInt64(0)))
        data.append(littleEndian(UInt64(entries.count)))
        for (key, value) in entries {
            data.append(littleEndian(UInt64(key.utf8.count)))
            data.append(Data(key.utf8))
            switch value {
            case .string(let text):
                data.append(littleEndian(UInt32(8)))
                data.append(littleEndian(UInt64(text.utf8.count)))
                data.append(Data(text.utf8))
            case .bool(let flag):
                data.append(littleEndian(UInt32(7)))
                data.append(flag ? 1 : 0)
            case .uint32(let number):
                data.append(littleEndian(UInt32(4)))
                data.append(littleEndian(number))
            }
        }
        data.append(Data(count: 256))
        try data.write(to: url)
    }

    static func encoder(at url: URL) throws {
        try write([("general.architecture", .string("clip")), ("clip.has_vision_encoder", .bool(true))], to: url)
    }

    static func model(at url: URL) throws {
        try write([("general.architecture", .string("llama")), ("llama.block_count", .uint32(2)),
                   ("llama.context_length", .uint32(512)), ("llama.embedding_length", .uint32(64)),
                   ("llama.attention.head_count", .uint32(2))], to: url)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("omnia-images-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pixel(_ rgb: (width: Int, height: Int, pixels: [UInt8]), x: Int, y: Int) -> [Int] {
    let offset = (y * rgb.width + x) * 3
    return rgb.pixels[offset..<offset + 3].map(Int.init)
}

private func close(_ actual: [Int], _ expected: [Int], tolerance: Int = 8) -> Bool {
    zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
}

@Suite("Image input")
struct ImageInputTests {
    @Test func storesAnOpaqueJPEGWithTransparencyOnWhite() throws {
        let image = try TestImages.draw(width: 120, height: 80) { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 40, y: 20, width: 40, height: 40))
        }
        let prepared = try ImageInput.prepare(try TestImages.encode(image, as: .png))

        #expect(prepared.data.prefix(2) == Data([0xFF, 0xD8]))
        #expect(prepared.width == 120 && prepared.height == 80)
        let rgb = try ImageInput.rgbPixels(prepared.data)
        #expect(close(pixel(rgb, x: 5, y: 5), [255, 255, 255]), "transparent areas should become white")
        #expect(close(pixel(rgb, x: 60, y: 40), [255, 0, 0]))
    }

    @Test func turnsPhotosUprightFromTheirOrientation() throws {
        let image = try TestImages.draw(width: 400, height: 100) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        }
        // Orientation 6: the camera was turned, so the picture is shown rotated by 90°.
        let jpeg = try TestImages.encode(image, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let prepared = try ImageInput.prepare(jpeg)

        #expect(prepared.width == 100 && prepared.height == 400)
    }

    @Test func scalesLargeImagesDownButSmallOnesNotUp() throws {
        let large = try ImageInput.prepare(try TestImages.solid(width: 3000, height: 1500, red: 0, green: 1, blue: 0))
        #expect(large.width == ImageInput.maxPixelSize && large.height == ImageInput.maxPixelSize / 2)

        let small = try ImageInput.prepare(try TestImages.solid(width: 32, height: 24, red: 0, green: 1, blue: 0))
        #expect(small.width == 32 && small.height == 24)
    }

    @Test func pixelsArePackedRGBWithoutPadding() throws {
        let image = try TestImages.draw(width: 3, height: 2) { context in
            let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 1, 1)]
            for (index, color) in colors.enumerated() {
                context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
                // CoreGraphics' origin is bottom-left: row 0 of the bitmap is the top one.
                context.fill(CGRect(x: index % 3, y: 1 - index / 3, width: 1, height: 1))
            }
        }
        let rgb = try ImageInput.rgbPixels(try TestImages.encode(image, as: .png))

        #expect(rgb.width == 3 && rgb.height == 2)
        #expect(rgb.pixels.count == 3 * 2 * 3)
        #expect(close(pixel(rgb, x: 0, y: 0), [255, 0, 0], tolerance: 2))
        #expect(close(pixel(rgb, x: 2, y: 0), [0, 0, 255], tolerance: 2))
        #expect(close(pixel(rgb, x: 1, y: 1), [0, 255, 255], tolerance: 2))
    }

    @Test func identifiesImagesByContent() throws {
        let red = try TestImages.solid(red: 1, green: 0, blue: 0)
        let blue = try TestImages.solid(red: 0, green: 0, blue: 1)
        #expect(ImageInput.contentID(red) == ImageInput.contentID(red))
        #expect(ImageInput.contentID(red) != ImageInput.contentID(blue))
    }

    @Test func rejectsDataThatIsntAnImage() {
        #expect(throws: ImageInput.ImageError.self) {
            try ImageInput.prepare(Data("not a picture".utf8))
        }
    }
}

@Suite("Images in prompts")
struct ImagePromptTests {
    static let marker = "<__media__>"

    @Test func placesImagesBeforeTheirTurnsText() {
        let first = Data([1]), second = Data([2]), third = Data([3])
        var withImages = ChatTurn(role: .user, content: "Compare these.")
        withImages.images = [first, second]
        var onlyImage = ChatTurn(role: .user, content: "")
        onlyImage.images = [third]
        let prompt = ImagePrompt(turns: [ChatTurn(role: .system, content: "Be brief."), withImages,
                                         ChatTurn(role: .assistant, content: "Sure."), onlyImage], marker: Self.marker)

        #expect(prompt.images == [first, second, third])
        #expect(prompt.turns[0].content == "Be brief.")
        #expect(prompt.turns[1].content == ImagePrompt.placeholder(0) + "\n" + ImagePrompt.placeholder(1) + "\nCompare these.")
        #expect(prompt.turns[3].content == ImagePrompt.placeholder(2))
        #expect(prompt.turns.allSatisfy { $0.images.isEmpty })
    }

    @Test func resolvesOnlyTheImagesThePromptStillHolds() {
        var old = ChatTurn(role: .user, content: "Old")
        old.images = [Data([1])]
        var recent = ChatTurn(role: .user, content: "New")
        recent.images = [Data([2])]
        let prompt = ImagePrompt(turns: [old, recent], marker: Self.marker)
        // As if trimming had dropped the first turn.
        let formatted = "<s>user: \(prompt.turns[1].content)</s>"
        let resolved = prompt.resolve(formatted, marker: Self.marker)

        #expect(resolved.text == "<s>user: \(Self.marker)\nNew</s>")
        #expect(resolved.order == [1])
    }

    @Test func textCantPoseAsAnImage() {
        var turn = ChatTurn(role: .user, content: "What does \(Self.marker) mean? \u{F8F0}omnia-image-0\u{F8F1}")
        turn.images = [Data([1])]
        let prompt = ImagePrompt(turns: [turn], marker: Self.marker)
        let resolved = prompt.resolve(prompt.turns[0].content, marker: Self.marker)

        #expect(resolved.order == [0])
        #expect(resolved.text.components(separatedBy: Self.marker).count == 2, "only the real image becomes a marker")
    }

    @Test func leavesTextOnlyConversationsUntouched() {
        let turns = [ChatTurn(role: .user, content: "Tell me about \(Self.marker).")]
        let prompt = ImagePrompt(turns: turns, marker: Self.marker)
        #expect(prompt.isEmpty)
        #expect(prompt.turns == turns)
    }

    @Test func keepsTheNewestImagesAndNotesTheRest() {
        var turns: [ChatTurn] = []
        for index in 0..<3 {
            var turn = ChatTurn(role: .user, content: "Turn \(index)")
            turn.images = [Data([UInt8(index)]), Data([UInt8(index + 10)])]
            turns.append(turn)
            turns.append(ChatTurn(role: .assistant, content: "OK"))
        }
        ChatService.limitImages(&turns, supported: true, keep: 3)

        #expect(turns[4].images.count == 2)
        #expect(turns[2].images == [Data([1])])
        #expect(turns[2].content == "[An image shown here was left out to save memory.]\n\nTurn 1")
        #expect(turns[0].images.isEmpty)
        #expect(turns[0].content.hasPrefix("[2 images shown here were left out"))
    }

    @Test func modelsWithoutImageSupportAreToldAboutImages() {
        var turn = ChatTurn(role: .user, content: "")
        turn.images = [Data([1])]
        var turns = [turn]
        ChatService.limitImages(&turns, supported: false, keep: 4)

        #expect(turns[0].images.isEmpty)
        #expect(turns[0].content == "[The user attached an image, but this model can't view images.]")
    }

    @Test func imageBudgetFollowsTheContext() {
        #expect(ChatService.imageLimit(contextTokens: 2048) == 1)
        #expect(ChatService.imageLimit(contextTokens: 4096) == 2)
        #expect(ChatService.imageLimit(contextTokens: 8192) == 4)
        #expect(ChatService.imageLimit(contextTokens: 131_072) == 4)
    }

    @Test func templatesThatReadTypedContentGetIt() throws {
        let typed = try ChatTemplateRenderer(
            source: "{% for message in messages %}{{ message['role'] }}: {% for part in message['content'] %}{% if part['type'] == 'text' %}{{ part['text'] }}{% endif %}{% endfor %};{% endfor %}",
            bosToken: "", eosToken: "")
        #expect(typed.requiresTypedContent)
        #expect(try typed.render([ChatTurn(role: .user, content: "Hello")], addGenerationPrompt: false, variables: [:]) == "user: Hello;")

        let plain = try ChatTemplateRenderer(source: "{% for message in messages %}{{ message['content'] }}{% endfor %}",
                                             bosToken: "", eosToken: "")
        #expect(!plain.requiresTypedContent)
    }
}

@Suite("Image encoders", .serialized)
@MainActor
struct ImageEncoderStoreTests {
    /// A store with two copies (quantizations) of one catalog model, and a text-only model.
    private func makeStore(in directory: URL) throws -> ModelStore {
        let store = ModelStore(directory: directory.appendingPathComponent("Models", isDirectory: true))
        for (id, catalogID) in [("a/q4.gguf", "vision"), ("a/q8.gguf", "vision"), ("b/text.gguf", "text")] {
            let file = directory.appendingPathComponent(UUID().uuidString + ".gguf")
            try FakeGGUF.model(at: file)
            let info = try GGUFInspector.inspect(fileAt: file).info
            try store.install(fileAt: file, id: id, displayName: id, developer: nil, repo: "test",
                              fileName: (id as NSString).lastPathComponent + "-\(catalogID)", sha256: nil,
                              verification: .structureValid, info: info, license: nil, origin: .catalog,
                              catalogID: catalogID, moveFile: true)
        }
        return store
    }

    private func makeEncoder(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("mmproj-\(UUID().uuidString).gguf")
        try FakeGGUF.encoder(at: url)
        return url
    }

    @Test func recognisesEncoderFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = try makeEncoder(in: directory)
        let model = directory.appendingPathComponent("model.gguf")
        try FakeGGUF.model(at: model)

        #expect(GGUFInspector.isImageEncoder(fileAt: encoder))
        #expect(!GGUFInspector.isImageEncoder(fileAt: model))
        #expect(try GGUFInspector.inspect(fileAt: encoder).info.isEncoder)
    }

    @Test func installsForEveryCopyOfTheModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let updated = try store.installProjector(fileAt: try makeEncoder(in: directory), for: "a/q4.gguf", repo: "org/vision",
                                                 fileName: "mmproj.gguf", sha256: "abc", verification: .verified, moveFile: true)

        #expect(Set(updated.map(\.id)) == ["a/q4.gguf", "a/q8.gguf"])
        #expect(store.model(id: "b/text.gguf")?.supportsImages == false)
        let projector = try #require(store.model(id: "a/q8.gguf")?.projector)
        #expect(projector.relativePath == ModelStore.projectorStorageName(repo: "org/vision", fileName: "mmproj.gguf"))
        #expect(projector.verification == .verified)
        let owner = try #require(store.model(id: "a/q4.gguf"))
        let url = try #require(store.projectorURL(for: owner))
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(store.isProjectorInstalled(repo: "org/vision", fileName: "mmproj.gguf"))
    }

    @Test func deletesTheEncoderOnlyWhenNoModelUsesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        try store.installProjector(fileAt: try makeEncoder(in: directory), for: "a/q4.gguf", repo: "org/vision",
                                   fileName: "mmproj.gguf", sha256: nil, verification: .structureValid, moveFile: true)
        let owner = try #require(store.model(id: "a/q4.gguf"))
        let url = try #require(store.projectorURL(for: owner))

        await store.removeProjector(from: "a/q4.gguf")
        #expect(store.model(id: "a/q4.gguf")?.projector == nil)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "a/q8 still uses it")

        await store.delete(try #require(store.model(id: "a/q8.gguf")))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func reconcileNeverTreatsEncodersAsModels() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        try store.installProjector(fileAt: try makeEncoder(in: directory), for: "a/q4.gguf", repo: "org/vision",
                                   fileName: "mmproj.gguf", sha256: nil, verification: .structureValid, moveFile: true)
        let stray = store.modelsDirectory.appendingPathComponent("mmproj-leftover.gguf")
        try FakeGGUF.encoder(at: stray)

        store.reconcile()
        #expect(store.models.count == 3)
        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
        #expect(store.model(id: "a/q4.gguf")?.supportsImages == true)

        // An encoder file that went missing turns image support off instead of failing later.
        let owner = try #require(store.model(id: "a/q4.gguf"))
        let url = try #require(store.projectorURL(for: owner))
        try FileManager.default.removeItem(at: url)
        store.reconcile()
        #expect(store.model(id: "a/q4.gguf")?.projector == nil)
    }

    @Test func importingAnEncoderAsAModelIsRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelStore(directory: directory.appendingPathComponent("Models", isDirectory: true))
        let importer = ModelImporter(store: store)
        await importer.importFile(at: try makeEncoder(in: directory))

        guard case .failed(let message) = importer.phase else {
            Issue.record("Expected the import to fail, got \(importer.phase)")
            return
        }
        #expect(message.contains("image encoder"))
        #expect(store.models.isEmpty)
    }

    @Test func importsAnEncoderForAModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try makeStore(in: directory)
        let importer = ModelImporter(store: store)
        await importer.importProjector(at: try makeEncoder(in: directory), for: try #require(store.model(id: "b/text.gguf")))

        #expect(store.model(id: "b/text.gguf")?.projector?.verification == .structureValid)
        #expect(store.model(id: "b/text.gguf")?.projector?.repo == nil)
        if case .imported = importer.phase {} else { Issue.record("Expected success, got \(importer.phase)") }
    }
}

@Suite("Chat with images", .serialized, .enabled(if: TestModels.available("stories260K.gguf")))
@MainActor
struct ChatImageTests {
    private func attach(_ data: Data) -> (AttachmentRecord, [UUID: Data]) {
        let record = AttachmentRecord(name: "Photo", kind: .image, byteSize: data.count, text: "")
        return (record, [record.id: data])
    }

    @Test func modelsWithImageSupportGetTheImages() async throws {
        let harness = try ChatHarness(replies: ["A red square."])
        let encoder = FileManager.default.temporaryDirectory.appendingPathComponent("mmproj-\(UUID().uuidString).gguf")
        try FakeGGUF.encoder(at: encoder)
        try harness.store.installProjector(fileAt: encoder, for: harness.model.id, repo: nil, fileName: "mmproj.gguf",
                                           sha256: nil, verification: .structureValid, moveFile: true)
        let image = try ImageInput.prepare(try TestImages.solid(red: 1, green: 0, blue: 0)).data
        let (record, images) = attach(image)
        let conversation = try await harness.send("What is this?", attachments: [record], images: images)

        let turn = try #require(harness.backend.requests.last?.turns.last)
        #expect(turn.role == .user)
        #expect(turn.content == "What is this?")
        #expect(turn.images == [image])
        let stored = try #require(conversation.orderedMessages.first)
        #expect(stored.orderedImages.map(\.data) == [image])
        #expect(stored.attachments.map(\.kind) == [.image])
    }

    @Test func modelsWithoutImageSupportAreToldInstead() async throws {
        let harness = try ChatHarness(replies: ["I can't see it."])
        let image = try ImageInput.prepare(try TestImages.solid(red: 0, green: 0, blue: 1)).data
        let (record, images) = attach(image)
        _ = try await harness.send("What is this?", attachments: [record], images: images)

        let turn = try #require(harness.backend.requests.last?.turns.last)
        #expect(turn.images.isEmpty)
        #expect(turn.content == "[The user attached an image, but this model can't view images.]\n\nWhat is this?")
    }
}
