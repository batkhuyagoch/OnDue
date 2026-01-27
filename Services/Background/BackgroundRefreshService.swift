import Foundation

protocol BackgroundRefreshServicing {
    func scheduleRefresh()
}

final class BackgroundRefreshService: BackgroundRefreshServicing {
    func scheduleRefresh() {
        // TODO: Configure BGAppRefreshTask and best-effort refresh.
    }
}
