import XCTest
@testable import FocusTracker

final class ProfileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-profiles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private let builtIn = Profile.Screen(uuid: "builtin", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let homeMonitor = Profile.Screen(uuid: "home-lg", name: "LG", frame: CGRect(x: 1512, y: -400, width: 2560, height: 1440))
    private let officeMonitor = Profile.Screen(uuid: "office-dell", name: "DELL", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    private func connected(_ screens: [Profile.Screen]) -> [(uuid: String, frame: CGRect)] {
        screens.map { ($0.uuid, $0.frame) }
    }

    func testMigratesLegacyCalibrationIntoDefaultProfile() throws {
        let legacy = dir.appendingPathComponent("calibration.json")
        try Data("[]".utf8).write(to: legacy)
        let store = ProfileStore(directory: dir)
        XCTAssertEqual(store.profiles.map(\.name), ["Default"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.calibrationURL(for: store.activeID).path))
    }

    func testPicksProfileByConnectedScreens() {
        let store = ProfileStore(directory: dir)
        store.setScreens([builtIn, homeMonitor])
        let home = store.active
        let office = store.create(name: "Office", cameraID: "")
        store.activate(office.id)
        store.setScreens([builtIn, officeMonitor])

        XCTAssertEqual(store.bestMatch(displays: connected([builtIn, homeMonitor]), cameras: [])?.id, home.id)
        XCTAssertEqual(store.bestMatch(displays: connected([builtIn, officeMonitor]), cameras: [])?.id, office.id)
        // Laptop alone: neither profile has all its screens.
        XCTAssertNil(store.bestMatch(displays: connected([builtIn]), cameras: []))
    }

    func testCameraDecidesBetweenProfilesWithSameScreens() {
        let store = ProfileStore(directory: dir)
        store.setScreens([builtIn])
        let laptopOnly = store.active
        let withWebcam = store.create(name: "Webcam", cameraID: "usb-cam")
        store.activate(withWebcam.id)
        store.setScreens([builtIn])

        XCTAssertEqual(store.bestMatch(displays: connected([builtIn]), cameras: ["usb-cam"])?.id, withWebcam.id)
        XCTAssertEqual(store.bestMatch(displays: connected([builtIn]), cameras: [])?.id, laptopOnly.id)
    }

    func testPersistsAndDeletes() {
        let store = ProfileStore(directory: dir)
        let office = store.create(name: "Office", cameraID: "cam")
        store.activate(office.id)

        let reloaded = ProfileStore(directory: dir)
        XCTAssertEqual(reloaded.profiles.count, 2)
        XCTAssertEqual(reloaded.active.name, "Office")
        XCTAssertEqual(reloaded.active.cameraID, "cam")

        var changed: Profile?
        reloaded.onActiveChange = { changed = $0 }
        reloaded.delete(office.id)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Default"])
        XCTAssertEqual(changed?.name, "Default")
        reloaded.delete(reloaded.activeID) // last profile is kept
        XCTAssertEqual(reloaded.profiles.count, 1)
    }
}
