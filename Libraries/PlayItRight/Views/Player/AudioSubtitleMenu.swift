import SwiftUI

/// Audio and subtitle track menus for the player overlay (UI-2, doc 06 §2.4).
public struct AudioSubtitleMenu: View {
    public let viewModel: PlayerOverlayViewModel

    public init(viewModel: PlayerOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Menu {
                ForEach(viewModel.audioTracks) { track in
                    Button {
                        viewModel.selectAudio(track)
                    } label: {
                        if track.id == viewModel.selectedAudioID {
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            } label: {
                Label(audioTitle, systemImage: "waveform")
                    .font(DesignTypography.callout)
            }
            .accessibilityLabel("Audio track: \(audioTitle)")

            Menu {
                Button("Off") {
                    viewModel.selectSubtitle(nil)
                }
                ForEach(viewModel.subtitleTracks) { track in
                    Button {
                        viewModel.selectSubtitle(track)
                    } label: {
                        if track.id == viewModel.selectedSubtitleID {
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            } label: {
                Label(subtitleTitle, systemImage: "captions.bubble")
                    .font(DesignTypography.callout)
            }
            .accessibilityLabel("Subtitles: \(subtitleTitle)")
        }
    }

    private var audioTitle: String {
        viewModel.selectedAudio?.displayName ?? "Audio"
    }

    private var subtitleTitle: String {
        viewModel.selectedSubtitle?.displayName ?? "Subtitles"
    }
}
