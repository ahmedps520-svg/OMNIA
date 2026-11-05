import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisionKit

/// A QR code, black on white with its quiet zone, so a camera reads it in light or dark mode.
struct QRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("QR code to join the cluster")
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The last code drawn. The Cluster screen redraws with every device's heartbeat while its
    /// invitation stays the same, and drawing the code again took a new Core Image context each time.
    @MainActor private static var cached: (text: String, image: UIImage?)?
    @MainActor private static let context = CIContext()

    @MainActor
    static func image(for text: String) -> UIImage? {
        if let cached, cached.text == text { return cached.image }
        let image = render(text)
        cached = (text, image)
        return image
    }

    @MainActor
    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The camera, reading QR codes until one is a cluster's invitation.
struct QRScannerView: UIViewControllerRepresentable {
    var onInvitation: (ClusterInvitation) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInvitation: onInvitation)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onInvitation: (ClusterInvitation) -> Void
        private var found = false

        init(onInvitation: @escaping (ClusterInvitation) -> Void) {
            self.onInvitation = onInvitation
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !found else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
                      let url = URL(string: payload), let invitation = ClusterInvitation(url: url) else { continue }
                found = true
                dataScanner.stopScanning()
                onInvitation(invitation)
                return
            }
        }
    }
}

/// Scans a host's QR code to lend this device to its cluster.
struct ClusterScanSheet: View {
    var enterCode: () -> Void
    var onInvitation: (ClusterInvitation) -> Void

    @Environment(\.dismiss) private var dismiss
    /// nil until camera access is settled (iOS asks the first time).
    @State private var cameraReady: Bool?

    var body: some View {
        NavigationStack {
            Group {
                switch cameraReady {
                case .some(true):
                    QRScannerView(onInvitation: onInvitation)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text("Point the camera at the QR code on the host's Cluster screen.")
                                .font(.subheadline)
                                .padding(14)
                                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                                .padding(20)
                        }
                case .some(false):
                    ContentUnavailableView {
                        Label("Can't Use the Camera", systemImage: "camera")
                    } description: {
                        Text("Allow OMNIA to use the camera in Settings, or enter the host's address and code instead.")
                    } actions: {
                        Button("Enter Code", action: enterCode).buttonStyle(.glassProminent)
                    }
                case .none:
                    ProgressView()
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Enter Code", action: enterCode)
                }
            }
        }
        .task {
            guard DataScannerViewController.isSupported else {
                cameraReady = false
                return
            }
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            cameraReady = DataScannerViewController.isAvailable
        }
    }
}

/// Joins a cluster by typing what the host shows under its QR code.
struct ClusterCodeSheet: View {
    var onInvitation: (ClusterInvitation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address, like 192.168.1.20:8770", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("Both are under the QR code on the host's Cluster screen. The two devices must be on the same Wi-Fi.")
                }
            }
            .navigationTitle("Enter Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        if let invitation { onInvitation(invitation) }
                    }
                    .disabled(invitation == nil)
                }
            }
        }
    }

    private var invitation: ClusterInvitation? {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = address.contains(":") ? address : "\(address):\(ClusterProtocol.httpPort)"
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard ClusterInvitation.isEndpoint(endpoint), normalized.count == 10 else { return nil }
        return ClusterInvitation(host: endpoint, code: normalized, name: "the host")
    }
}
