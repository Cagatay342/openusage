import Foundation

/// Bundled web dashboard served at `GET /` on the local usage API (port 6736).
enum LocalUsageDashboard {
    private static let cached: Data? = {
        guard let url = Bundle.openUsageResources.url(forResource: "usage-dashboard", withExtension: "html"),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return data
    }()

    static var html: Data? { cached }
}
