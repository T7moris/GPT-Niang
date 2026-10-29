import Foundation
@main struct VerifyRefreshPolicy {
    static func main() {
        precondition(WidgetRefreshPolicy.windowInterval(follow: false, foreground: true, moving: false) == 1)
        precondition(WidgetRefreshPolicy.windowInterval(follow: true, foreground: false, moving: false) == 1)
        precondition(WidgetRefreshPolicy.windowInterval(follow: true, foreground: true, moving: false) == 0.1)
        precondition(WidgetRefreshPolicy.windowInterval(follow: true, foreground: true, moving: true) == 1.0/60)
        precondition(!WidgetRefreshPolicy.animates(visible: false, bubble: true, fullColor: true, textColor: false))
        precondition(!WidgetRefreshPolicy.animates(visible: true, bubble: false, fullColor: false, textColor: true))
        precondition(WidgetRefreshPolicy.animates(visible: true, bubble: false, fullColor: true, textColor: false))
        precondition(WidgetRefreshPolicy.animates(visible: true, bubble: true, fullColor: false, textColor: true))
        print("Refresh policy: 8 checks passed")
    }
}
