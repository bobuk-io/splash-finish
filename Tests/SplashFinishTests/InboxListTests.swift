import AppKit
import SwiftUI
import XCTest
@testable import SplashFinish

@MainActor private final class ListFixture: ObservableObject {
    @Published var count = 8
    @Published var maxHeight: CGFloat = 240
}

private struct ListFixtureView: View {
    @ObservedObject var fixture: ListFixture
    var body: some View {
        VStack(spacing: 0) {
            Text("Inbox header").frame(height: 80)
            InboxList(maxHeight: fixture.maxHeight) {
                VStack(spacing: 0) {
                    ForEach(0..<fixture.count, id: \.self) { index in
                        MessagePreview(text: "Completed task \(index)", size: 16, color: .labelColor,
                                       lines: 2, characterLimit: 160, onOpenSource: {})
                            .frame(height: 100)
                    }
                }
            }
            Text("Inbox footer").frame(height: 60)
        }.frame(width: 420).fixedSize(horizontal: false, vertical: true)
    }
}

final class InboxListTests: XCTestCase {
    func testRowsStayInsideListAfterTallInboxShrinksAndGrows() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let fixture = ListFixture()
            let host = NSHostingView(rootView: ListFixtureView(fixture: fixture))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }

            @MainActor func settle() {
                for _ in 0..<8 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                }
            }
            @MainActor func previews(in view: NSView) -> [PreviewTextView] {
                if let preview = view as? PreviewTextView { return [preview] }
                return view.subviews.flatMap { previews(in: $0) }
            }

            settle()
            XCTAssertEqual(host.frame.height, 380, accuracy: 1)
            XCTAssertEqual(previews(in: host).count, 8, "Each row must have only one native preview")

            // Closing a question removes a large section and leaves one completed row.
            fixture.count = 1
            settle()
            XCTAssertEqual(host.frame.height, 240, accuracy: 1, "The list must shrink to its content")
            let remaining = previews(in: host)
            XCTAssertEqual(remaining.count, 1)
            let preview = try XCTUnwrap(remaining.first)
            let rect = preview.convert(preview.bounds, to: host)
            let headerBottom = host.isFlipped ? CGFloat(80) : CGFloat(60)
            XCTAssertGreaterThanOrEqual(rect.minY, headerBottom - 1, "Preview must not overlap the header/footer")
            XCTAssertLessThanOrEqual(rect.maxY, headerBottom + 101)
            XCTAssertEqual(preview.attributedString().string, "Completed task 0")

            fixture.count = 8
            fixture.maxHeight = 180
            settle()
            XCTAssertEqual(host.frame.height, 320, accuracy: 1)
            XCTAssertEqual(previews(in: host).count, 8)

            fixture.count = 1
            settle()
            XCTAssertEqual(host.frame.height, 240, accuracy: 1)
            XCTAssertEqual(previews(in: host).count, 1)
        }
    }
}
