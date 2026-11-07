import Foundation
import Testing
@testable import PlaybackKit

/// 21:9 ultrawide & anamorphic stretch tests (TASK-4.5, doc 06 §2.4).
@Suite
struct AspectScalerTests {
    // MARK: - Contained mode

    @Test
    func keepsSquarePixelsUntouched() throws {
        let t = try AspectScaler.transform(
            pixelWidth: 1920,
            pixelHeight: 1080,
            mode: .contained
        )
        #expect(t.sourceRect == .full)
        #expect(abs(t.displayAspectRatio - 16.0 / 9.0) < 1e-9)
        #expect(!t.removedBlackBars)
    }

    @Test
    func keepsWidePixelsSquareByDefault() throws {
        let t = try AspectScaler.transform(
            pixelWidth: 1024,
            pixelHeight: 424,
            pixelAspect: 1,
            mode: .contained
        )
        #expect(abs(t.displayAspectRatio - 1024.0 / 424.0) < 1e-9)
        #expect(t.sourceRect == .full)
        #expect(!t.removedBlackBars)
    }

    // MARK: - Anamorphic de-squeeze

    @Test
    func desqueezesAnamorphicDVD() throws {
        // Classic PAL anamorphic DVD: 720x480 pixels at PAR 2.0 → 2.99:1.
        let t = try AspectScaler.transform(
            pixelWidth: 720,
            pixelHeight: 480,
            pixelAspect: 2.0,
            mode: .anamorphicDequeeze
        )
        #expect(abs(t.displayAspectRatio - 3.0) < 1e-9)
        #expect(t.sourceRect == .full)
        #expect(t.removedBlackBars)
    }

    // MARK: - Custom letterbox (2.39:1 window)

    @Test
    func cropsLetterbarsOnSixteenByNine() throws {
        // 1920x1080 scope master with burned-in bars → crop to 2.39:1: the
        // remaining source strip is full width, height scaled.
        let t = try AspectScaler.showWidescreenWindow(
            pixelWidth: 1920,
            pixelHeight: 1080,
            pixelAspect: 1,
            targetRatio: AspectScaler.scopeRatio
        )
        #expect(t.sourceRect.x == 0)
        #expect(t.sourceRect.width == 1)
        let expectedHeight = (16.0 / 9.0) / AspectScaler.scopeRatio
        #expect(abs(t.sourceRect.height - expectedHeight) < 1e-9)
        let expectedY = (1.0 - expectedHeight) / 2.0
        #expect(abs(t.sourceRect.y - expectedY) < 1e-9)
        #expect(t.removedBlackBars)
        #expect(abs(t.displayAspectRatio - AspectScaler.scopeRatio) < 1e-9)
    }

    @Test
    func trimsNarrowPixelsToFillScopeWindow() throws {
        // A 2.35:1 picture forced into a 2.39:1 window is slightly
        // narrower than the target, so a sliver is cropped top/bottom.
        let t = try AspectScaler.showWidescreenWindow(
            pixelWidth: 2350,
            pixelHeight: 1000,
            pixelAspect: 1,
            targetRatio: AspectScaler.scopeRatio
        )
        let expectedHeight = (2350.0 / 1000.0) / AspectScaler.scopeRatio
        #expect(abs(t.sourceRect.height - expectedHeight) < 1e-9)
        #expect(abs(t.sourceRect.y - (1.0 - expectedHeight) / 2.0) < 1e-9)
        #expect(t.sourceRect.width == 1)
        #expect(t.removedBlackBars)
    }

    @Test
    func coversFullPipelineForUltrawideTV() throws {
        let frame = try AspectScaler.transform(
            pixelWidth: 1920,
            pixelHeight: 1080,
            mode: .customLetterbox
        )
        // A 2.39:1 window shown on a 21:9 panel nearly fills the height:
        // the letterbox bars are small and centered.
        let viewport = AspectScaler.videoFrame(
            contentAspectRatio: frame.displayAspectRatio,
            screenRatio: AspectScaler.ultrawideRatio
        )
        #expect(abs(viewport.y - (1.0 - viewport.height) / 2.0) < 1e-9)
        #expect(viewport.width == 1)
    }

    // MARK: - User stretch

    @Test
    func stretchesToRequestedRatio() throws {
        let t = try AspectScaler.transform(
            pixelWidth: 1280,
            pixelHeight: 720,
            mode: .stretch(to: 2.39)
        )
        #expect(abs(t.displayAspectRatio - 2.39) < 1e-9)
        #expect(t.sourceRect == .full)
        #expect(!t.removedBlackBars)
    }

    // MARK: - Frame-on-screen planning

    @Test
    func videoFrameCentersScopeOnSixteenByNineScreen() {
        let frame = AspectScaler.videoFrame(
            contentAspectRatio: 2.39,
            screenRatio: 16.0 / 9.0
        )
        #expect(frame.width == 1)
        let expectedHeight = (16.0 / 9.0) / 2.39
        #expect(abs(frame.height - expectedHeight) < 1e-9)
        #expect(abs(frame.y - (1.0 - expectedHeight) / 2.0) < 1e-9)
        #expect(frame.x == 0)
    }

    @Test
    func videoFramePillarboxesNarrowContent() {
        let frame = AspectScaler.videoFrame(
            contentAspectRatio: 4.0 / 3.0,
            screenRatio: 16.0 / 9.0
        )
        #expect(frame.height == 1)
        let expectedWidth = (4.0 / 3.0) / (16.0 / 9.0)
        #expect(abs(frame.width - expectedWidth) < 1e-9)
        #expect(abs(frame.x - (1.0 - expectedWidth) / 2.0) < 1e-9)
    }

    // MARK: - Classification helpers

    @Test
    func ultrawideWindowIsScopeClass() {
        #expect(AspectScaler.isUltrawide(AspectScaler.scopeRatio))
        #expect(AspectScaler.isUltrawide(AspectScaler.ultrawideRatio))
        #expect(!AspectScaler.isUltrawide(16.0 / 9.0))
        #expect(!AspectScaler.isUltrawide(2.6))
    }
}
