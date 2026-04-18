import XCTest

final class CameraAirUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLivePhotoControlVisibilityAndToggle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launchEnvironment["CAMERA_AIR_UI_TEST_LIVE_PHOTO_SUPPORTED"] = "1"
        app.launch()

        let livePhotoToggle = app.buttons["Live photo"]
        XCTAssertTrue(livePhotoToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(livePhotoToggle.value as? String, "On")

        livePhotoToggle.tap()
        XCTAssertEqual(livePhotoToggle.value as? String, "Off")
    }

    @MainActor
    func testLivePhotoControlHiddenWhenUnsupported() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launchEnvironment["CAMERA_AIR_UI_TEST_LIVE_PHOTO_SUPPORTED"] = "0"
        app.launch()

        let livePhotoToggle = app.buttons["Live photo"]
        XCTAssertTrue(livePhotoToggle.waitForExistence(timeout: 5))
        XCTAssertFalse(livePhotoToggle.isEnabled)
    }
}
