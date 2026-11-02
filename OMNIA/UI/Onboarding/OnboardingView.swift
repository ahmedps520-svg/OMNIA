import SwiftUI

/// First launch: welcome, what OMNIA detected about this device, and a model recommendation.
struct OnboardingView: View {
    var onFinish: (SidebarSection?) -> Void

    @Environment(InferenceEngine.self) private var engine
    @Environment(DownloadManager.self) private var downloads
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(AppSettings.self) private var settings

    @State private var step = 0
    @State private var mode: RecommendationMode = .balanced
    @State private var downloadError: String?

    private let device = AppServices.shared.device

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(0)
                deviceStep.tag(1)
                recommendationStep.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .omniaAnimation(settings.animations, value: step)

            HStack {
                pageDots
                Spacer()
                if step < 2 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .onAppear { mode = engine.profile.defaultRecommendation }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == step ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 30) {
            Spacer()
            OmniaMark(size: 110, animated: true)
            VStack(spacing: 10) {
                OmniaWordmark(size: 34)
                Text("Every model. One mind.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                feature("cpu", "Runs on your hardware", "Language models execute on the Apple GPU through Metal. Nothing is sent to a server.")
                feature("lock.shield", "Private by design", "No account, no telemetry, no cloud. Conversations stay in OMNIA's sandbox.")
                feature("wifi.slash", "Works offline", "Once a model is downloaded, chat works with no connection at all.")
            }
            .frame(maxWidth: 460)
            Spacer()
        }
        .padding(32)
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var deviceStep: some View {
        let budget = engine.currentBudget()
        let profile = engine.profile
        return ScrollView {
            VStack(spacing: 26) {
                Image(systemName: device.isPad ? "ipad.landscape" : "iphone")
                    .font(.system(size: 54, weight: .thin))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
                VStack(spacing: 6) {
                    Text(device.name).font(.title2.weight(.semibold))
                    Text("\(device.chip) · \(device.configurationSummary)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    StatTile(title: "Unified memory", value: "\(device.memoryGB) GB", symbol: "memorychip")
                    StatTile(title: "For models", value: ByteFormat.memory(budget.usable),
                             detail: budget.isMeasured ? "Measured headroom, safety margin applied" : "Estimated (Simulator)",
                             symbol: "square.stack.3d.up")
                    StatTile(title: "CPU", value: "\(device.cpuCores) cores", detail: "\(device.performanceCores) performance · \(device.efficiencyCores) efficiency", symbol: "cpu")
                    StatTile(title: "GPU", value: device.gpuName.replacingOccurrences(of: "Apple ", with: ""), detail: "Metal acceleration", symbol: "square.grid.3x3.fill")
                }
                .frame(maxWidth: 560)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Profile: \(profile.title)", systemImage: device.isPad ? "sparkles" : "leaf")
                        .font(.headline)
                    Text(profile.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .surface()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    private var recommendationStep: some View {
        let budget = engine.currentBudget()
        let recommendation = ModelCatalog.recommend(mode, device: device, profile: engine.profile, budget: budget)
        return ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Recommended for this device")
                        .font(.title2.weight(.semibold))
                    Text("Chosen from file size, architecture and context needs, measured against this device's memory.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                }
                .padding(.top, 40)

                Picker("Priority", selection: $mode) {
                    ForEach(RecommendationMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)

                if let recommendation {
                    RecommendationCard(recommendation: recommendation, device: device)
                        .frame(maxWidth: 560)
                    VStack(spacing: 10) {
                        Button {
                            startDownload(recommendation)
                        } label: {
                            Label("Download \(ByteFormat.file(recommendation.variant.sizeBytes))", systemImage: "arrow.down.circle")
                                .frame(maxWidth: 320)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(!connectivity.isOnline || settings.offlineOnly)

                        if !connectivity.isOnline || settings.offlineOnly {
                            Text(settings.offlineOnly ? "Offline-only mode is on." : "Connect to the internet to download models.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let downloadError {
                            Text(downloadError).font(.caption).foregroundStyle(Theme.critical).multilineTextAlignment(.center)
                        }
                        Button("Choose Later") { onFinish(.models) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                } else {
                    OmniaEmptyState(title: "No catalog model fits right now",
                                    message: "Close other apps to free memory, or import a smaller GGUF model from Files.",
                                    symbol: "memorychip")
                    Button("Continue") { onFinish(.models) }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    private func startDownload(_ recommendation: Recommendation) {
        do {
            try downloads.start(recommendation.model.downloadRequest(for: recommendation.variant))
            onFinish(.models)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

/// A recommended model and why it was chosen.
struct RecommendationCard: View {
    let recommendation: Recommendation
    let device: DeviceProfile

    var body: some View {
        let assessment = recommendation.assessment
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.model.name).font(.title3.weight(.semibold))
                    Text("\(recommendation.model.developer) · \(recommendation.model.parameterLabel) · \(recommendation.variant.quant)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CompatibilityBadge(compatibility: assessment.compatibility)
            }
            Text(recommendation.rationale)
                .font(.subheadline)
            HStack(spacing: 18) {
                metric("Download", ByteFormat.file(recommendation.variant.sizeBytes))
                metric("Runtime memory", ByteFormat.memory(assessment.plan.estimate.total))
                metric("Context", ByteFormat.tokens(assessment.plan.contextLength))
                metric("Speed (est.)", String(format: "%.0f tok/s", assessment.estimatedTokensPerSecond))
            }
            Text(recommendation.model.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .surface(padding: 18)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}
