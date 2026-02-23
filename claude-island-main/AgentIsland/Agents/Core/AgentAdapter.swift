//
//  AgentAdapter.swift
//  AgentIsland
//
//  Protocol that every agent integration must conform to.
//  Adding a new agent = one new Swift file conforming to this protocol.
//

import Foundation
import SwiftUI

// MARK: - Permission Decision

/// The decision returned to an agent for a permission request.
public enum PermissionDecision: Sendable {
    case allow
    case deny(reason: String)
}

// MARK: - AgentAdapter Protocol

/// Contract for all agent integrations.
/// Implementations translate CLI-specific events into AgentEvents and
/// route permission decisions back to the CLI.
public protocol AgentAdapter: AnyObject, Sendable {
    /// Unique stable identifier (e.g. "claude", "codex"). Must be lowercase, no spaces.
    var agentId: String { get }

    /// Human-readable display name (e.g. "Claude Code", "Codex").
    var displayName: String { get }

    /// Brand accent color shown in the UI for this agent's sessions.
    var accentColor: Color { get }

    /// SF Symbol name for the agent's icon in the UI.
    var iconName: String { get }

    /// Install any hooks or monitoring required for this agent.
    /// Called once when the adapter is enabled in AgentRegistry.
    func install() async throws

    /// Undo everything install() did.
    /// Called when the adapter is disabled or the app quits.
    func uninstall() async throws

    /// Async stream of normalized events from this agent.
    /// The stream runs until uninstall() is called.
    var events: AsyncStream<AgentEvent> { get }

    /// Called by PermissionCoordinator when the user has made a decision.
    /// Implementors must route this back to the waiting CLI process.
    func resolvePermission(_ decision: PermissionDecision, for requestId: String) async
}
