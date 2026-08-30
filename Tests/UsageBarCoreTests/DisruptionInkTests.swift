import Foundation
import Testing
@testable import UsageBarCore

/// The six slot fills, measured from `NSColor.system*` under Aqua and Dark Aqua
/// on macOS 26.5, 2026-08-24. Channels are the sRGB values AppKit returned,
/// not the rounded hex. `error` is `systemGray` at alpha 0.5; the RGB is the
/// same as `idle` and the ink reads the source colour, not the composite.
private struct SlotFill: Sendable {
    let tone: String
    let appearance: String
    let fill: SRGBColor
}

private let slotFills: [SlotFill] = [
    .init(tone: "ok", appearance: "light", fill: SRGBColor(red: 0.2039, green: 0.7804, blue: 0.3490)),
    .init(tone: "ok", appearance: "dark", fill: SRGBColor(red: 0.1882, green: 0.8196, blue: 0.3451)),
    .init(tone: "warning", appearance: "light", fill: SRGBColor(red: 1.0000, green: 0.8000, blue: 0.0000)),
    .init(tone: "warning", appearance: "dark", fill: SRGBColor(red: 1.0000, green: 0.8392, blue: 0.0000)),
    .init(tone: "critical", appearance: "light", fill: SRGBColor(red: 1.0000, green: 0.5529, blue: 0.1569)),
    .init(tone: "critical", appearance: "dark", fill: SRGBColor(red: 1.0000, green: 0.5725, blue: 0.1882)),
    .init(tone: "blocked", appearance: "light", fill: SRGBColor(red: 1.0000, green: 0.2196, blue: 0.2353)),
    .init(tone: "blocked", appearance: "dark", fill: SRGBColor(red: 1.0000, green: 0.2588, blue: 0.2706)),
    .init(tone: "error", appearance: "light", fill: SRGBColor(red: 0.5569, green: 0.5569, blue: 0.5765)),
    .init(tone: "error", appearance: "dark", fill: SRGBColor(red: 0.5961, green: 0.5961, blue: 0.6157)),
    .init(tone: "idle", appearance: "light", fill: SRGBColor(red: 0.5569, green: 0.5569, blue: 0.5765)),
    .init(tone: "idle", appearance: "dark", fill: SRGBColor(red: 0.5961, green: 0.5961, blue: 0.6157)),
]

@Suite("DisruptionInk")
struct DisruptionInkTests {

    @Test func linearizeMatchesWCAGEdges() {
        #expect(DisruptionInk.linearize(0) == 0)
        #expect(DisruptionInk.linearize(1) == 1)
        // The break between the two WCAG branches.
        #expect(abs(DisruptionInk.linearize(0.04045) - 0.04045 / 12.92) < 1e-12)
        #expect(DisruptionInk.linearize(0) < DisruptionInk.linearize(0.5))
        #expect(DisruptionInk.linearize(0.5) < DisruptionInk.linearize(1))
    }

    @Test func blackAndWhiteAreTheWCAGAnchors() {
        #expect(DisruptionInk.relativeLuminance(of: .black) == 0)
        #expect(DisruptionInk.relativeLuminance(of: .white) == 1)
        #expect(abs(DisruptionInk.contrastRatio(between: .black, and: .white) - 21) < 1e-9)
        #expect(DisruptionInk.contrastRatio(between: .white, and: .white) == 1)
        #expect(DisruptionInk.contrastRatio(between: .black, and: .black) == 1)
    }

    /// A comparison whose result depends on input order is a bug.
    @Test func contrastRatioDoesNotDependOnOrder() {
        for slot in slotFills {
            let blackFirst = DisruptionInk.contrastRatio(between: .black, and: slot.fill)
            let fillFirst = DisruptionInk.contrastRatio(between: slot.fill, and: .black)
            #expect(blackFirst == fillFirst, "\(slot.tone) \(slot.appearance)")
            let whiteFirst = DisruptionInk.contrastRatio(between: .white, and: slot.fill)
            let fillThenWhite = DisruptionInk.contrastRatio(between: slot.fill, and: .white)
            #expect(whiteFirst == fillThenWhite, "\(slot.tone) \(slot.appearance)")
        }
        #expect(
            DisruptionInk.contrastRatio(0.64, 0) == DisruptionInk.contrastRatio(0, 0.64)
        )
    }

    @Test func darkFillPicksWhiteAndLightFillPicksBlack() {
        #expect(DisruptionInk.on(fill: SRGBColor(red: 0.05, green: 0.08, blue: 0.2)) == .white)
        #expect(DisruptionInk.on(fill: SRGBColor(red: 0.2, green: 0.8, blue: 0.35)) == .black)
        #expect(DisruptionInk.on(fill: .white) == .black)
        #expect(DisruptionInk.on(fill: .black) == .white)
    }

    /// Relative luminance √0.0525 − 0.05 is where black and white contrast
    /// equally (~4.58:1). Grey 0.5 is above that and takes black; 0.4 is
    /// below and takes white.
    @Test func greyOnEitherSideOfTheThreshold() {
        let lighter = SRGBColor(red: 0.5, green: 0.5, blue: 0.5)
        #expect(DisruptionInk.relativeLuminance(of: lighter) > 0.179)
        #expect(DisruptionInk.on(fill: lighter) == .black)
        let darker = SRGBColor(red: 0.4, green: 0.4, blue: 0.4)
        #expect(DisruptionInk.relativeLuminance(of: darker) < 0.179)
        #expect(DisruptionInk.on(fill: darker) == .white)
    }

    /// Dark Mode used `labelColor`, which is near-white. White on `systemGreen`
    /// is 2.02:1 — below the 3:1 graphics floor, which is why the dot vanished.
    @Test func whiteOnDarkGreenIsTheBug() {
        let darkGreen = SRGBColor(red: 0.1882, green: 0.8196, blue: 0.3451)
        #expect(DisruptionInk.contrastRatio(between: .white, and: darkGreen) < 3)
        #expect(DisruptionInk.on(fill: darkGreen) == .black)
        #expect(DisruptionInk.contrast(on: darkGreen) > 3)
    }

    /// Yellow is the hard case only for white ink. Black on `systemYellow` is
    /// the highest contrast of the six tones, so no ring, no bigger dot.
    @Test func yellowIsHopelessForWhiteAndTrivialForBlack() {
        let yellow = SRGBColor(red: 1, green: 0.8, blue: 0)
        #expect(DisruptionInk.contrastRatio(between: .white, and: yellow) < 2)
        #expect(DisruptionInk.on(fill: yellow) == .black)
        #expect(DisruptionInk.contrast(on: yellow) > 13)
    }

    @Test func everySlotPicksBlackAndClearsTheGraphicsFloor() {
        let floor = 3.0
        for slot in slotFills {
            let ink = DisruptionInk.on(fill: slot.fill)
            let contrast = DisruptionInk.contrast(on: slot.fill)
            #expect(ink == .black, "\(slot.tone) \(slot.appearance) picked \(ink)")
            #expect(contrast >= floor, "\(slot.tone) \(slot.appearance) contrast \(contrast)")
        }
    }

    /// Opaque sRGB cannot fall below ~4.58:1 against the better of black and
    /// white, so a ring is never the thing that saves these slots.
    @Test func betterPolarityStaysAboveTheGraphicsFloorAcrossTheLuminanceSweep() {
        for step in 0...20 {
            let channel = Double(step) / 20
            let fill = SRGBColor(red: channel, green: channel, blue: channel)
            #expect(DisruptionInk.contrast(on: fill) > 4.5, "L channel \(channel)")
        }
    }

    @Test func idleDarkWouldFailIfTheInkStayedWhite() {
        let idleDark = SRGBColor(red: 0.5961, green: 0.5961, blue: 0.6157)
        #expect(DisruptionInk.contrastRatio(between: .white, and: idleDark) < 3)
        #expect(DisruptionInk.on(fill: idleDark) == .black)
        #expect(DisruptionInk.contrast(on: idleDark) > 3)
    }
}
