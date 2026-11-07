import AVKit
import SwiftUI

/// The system AirPlay route picker, scoped to video devices so the companion
/// hands playback to an Apple TV rather than an audio-only route.
public struct AirPlayRouteButton: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .label
        picker.activeTintColor = .systemBlue
        picker.accessibilityLabel = "AirPlay to Apple TV"
        return picker
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
