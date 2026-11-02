import SwiftUI

/// Shown on hardware outside OMNIA's targets (M5 iPad Pro, iPhone 18 Pro family).
struct UnsupportedDeviceView: View {
    let device: DeviceProfile
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            OmniaMark(size: 72)
            OmniaWordmark(size: 26)
            VStack(spacing: 10) {
                Text("Built for iPad Pro (M5) and iPhone 18 Pro")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("OMNIA is tuned for the memory bandwidth, unified memory and GPU of these devices. This device (\(device.identifier), \(device.memoryGB) GB) isn't one of them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            #if DEBUG
            Button("Continue Anyway (Development Build)", action: onContinue)
                .buttonStyle(.glass)
                .padding(.top, 8)
            #endif
            Spacer()
            Text("Supported: iPad Pro 11-inch and 13-inch (M5) · iPhone 18 Pro · iPhone 18 Pro Max")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
