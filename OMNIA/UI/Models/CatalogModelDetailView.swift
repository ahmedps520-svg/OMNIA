import SwiftUI

/// A catalog model: what it is, every quantization, and exactly how much memory it needs here.
struct CatalogModelDetailView: View {
    let model: CatalogModel

    @Environment(InferenceEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    @State private var selectedVariantID: String?
    @State private var contextLength: Double = 8192
    @State private var kvChoice: KVCacheChoice = .automatic
    @State private var errorMessage: String?
    /// Every version's assessment (and cluster plan) stays until the planning inputs change: the
    /// context slider below redraws this screen with every step it moves.
    @State private var fits = Memo<PlanningInputs, [String: VariantFit]>()

    private let device = AppServices.shared.device

    private struct VariantFit {
        let assessment: VariantAssessment
        /// Too big here, but the cluster this device hosts can run it.
        let onCluster: Bool
    }

    var body: some View {
        let inputs = PlanningInputs(engine: engine, settings: settings)
        let budget = inputs.budget
        let profile = engine.profile
        let variantFits = fits.value(for: inputs) { assessVariants(budget: budget, profile: profile) }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                factsGrid
                variantsSection(variantFits)
                memorySection(budget: budget, profile: profile)
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedVariantID == nil {
                selectedVariantID = ModelCatalog.bestVariant(of: model, device: device, profile: profile, budget: budget)?.0.id
                    ?? model.variants.first?.id
            }
            contextLength = Double(min(profile.defaultContext, model.facts.trainContext))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.name).font(.omniaLargeTitle)
            Text("\(model.developer) · released \(model.released)").font(.subheadline).foregroundStyle(.secondary)
            Text(model.summary).font(.body)
            HStack(spacing: 6) { ForEach(model.tags, id: \.self) { Pill(text: $0) } }
        }
    }

    private var factsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: "Parameters", value: model.parameterLabel, symbol: "circle.grid.3x3")
            StatTile(title: "Architecture", value: model.architectureLabel, detail: model.facts.isMixtureOfExperts ? "Mixture of experts" : "Dense", symbol: "square.stack.3d.up")
            StatTile(title: "Native context", value: ByteFormat.tokens(model.facts.trainContext), symbol: "text.alignleft")
            StatTile(title: "License", value: model.license, symbol: "doc.text")
            StatTile(title: "Reasoning", value: model.facts.thinkingToggle ? "Switchable" : (model.tags.contains("Reasoning") ? "Always on" : "None"), symbol: "sparkle")
            StatTile(title: "Images", value: model.projector == nil ? "Text only" : "Can see images",
                     detail: model.projector.map { "Optional \(ByteFormat.file($0.sizeBytes)) image encoder, added after download" },
                     symbol: "photo")
            Link(destination: model.huggingFaceURL) {
                StatTile(title: "Source", value: "Hugging Face", detail: model.repo, symbol: "link")
            }
            .buttonStyle(.plain)
        }
    }

    private func assessVariants(budget: MemoryBudget, profile: OptimizationProfile) -> [String: VariantFit] {
        var fits: [String: VariantFit] = [:]
        for variant in model.variants {
            let assessment = ModelCatalog.assess(model, variant, device: device, profile: profile, budget: budget)
            let onCluster = !assessment.compatibility.isUsable && !variant.isMLX
                && engine.clusterPlan(facts: model.facts, fileSize: UInt64(variant.sizeBytes), budget: budget) != nil
            fits[variant.id] = VariantFit(assessment: assessment, onCluster: onCluster)
        }
        return fits
    }

    private func variantsSection(_ fits: [String: VariantFit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Quantizations", subtitle: "Lower bit-widths are smaller and faster but lose some accuracy. Estimates use this device's measured memory limits.")
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Theme.critical)
            }
            VStack(spacing: 8) {
                ForEach(model.variants) { variant in
                    if let fit = fits[variant.id] {
                        variantRow(variant, assessment: fit.assessment, onCluster: fit.onCluster)
                    }
                }
            }
            .surface(padding: 8)
        }
    }

    private func variantRow(_ variant: CatalogVariant, assessment: VariantAssessment, onCluster: Bool) -> some View {
                    HStack(spacing: 12) {
                        Button {
                            selectedVariantID = variant.id
                        } label: {
                            Image(systemName: selectedVariantID == variant.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show memory for \(variant.quant)")

                        VStack(alignment: .leading, spacing: 3) {
                            Text(variant.label(parameters: model.facts.parameters)).font(.subheadline.weight(.semibold))
                            Text("\(ByteFormat.file(variant.sizeBytes)) · quality \(Int(model.quality(of: variant))) · ≈ \(Int(assessment.estimatedTokensPerSecond)) tok/s est.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if onCluster {
                            Pill(text: "Runs on your cluster", symbol: "point.3.connected.trianglepath.dotted", tint: Theme.positive)
                        } else {
                            CompatibilityBadge(compatibility: assessment.compatibility)
                        }
                        DownloadButton(model: model, variant: variant, errorMessage: $errorMessage,
                                       exceedsMemory: !assessment.compatibility.isUsable && !onCluster)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(selectedVariantID == variant.id ? Color.accentColor.opacity(0.07) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func memorySection(budget: MemoryBudget, profile: OptimizationProfile) -> some View {
        if let variant = model.variants.first(where: { $0.id == selectedVariantID }) {
            let maxContext = Double(min(model.facts.trainContext, profile.maximumContext))
            let kvTypes = MemoryPlanner.allowedKVTypes(kvChoice, profile: profile, flashAttention: settings.flashAttention)
            let kv = kvTypes.first ?? .q8_0
            let estimate = MemoryPlanner.estimate(model.facts, fileSize: UInt64(variant.sizeBytes), context: Int(contextLength),
                                                  kv: kv, microBatch: profile.microBatchSize, flashAttention: settings.flashAttention)
            let fits = budget.allowance.admits(estimate)
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Memory at a given context", subtitle: "The KV cache grows with context; the weights don't.")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Context").font(.subheadline)
                        Spacer()
                        Text("\(ByteFormat.tokens(Int(contextLength))) tokens").font(.subheadline.monospacedDigit())
                    }
                    Slider(value: $contextLength, in: 2048...max(4096, maxContext), step: 1024)
                    Picker("KV cache", selection: $kvChoice) {
                        ForEach(KVCacheChoice.allCases) { Text($0 == .automatic ? "Auto (\(kv.label))" : $0.title).tag($0) }
                    }
                    MemoryBreakdownBar(estimate: estimate, capacity: budget.usable, accent: .accentColor)
                    HStack(spacing: 8) {
                        Image(systemName: fits ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(fits ? Theme.positive : Theme.critical)
                        Text(fits
                             ? "\(ByteFormat.memory(estimate.total)) of \(ByteFormat.memory(budget.usable)) — fits safely."
                             : "\(ByteFormat.memory(estimate.total)) exceeds the \(ByteFormat.memory(budget.usable)) OMNIA allows on this device. Choose a shorter context or a smaller quantization, or download it anyway to run it slowly with a short context.")
                            .font(.footnote)
                    }
                }
                .surface()
            }
        }
    }
}
