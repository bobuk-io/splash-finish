import BobukCore
import Foundation
import Observation

/// Persists the user's last selected ACP agent, model, and reasoning effort across launches.
@MainActor @Observable public final class AgentChatPreferences {
    public struct StorageKeys: Equatable, Sendable {
        public var agentID: String
        public var model: String
        public var effort: String

        public init(
            agentID: String = "acpChatAgentID",
            model: String = "acpChatModel",
            effort: String = "acpChatEffort"
        ) {
            self.agentID = agentID
            self.model = model
            self.effort = effort
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: StorageKeys
    @ObservationIgnored private let availableAgents: [ACPAgentPreset]

    public var agent: ACPAgentPreset {
        didSet {
            guard agent.id != oldValue.id else { return }
            defaults.set(agent.id, forKey: keys.agentID)
            model = nil
            effort = nil
        }
    }

    public var model: String? {
        didSet {
            if let model, !model.isEmpty { defaults.set(model, forKey: keys.model) }
            else { defaults.removeObject(forKey: keys.model) }
        }
    }

    public var effort: String? {
        didSet {
            if let effort, !effort.isEmpty { defaults.set(effort, forKey: keys.effort) }
            else { defaults.removeObject(forKey: keys.effort) }
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        keys: StorageKeys = StorageKeys(),
        agents: [ACPAgentPreset] = ACPAgentPreset.all,
        defaultAgent: ACPAgentPreset? = nil
    ) {
        self.defaults = defaults
        self.keys = keys
        self.availableAgents = agents

        let storedID = defaults.string(forKey: keys.agentID)
        let resolvedAgent = storedID.flatMap { id in agents.first(where: { $0.id == id }) }
            ?? defaultAgent
            ?? agents.first
            ?? .antigravity
        self.agent = resolvedAgent
        self.model = defaults.string(forKey: keys.model)
        self.effort = defaults.string(forKey: keys.effort)
    }

    /// Synchronizes current model and effort from an active `AgentChatSession`.
    public func record(from session: AgentChatSession) {
        if let currentModel = session.models?.current, !currentModel.isEmpty {
            model = currentModel
        }
        if let currentEffort = session.efforts?.current, !currentEffort.isEmpty {
            effort = currentEffort
        }
    }
}
