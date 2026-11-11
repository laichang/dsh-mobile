public struct WorkspaceList: Equatable, Sendable {
    public let defaultPath: String
    public let recentPaths: [String]

    public init(defaultPath: String, recentPaths: [String]) {
        self.defaultPath = defaultPath
        self.recentPaths = recentPaths
    }
}
