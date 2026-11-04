import Foundation
import Testing
@testable import PlayItRight

@MainActor
@Suite("PlayerOverlayViewModel Tests")
struct PlayerOverlayViewModelTests {
    @Test("Auto-hide timer resets on every interaction")
    func autoHideResets() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = PlayerOverlayViewModel(
            duration: 3_600,
            autoHideDelay: 3,
            now: { start }
        )

        #expect(viewModel.isVisible)

        viewModel.interact(at: start)
        viewModel.tick(at: start.addingTimeInterval(2.9))
        #expect(viewModel.isVisible)

        viewModel.tick(at: start.addingTimeInterval(3.1))
        #expect(viewModel.isVisible == false)

        viewModel.interact(at: start.addingTimeInterval(4))
        #expect(viewModel.isVisible)
        viewModel.tick(at: start.addingTimeInterval(6.9))
        #expect(viewModel.isVisible)
        viewModel.tick(at: start.addingTimeInterval(7.1))
        #expect(viewModel.isVisible == false)
    }

    @Test("Scrubbing holds the overlay open until it ends")
    func scrubbingKeepsOverlayVisible() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = PlayerOverlayViewModel(
            duration: 3_600,
            autoHideDelay: 3,
            now: { start }
        )

        viewModel.beginScrubbing(at: start)
        viewModel.tick(at: start.addingTimeInterval(30))
        #expect(viewModel.isVisible)
        #expect(viewModel.isScrubbing)

        viewModel.endScrubbing(at: start.addingTimeInterval(30))
        #expect(viewModel.isScrubbing == false)
        #expect(viewModel.isVisible)
    }

    @Test("Seek events are debounced to the last scrub position")
    func seekDebouncing() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var seeks: [TimeInterval] = []
        let viewModel = PlayerOverlayViewModel(
            duration: 600,
            seekDebounceInterval: 0.25,
            now: { start }
        )
        viewModel.onSeek = { seeks.append($0) }

        viewModel.requestSeek(to: 10, at: start)
        viewModel.requestSeek(to: 20, at: start.addingTimeInterval(0.1))

        #expect(viewModel.flushSeekIfNeeded(at: start.addingTimeInterval(0.2)) == false)
        #expect(seeks.isEmpty)

        #expect(viewModel.flushSeekIfNeeded(at: start.addingTimeInterval(0.4)))
        #expect(seeks == [20])
        #expect(viewModel.position == 20)
    }

    @Test("Skipping, chapter navigation, and clamping")
    func transportNavigation() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var seeks: [TimeInterval] = []
        let viewModel = PlayerOverlayViewModel(
            duration: 300,
            chapters: [
                PlaybackChapter(index: 0, title: "Opening", time: 0),
                PlaybackChapter(index: 1, title: "Middle", time: 60),
                PlaybackChapter(index: 2, title: "Finale", time: 120)
            ],
            now: { start }
        )
        viewModel.onSeek = { seeks.append($0) }

        viewModel.seek(to: 30, at: start, immediate: true)
        #expect(viewModel.position == 30)

        viewModel.skip(by: 10, at: start)
        #expect(viewModel.position == 40)

        viewModel.nextChapter(at: start)
        #expect(viewModel.position == 60)
        #expect(viewModel.currentChapter?.title == "Middle")

        viewModel.nextChapter(at: start)
        #expect(viewModel.position == 120)

        viewModel.previousChapter(at: start)
        #expect(viewModel.position == 60)

        viewModel.skip(by: 10_000, at: start)
        #expect(viewModel.position == 300)

        viewModel.skip(by: -10_000, at: start)
        #expect(viewModel.position == 0)
        #expect(seeks.last == 0)
    }

    @Test("Play/pause and track selection notify handlers")
    func playbackAndTrackSelection() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let audio = [
            PlayerTrackOption(id: "a0", name: "TrueHD", language: "en"),
            PlayerTrackOption(id: "a1", name: "Stereo", language: "fr")
        ]
        let subtitles = [
            PlayerTrackOption(id: "s0", name: "English", language: "en")
        ]
        let viewModel = PlayerOverlayViewModel(
            duration: 100,
            audioTracks: audio,
            subtitleTracks: subtitles,
            now: { start }
        )

        #expect(viewModel.selectedAudio?.id == "a0")
        #expect(viewModel.selectedSubtitle?.id == "s0")

        var playingStates: [Bool] = []
        var selectedAudio: [String?] = []
        var selectedSubtitle: [String?] = []
        viewModel.onPlayPause = { playingStates.append($0) }
        viewModel.onAudioChanged = { selectedAudio.append($0?.id) }
        viewModel.onSubtitleChanged = { selectedSubtitle.append($0?.id) }

        viewModel.togglePlayback(at: start)
        #expect(playingStates == [true])
        viewModel.togglePlayback(at: start)
        #expect(playingStates == [true, false])

        viewModel.selectAudio(audio[1], at: start)
        #expect(viewModel.selectedAudio?.id == "a1")
        #expect(selectedAudio == ["a1"])

        viewModel.selectSubtitle(nil, at: start)
        #expect(viewModel.selectedSubtitle == nil)
        #expect(selectedSubtitle == [nil])
    }
}
