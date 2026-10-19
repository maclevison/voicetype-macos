import Foundation
import Observation

/// Which meeting the approval window shows. The menu sets it before
/// `openWindow(id: ApprovalRouter.windowID)`, as `MainWindowRouter` does for
/// the main window.
@MainActor
@Observable
final class ApprovalRouter {
    static let windowID = "approval"
    var meetingDirectory: URL?
}
