import XCTest
@testable import FocusTracker

/// Two windows side by side on a 3360×1890 display, with the accuracy measured in real use
/// (±13 % horizontal, ±28 % vertical).
final class WindowShareTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 3360, height: 1890)
    private let left = WindowFocus.WindowInfo(id: 1, pid: 1, bounds: CGRect(x: 0, y: 25, width: 1680, height: 1865))
    private let right = WindowFocus.WindowInfo(id: 2, pid: 2, bounds: CGRect(x: 1680, y: 25, width: 1680, height: 1865))
    private lazy var sigma = CGSize(width: display.width * 0.13, height: display.height * 0.28)

    private func likely(u: CGFloat, v: CGFloat, windows: [WindowFocus.WindowInfo]? = nil) -> CGWindowID? {
        let shares = WindowFocus.shares(center: CGPoint(x: u * display.width, y: v * display.height),
                                        sigma: sigma, display: display, windows: windows ?? [right, left])
        return WindowFocus.likelyWindow(from: shares)?.id
    }

    func testPicksLeftWindowIncludingNearTheEdge() {
        XCTAssertEqual(likely(u: 0.25, v: 0.5), left.id)
        // Old bug: the uncertainty box stuck out over the display edge, so the left window never "covered" it.
        XCTAssertEqual(likely(u: 0.05, v: 0.2), left.id)
        XCTAssertEqual(likely(u: 0.0, v: 0.9), left.id)
    }

    func testPicksRightWindow() {
        XCTAssertEqual(likely(u: 0.75, v: 0.3), right.id)
        XCTAssertEqual(likely(u: 1.0, v: 0.1), right.id)
    }

    func testUndecidedAtTheSplit() {
        XCTAssertNil(likely(u: 0.5, v: 0.5))
    }

    func testOccludedPartsBelongToTheFrontWindow() {
        // A small window in front of the left one, around the gaze point: neither is clearly ahead.
        let popup = WindowFocus.WindowInfo(id: 3, pid: 3, bounds: CGRect(x: 400, y: 600, width: 600, height: 500))
        let shares = WindowFocus.shares(center: CGPoint(x: 700, y: 850), sigma: sigma, display: display,
                                        windows: [popup, right, left])
        let popupShare = shares.first { $0.window.id == 3 }?.share ?? 0
        XCTAssertGreaterThan(popupShare, 0.1)
        XCTAssertLessThan(popupShare, 0.6)
        XCTAssertEqual(shares.reduce(0) { $0 + $1.share }, 1, accuracy: 0.05)
    }
}
