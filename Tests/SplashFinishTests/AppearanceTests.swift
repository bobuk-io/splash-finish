import AppKit
import XCTest
@testable import SplashFinish

final class AppearanceTests: XCTestCase {
    func testPaletteResolvesForBothThemes() throws {
        let color = NSColor.theme(light: 0x222A2E, dark: 0xEEF1EC)
        for (name, red) in [(NSAppearance.Name.aqua, 0x22), (.darkAqua, 0xEE)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let resolved = color.usingColorSpace(.sRGB)
                XCTAssertEqual(resolved?.redComponent ?? -1, Double(red) / 255, accuracy: 0.001)
            }
        }
    }

    func testThemeValuesAreStableForSavedPreferences() {
        XCTAssertEqual(AppTheme.light.rawValue, "light")
        XCTAssertEqual(AppTheme.dark.rawValue, "dark")
        XCTAssertNil(AppTheme(rawValue: "invalid"))
    }
}
