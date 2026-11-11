import DSHProtocol

public struct ModelSelection: Equatable, Sendable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String?

    public init(provider: String, model: String, effort: String? = nil) {
        self.provider = provider
        self.model = model
        reasoningEffort = effort
    }

    init(_ message: Dshm_V1_ModelSelection) {
        self.init(provider: message.provider, model: message.model,
                  effort: message.hasReasoningEffort ? message.reasoningEffort : nil)
    }

    var wire: Dshm_V1_ModelSelection {
        var message = Dshm_V1_ModelSelection()
        message.provider = provider
        message.model = model
        if let reasoningEffort { message.reasoningEffort = reasoningEffort }
        return message
    }

    var transcriptLine: String {
        "\n[Model: \(provider)/\(model)\(reasoningEffort.map { " · " + $0 } ?? "")]\n"
    }
}

public struct ModelCatalog: Equatable, Sendable {
    public struct Effort: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Model: Equatable, Sendable {
        public let id: String
        public let name: String
        public let efforts: [Effort]
        public let defaultEffort: String?

        public init(id: String, name: String, efforts: [Effort] = [], defaultEffort: String? = nil) {
            self.id = id
            self.name = name
            self.efforts = efforts
            self.defaultEffort = defaultEffort
        }
    }

    public struct Group: Equatable, Sendable {
        public let id: String
        public let name: String
        public var models: [Model]

        public init(id: String, name: String, models: [Model]) {
            self.id = id
            self.name = name
            self.models = models
        }
    }

    public struct Failure: Equatable, Sendable {
        public let id: String
        public let name: String
        public let message: String
    }

    public let defaultSelection: ModelSelection?
    public let groups: [Group]
    public let failures: [Failure]

    init(_ message: Dshm_V1_ModelCatalog) {
        defaultSelection = message.hasDefaultSelection ? ModelSelection(message.defaultSelection) : nil
        groups = message.groups.map { group in
            Group(id: group.id, name: group.name, models: group.models.map { model in
                Model(id: model.id, name: model.name,
                      efforts: model.efforts.map { Effort(id: $0.id, name: $0.name) },
                      defaultEffort: model.hasDefaultEffort ? model.defaultEffort : nil)
            })
        }
        failures = message.failures.map { Failure(id: $0.id, name: $0.name, message: $0.message) }
    }

    public func entry(for selection: ModelSelection) -> Model? {
        groups.first { $0.id == selection.provider }?.models.first { $0.id == selection.model }
    }
}
