import SwiftUI

@main
struct QuickPanelLayoutTests {
    static func main() {
        testPanelProvidesRoomForPinnedHeaderAndScrollableBody()
        testScrollableBodyHasPositiveHeightBelowPinnedHeader()
        print("QuickPanelLayoutTests passed")
    }

    private static func testPanelProvidesRoomForPinnedHeaderAndScrollableBody() {
        assert(QuickPanelLayout.width == 392, "expected the existing menu bar width")
        assert(QuickPanelLayout.height >= 680, "expected enough height for the full default panel")
        assert(QuickPanelLayout.pinnedHeaderHeight == 58, "expected the header to reserve its full height")
        assert(QuickPanelLayout.verticalPadding >= 14, "expected top and bottom safe spacing")
    }

    private static func testScrollableBodyHasPositiveHeightBelowPinnedHeader() {
        let bodyHeight = QuickPanelLayout.height - QuickPanelLayout.pinnedHeaderHeight - QuickPanelLayout.verticalPadding * 2 - 8
        assert(bodyHeight > 0, "expected a positive scrollable body height")
    }
}
