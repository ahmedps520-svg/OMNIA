import SwiftData
import SwiftUI

struct HomeView: View {
    @Binding var selection: SidebarSelection?

    @Environment(AppSettings.self) private var settings
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(ChatService.self) private var chat

    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var loadError: String?

    private let device = AppServices.shared.device

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                hero
                VStack(spacing: 16) {
                    activeModelCard
                    if !conversations.isEmpty { recentSection }
                    if !store.models.isEmpty { modelsSection }
                    deviceFooter
                }
                .frame(maxWidth: 760)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            OmniaMark(size: 92, animated: settings.animations == .full)
            VStack(spacing: 8) {
                OmniaWordmark(size: 30)
                Text("Every model. One mind.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    selection = .section(.chat)
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                if store.models.isEmpty {
                    Button("Find a Model") { selection = .section(.models) }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            }
            .padding(.top, 6)
        }
        .padding(.top, 12)
    }

    // MARK: Active model

    private var activeModelCard: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 44, height: 44)
                Image(systemName: "cpu").foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let loaded = engine.loadedModels.first {
                    Text(loaded.info.displayName).font(.headline)
                    Text("\(ByteFormat.tokens(loaded.info.configuration.contextLength)) context · \(loaded.info.configuration.kvCacheType.label) cache · \(ByteFormat.memory(loaded.plan.estimate.total)) planned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let id = engine.loadingModelID {
                    Text("Loading \(store.model(id: id)?.displayName ?? "model")…").font(.headline)
                    ProgressView(value: engine.loadProgress).frame(maxWidth: 220)
                } else if let model = chat.defaultModel {
                    Text(model.displayName).font(.headline)
                    Text("Ready on device · loads when you start chatting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No model downloaded").font(.headline)
                    Text("OMNIA recommends models that fit \(device.name) safely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(Theme.critical)
                }
            }
            Spacer(minLength: 12)
            if engine.loadedModels.isEmpty, engine.loadingModelID == nil, let model = chat.defaultModel {
                Button("Load") {
                    Task {
                        do {
                            loadError = nil
                            try await engine.ensureLoaded(model)
                        } catch {
                            loadError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.glass)
            } else if store.models.isEmpty {
                Button("Browse") { selection = .section(.models) }
                    .buttonStyle(.glass)
            }
        }
        .surface()
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Recent Conversations") {
                Button("Library") { selection = .section(.library) }
                    .font(.footnote)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(conversations.prefix(4)) { conversation in
                    Button {
                        selection = .conversation(conversation.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(conversation.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(conversation.preview.isEmpty ? "No messages yet" : conversation.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2, reservesSpace: true)
                            Text(conversation.updatedAt.relativeDescription)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface(padding: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 12)
    }

    // MARK: Models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("On This Device", subtitle: "\(store.models.count) \(store.models.count == 1 ? "model" : "models") · \(ByteFormat.file(store.storageUsed))") {
                Button("Manage") { selection = .section(.models) }
                    .font(.footnote)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.sortedByRecentUse.prefix(5).enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    HStack(spacing: 12) {
                        StatusDot(color: engine.isLoaded(model.id) ? Theme.positive : Color.secondary.opacity(0.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).font(.subheadline)
                            Text(model.isSystem ? "Built into iOS"
                                 : "\(model.parameterLabel) · \(model.quantization ?? "GGUF") · \(ByteFormat.file(model.sizeBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(engine.isLoaded(model.id) ? "Loaded" : "Ready offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                }
            }
            .surface(padding: 14)
        }
        .padding(.top, 12)
    }

    // MARK: Device

    private var deviceFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isPad ? "ipad" : "iphone")
            Text("\(device.name) · \(device.chip) · \(device.configurationSummary)")
                .lineLimit(2)
            Spacer(minLength: 8)
            Label(connectivity.isOnline ? "Online" : "Offline", systemImage: connectivity.isOnline ? "wifi" : "wifi.slash")
                .labelStyle(.titleAndIcon)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 16)
        .padding(.horizontal, 4)
    }
}
