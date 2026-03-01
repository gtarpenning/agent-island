//
//  NotchView.swift
//  AgentIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var notifiedAssistantReplySignatureBySessionId: [String: String] = [:]
    @State private var hasPrimedSoundBaseline = false
    @State private var waitingForInputSoundTask: Task<Void, Never>?
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace
    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let codexBlue = Color(red: 0.24, green: 0.52, blue: 0.96)
    private let codexGreen = Color(red: 0.06, green: 0.73, blue: 0.51)
    private let waitingForInputDisplayDuration: TimeInterval = 30

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        return sessionMonitor.instances.contains { session in
            isSessionWaitingForInputVisible(session, now: now)
        }
    }

    private var hasClaudeSessions: Bool {
        sessionMonitor.instances.contains { $0.agentId == "claude" }
    }

    private var hasCodexSessions: Bool {
        sessionMonitor.instances.contains { $0.agentId == "codex" }
    }

    /// Sessions eligible for top activity icons (active/pending/waiting-for-input).
    private var activityIconSessions: [SessionState] {
        let now = Date()
        return sessionMonitor.instances
            .filter { session in
                session.phase == .processing
                    || session.phase == .compacting
                    || session.phase.isWaitingForApproval
                    || isSessionWaitingForInputVisible(session, now: now)
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Per-session icons for the closed notch, sorted by most recently active.
    /// Includes only activity-relevant sessions so idle/stale sessions don't appear.
    private var closedNotchIconSessions: [SessionState] {
        Array(activityIconSessions.prefix(4))
    }

    private var hasBothAgentTypes: Bool {
        hasClaudeSessions && hasCodexSessions
    }

    /// Use Codex branding only when Claude is not present.
    private var isCodexOnly: Bool {
        hasCodexSessions && !hasClaudeSessions
    }

    private var activeProcessingType: NotchActivityType {
        let activeSessions = sessionMonitor.instances.filter {
            $0.phase == .processing || $0.phase == .compacting || $0.phase.isWaitingForApproval
        }

        if activeSessions.contains(where: { $0.agentId == "claude" }) {
            return .claude
        }
        if activeSessions.contains(where: { $0.agentId == "codex" }) {
            return .codex
        }
        return isCodexOnly ? .codex : .claude
    }

    private var usesCodexBranding: Bool {
        if activityCoordinator.expandingActivity.show {
            return activityCoordinator.expandingActivity.type == .codex
        }
        return isCodexOnly
    }

    private func isSessionWaitingForInputVisible(_ session: SessionState, now: Date) -> Bool {
        guard session.phase == .waitingForInput else { return false }
        guard let enteredAt = waitingForInputTimestamps[session.stableId] else { return false }
        return now.timeIntervalSince(enteredAt) < waitingForInputDisplayDuration
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission indicator adds width on left side only (14pt icon + 2pt spacing)
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 16 : 0

        // Extra width for additional per-session icons beyond the first
        let extraIconWidth = CGFloat(max(0, closedNotchIconSessions.count - 1)) * 8

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude, .codex:
                let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20 + extraIconWidth
                return baseWidth + permissionIndicatorWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + extraIconWidth + permissionIndicatorWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + extraIconWidth
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            viewModel.closedExpansionWidth = expansionWidth
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onDisappear {
            waitingForInputSoundTask?.cancel()
            waitingForInputSoundTask = nil
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type != .none
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasWaitingForInput
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab + optional permission indicator (visible when processing, pending, or waiting for input)
            if showClosedActivity {
                HStack(spacing: 2) {
                    sessionStackedIcons()

                    // Permission indicator only (amber) - waiting for input shows checkmark on right
                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: claudeOrange)
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
                .frame(
                    width: viewModel.status == .opened
                        ? nil
                        : sideWidth + (hasPendingPermission ? 16 : 0) + CGFloat(max(0, closedNotchIconSessions.count - 1)) * 8
                )
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: black spacer (with optional bounce)
                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
            }

            // Right side - spinner when processing/pending, checkmark when waiting for input
            if showClosedActivity {
                if isProcessing || hasPendingPermission {
                    ProcessingSpinner(color: usesCodexBranding ? codexGreen : claudeOrange)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else if hasWaitingForInput {
                    // Checkmark for waiting-for-input on the right side
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    /// Renders the icon for a single session (with subtle black shadow outline).
    @ViewBuilder
    private func sessionIcon(_ session: SessionState) -> some View {
        let isSessionAnimating = session.phase == .processing
            || session.phase == .compacting
            || session.phase.isWaitingForApproval

        if session.agentId == "codex" {
            ZStack {
                CodexAnimationIcon(size: 15, isAnimating: isSessionAnimating, fallbackColor: .black)
                CodexAnimationIcon(size: 14, isAnimating: isSessionAnimating, fallbackColor: codexBlue)
            }
        } else {
            ZStack {
                ClaudeCrabIcon(size: 15, color: .black, animateLegs: isSessionAnimating)
                ClaudeCrabIcon(size: 14, animateLegs: isSessionAnimating)
            }
        }
    }

    /// Per-session icon stack: overlapping when closed, side-by-side when expanded.
    /// Sessions are ordered most-recently-active first.
    @ViewBuilder
    private func sessionStackedIcons() -> some View {
        let sessions = closedNotchIconSessions
        if viewModel.status == .opened {
            // Expanded: one icon per session, side by side
            HStack(spacing: 4) {
                ForEach(Array(zip(sessions.indices, sessions)), id: \.0) { index, session in
                    if index == 0 {
                        sessionIcon(session)
                            .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)
                    } else {
                        sessionIcon(session)
                    }
                }
            }
        } else {
            // Collapsed: stack icons with offsets — most recent on top at x=0, older ones behind/right
            ZStack {
                ForEach(Array(zip(sessions.indices, sessions)), id: \.0) { index, session in
                    if index == 0 {
                        sessionIcon(session)
                            .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)
                            .zIndex(Double(sessions.count))
                    } else {
                        sessionIcon(session)
                            .opacity(index == 1 ? 0.6 : 0.35)
                            .offset(x: CGFloat(index) * 8, y: 0)
                            .zIndex(Double(sessions.count - index))
                    }
                }
            }
        }
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                if hasBothAgentTypes {
                    HStack(spacing: 4) {
                        if isCodexOnly {
                            ZStack {
                                CodexAnimationIcon(size: 15, isAnimating: false, fallbackColor: .black)
                                CodexAnimationIcon(size: 14, isAnimating: false, fallbackColor: codexBlue)
                            }
                            ClaudeCrabIcon(size: 14)
                        } else {
                            ZStack {
                                ClaudeCrabIcon(size: 15, color: .black)
                                ClaudeCrabIcon(size: 14)
                            }
                            CodexAnimationIcon(size: 14, isAnimating: false, fallbackColor: codexBlue)
                        }
                    }
                    .padding(.leading, 8)
                } else if isCodexOnly {
                    CodexAnimationIcon(size: 14, isAnimating: false, fallbackColor: codexBlue)
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                        .padding(.leading, 8)
                } else {
                    ClaudeCrabIcon(size: 14)
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                        .padding(.leading, 8)
                }
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        // Keep the view model's expansion width in sync so click hit-testing covers the full pill
        viewModel.closedExpansionWidth = expansionWidth

        if isAnyProcessing || hasPendingPermission {
            // Show activity matching the active agent.
            activityCoordinator.showActivity(type: activeProcessingType)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed && viewModel.hasPhysicalNotch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
                waitingForInputSoundTask?.cancel()
                waitingForInputSoundTask = nil
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Prime baseline once to avoid alerting for sessions that were already waiting
        // when the UI first subscribed.
        if !hasPrimedSoundBaseline {
            for session in waitingForInputSessions {
                if let signature = assistantReplySignature(for: session) {
                    notifiedAssistantReplySignatureBySessionId[session.sessionId] = signature
                }
            }
            hasPrimedSoundBaseline = true
            previousWaitingForInputIds = currentIds
            return
        }

        let activeSessionIds = Set(instances.map(\.sessionId))
        notifiedAssistantReplySignatureBySessionId = notifiedAssistantReplySignatureBySessionId.filter { activeSessionIds.contains($0.key) }

        let sessionsEligibleForSound = waitingForInputSessions.filter { session in
            guard let signature = assistantReplySignature(for: session) else { return false }
            return notifiedAssistantReplySignatureBySessionId[session.sessionId] != signature
        }

        for session in sessionsEligibleForSound {
            if let signature = assistantReplySignature(for: session) {
                notifiedAssistantReplySignatureBySessionId[session.sessionId] = signature
            }
        }

        if !sessionsEligibleForSound.isEmpty {
            scheduleWaitingForInputSound(for: sessionsEligibleForSound)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    private func scheduleWaitingForInputSound(for sessions: [SessionState]) {
        waitingForInputSoundTask?.cancel()

        if AppSettings.hasCustomNotificationSoundSelection,
           AppSettings.notificationSound.soundName == nil {
            return
        }

        waitingForInputSoundTask = Task {
            guard !Task.isCancelled else { return }

            let sessionsToCheck = sessions.filter { $0.phase == .waitingForInput }
            guard !sessionsToCheck.isEmpty else { return }

            let shouldPlaySound = await shouldPlayNotificationSound(for: sessionsToCheck)
            guard shouldPlaySound else { return }

            let sound = notificationSound(for: sessionsToCheck)
            guard let soundName = sound.soundName else { return }

            await MainActor.run {
                _ = NSSound(named: soundName)?.play()
            }
        }
    }

    private func assistantReplySignature(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            guard case .assistant(let text) = item.type else { continue }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            return "item:\(item.id)"
        }

        guard session.lastMessageRole == "assistant",
              let lastMessage = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastMessage.isEmpty else {
            return nil
        }

        if let lastUserDate = session.lastUserMessageDate {
            return "conv:\(lastUserDate.timeIntervalSince1970):\(lastMessage)"
        }
        return "conv:\(lastMessage)"
    }

    private func notificationSound(for sessions: [SessionState]) -> NotificationSound {
        if AppSettings.hasCustomNotificationSoundSelection {
            return AppSettings.notificationSound
        }

        if sessions.contains(where: { $0.agentId == "codex" }) {
            return AppSettings.notificationSound(for: "codex")
        }
        if let firstSession = sessions.first {
            return AppSettings.notificationSound(for: firstSession.agentId)
        }
        return AppSettings.notificationSound(for: "claude")
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
