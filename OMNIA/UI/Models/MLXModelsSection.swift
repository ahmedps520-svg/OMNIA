import SwiftUI

/// The Models screen's MLX tab: models for Apple's MLX engine, with how they fit this device.
struct MLXModelsSection: View {
    @Environment(InferenceEngine.self) private var engine

    private let device = AppServices.shared.device

    var body: some View {
        let budget = engine.currentBudget()
        let profile = engine.profile
        let assessed = ModelCatalog.mlx.map { model in
            (model: model, best: ModelCatalog.bestVariant(of: model, device: device, profile: profile, budget: budget))
        }
        let fitting = assessed.filter { $0.best != nil }.sorted { $0.model.qualityScore > $1.model.qualityScore }
        let tooLarge = assessed.filter { $0.best == nil }

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("MLX (Beta)", subtitle: "Apple's MLX engine runs these models from folders of safetensors (mlx-community). On M5 chips it reads prompts with the GPU's Neural Accelerators. Download one, then pick it in a chat like any other model. MLX models read text only, and every file is checked against its published SHA-256.")
            LazyVStack(spacing: 10) {
                ForEach(fitting + tooLarge, id: \.model.id) { entry in
                    NavigationLink(value: entry.model) {
                        CatalogModelRow(model: entry.model, best: entry.best)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
