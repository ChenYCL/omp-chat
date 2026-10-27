import SwiftUI
import OMPCore
import OMPDesign

#if os(iOS)
// MARK: - RemoteScreen
//
// 远程 tab 的整页视图（不再是 sheet）：
// - 未配对：配对表单（host / port / token + 连接按钮 + 报错行）。
// - 已配对：主机会话列表（标题 / 项目 / 相对时间 / 流式黄点 / rev 胶囊），右上「重新配对」。
// - 点行进入 RemoteConversationScreen（保留原实现）。

public struct RemoteScreen: View {
    @Environment(ChatAppModel.self) private var model
    @Environment(RemoteSession.self) private var remoteSession
    @State private var hostField = ""
    @State private var portField = "8790"
    @State private var tokenField = ""
    @State private var status: Status = .idle
    @State private var hostName = ""
    @State private var snapshot: RelaySnapshot?
    @State private var selectedItem: ConversationSheetItem?
    @State private var client: RemoteRelayClient?
    @State private var revisionsTask: Task<Void, Never>?
    /// Connection mode: same Wi-Fi (IP + token) or cross-network (room code).
    @State private var mode: ConnectMode = .room
    @State private var hubClient: RelayHubClient?
    @State private var persistedRoom = ""
    @State private var roomField = ""
    @State private var hubField = ""

    private enum ConnectMode: String, CaseIterable {
        case room = "房间码"
        case lan = "局域网"
    }

    public init() {}

    private enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    /// Full-screen cover needs an Identifiable item; the relay models are
    /// plain Codable structs, so wrap the conversation id instead.
    private struct ConversationSheetItem: Identifiable {
        let id: String
    }

    public var body: some View {
        Group {
            switch status {
            case .idle, .connecting, .failed:
                pairingForm
            case .connected:
                hostBrowser
            }
        }
        .background(Color.ompCanvas)
        .onAppear {
            loadSavedConnection()
            consumeRequestedDevice()
        }
        .onChange(of: remoteSession.requestedDevice) { _, _ in consumeRequestedDevice() }
        // No disconnect on disappear: the 主机 tab, the drawer and CLI 会话 all
        // drive the Mac through RemoteSession, so switching tabs must keep the
        // pairing alive. Only the explicit 断开 button tears it down.
        .fullScreenCover(item: $selectedItem) { item in
            NavigationStack {
                RemoteConsoleScreen(
                    conversationID: item.id,
                    client: activeSink,
                    hostName: hostName,
                    conversationProvider: currentConversation,
                    approvals: { snapshot?.approvals ?? [] },
                    commandFailures: { snapshot?.commandFailures ?? [] },
                    onDismiss: { selectedItem = nil }
                )
                .environment(model)
            }
        }
    }

    // MARK: Pairing Form

    private var pairingForm: some View {
        VStack(spacing: 0) {
            headerBar(title: "远程") { EmptyView() }

            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接你的 Mac")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ompText)
                    Text("镜像同一份会话，手机可直接继续对话")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 14)

            Picker("连接方式", selection: $mode) {
                ForEach(ConnectMode.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .accessibilityIdentifier("remote.mode")

            VStack(alignment: .leading, spacing: 14) {
                if mode == .room {
                    field("房间码", text: $roomField, placeholder: "Mac 设置页里的 6 位码", autocapitalization: true, identifier: "remote.room")
                    field("中继地址", text: $hubField, placeholder: "https://hub.example.com", keyboard: .URL, autocapitalization: false, identifier: "remote.hub")
                    Text("两端都连中继，用房间码相遇——不需要同一 Wi-Fi，也不需要公网 IP。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                } else {
                    field("主机地址", text: $hostField, placeholder: "例如 192.168.1.8 或 macbook.local", autocapitalization: false, identifier: "remote.host")
                    HStack(alignment: .top, spacing: 12) {
                        field("端口", text: $portField, placeholder: "8790", keyboard: .numberPad, identifier: "remote.port")
                            .frame(width: 110)
                        field("配对 Token", text: $tokenField, placeholder: "Mac 端生成的 UUID", autocapitalization: false, identifier: "remote.token")
                    }
                }
            }
            .padding(18)
            .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)

            if case .failed(let message) = status {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
            }

            Button(action: connect) {
                HStack(spacing: 6) {
                    if status == .connecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.ompInverseText)
                    }
                    Text(status == .connecting ? "正在连接…" : "连接")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.ompInverseText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(canConnect ? Color.ompPrimarySolid : Color.ompPrimarySolid.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canConnect)
            .accessibilityIdentifier("remote.connect")
            .accessibilityLabel("连接")
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Host Browser (conversation list)

    private var hostBrowser: some View {
        VStack(spacing: 0) {
            headerBar(title: "远程") { reconnectButton }
            hostBanner
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let snapshot, snapshot.conversations.isEmpty {
                        Text("Mac 上暂无会话")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ompTextTertiary)
                            .padding(.top, 48)
                    }
                    if let snapshot {
                        let waiting = Set(snapshot.approvals?.map(\.conversationID) ?? [])
                        ForEach(sorted(snapshot.conversations), id: \.id) { conversation in
                            Button {
                                selectedItem = ConversationSheetItem(id: conversation.id)
                            } label: {
                                RemoteConversationRow(
                                    conversation: conversation,
                                    waitingApproval: waiting.contains(conversation.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    /// Connected host strip: name + revision capsule.
    private var hostBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 12))
                .foregroundStyle(Color.ompTextSecondary)
            Text(hostName.isEmpty ? "已连接" : hostName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ompText)
            Spacer()
            if let snapshot {
                Text("rev \(snapshot.rev)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.ompTextTertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.ompFill, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.ompCard)
    }

    private var reconnectButton: some View {
        Button {
            snapshot = nil
            selectedItem = nil
            disconnect()
        } label: {
            Text("重新配对")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ompText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.ompFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Resolved fresh on every render, so bubbles track the latest snapshot.
    private func currentConversation(id: String) -> RelayConversation? {
        snapshot?.conversations.first { $0.id == id }
    }

    private func sorted(_ conversations: [RelayConversation]) -> [RelayConversation] {
        conversations.sorted {
            if $0.isStreaming != $1.isStreaming { return $0.isStreaming }
            return $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: Top bar (44pt, matches the shell chrome)

    private func headerBar(
        title: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ompText)
            Spacer()
            trailing()
                .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    // MARK: Connection actions

    private func field(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        keyboard: UIKeyboardType = .default,
        autocapitalization: Bool = true,
        identifier: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ompTextTertiary)
            TextField(placeholder, text: text)
                .accessibilityIdentifier(identifier ?? placeholder)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization ? .sentences : .never)
                .autocorrectionDisabled(!autocapitalization)
                .font(.system(size: 14.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var canConnect: Bool {
        switch mode {
        case .room:
            return RelayHubClient.isValidRoomCode(roomField)
                && !hubField.trimmingCharacters(in: .whitespaces).isEmpty
        case .lan:
            return !hostField.trimmingCharacters(in: .whitespaces).isEmpty
                && !tokenField.trimmingCharacters(in: .whitespaces).isEmpty
                && UInt16(portField) != nil
        }
    }

    private var trimmedRoom: String {
        roomField.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private func connect() {
        if mode == .room {
            connectViaHub()
            return
        }
        let host = hostField.trimmingCharacters(in: .whitespaces)
        let token = tokenField.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(portField) else { return }
        status = .connecting
        Task {
            let client = RemoteRelayClient(host: host, port: port, token: token)
            do {
                let pair = try await client.pair()
                self.client = client
                remoteSession.attach(sink: client, hostName: pair.host, mode: .lan)
                hostName = pair.host
                snapshot = try await client.snapshot()
                remoteSession.noteSnapshot()
                status = .connected
                persistConnection(host: host, port: port, token: token)
                revisionsTask = Task { await watchRevisions() }
                DiagnosticsCenter.shared.record("relay", .info, "pairing succeeded",
                    fields: ["host": host])
            } catch {
                self.client = nil
                status = .failed(describe(error))
                DiagnosticsCenter.shared.record("relay", .error, "pairing failed",
                    fields: ["error": describe(error)])
            }
        }
    }


    private func connectViaHub() {
        let room = trimmedRoom
        let raw = hubField.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: raw), RelayHubClient.isValidRoomCode(room) else {
            status = .failed("房间码或中继地址无效")
            return
        }
        status = .connecting
        Task {
            let hub = RelayHubClient(hubURL: url, roomCode: room)
            do {
                let first = try await hub.connectClient()
                hubClient = hub
                remoteSession.attach(sink: hub, hostName: first.host, mode: .room)
                hostName = first.host
                snapshot = first
                remoteSession.noteSnapshot()
                persistedRoom = room
                status = .connected
                persistRoom(room: room, hub: raw)
                revisionsTask = Task { await watchHubRevisions() }
                DiagnosticsCenter.shared.record("relay", .info, "pairing succeeded",
                    fields: ["room": DiagnosticsMask.hint(room)])
            } catch {
                hubClient = nil
                status = .failed(describe(error))
                DiagnosticsCenter.shared.record("relay", .error, "pairing failed",
                    fields: ["error": describe(error)])
            }
        }
    }


    private func watchHubRevisions() async {
        guard let hub = hubClient else { return }
        for await rev in hub.revisions() {
            guard !Task.isCancelled else { return }
            if let current = snapshot, rev <= current.rev { continue }
            if let fresh = try? await hub.snapshot() {
                snapshot = fresh
                remoteSession.noteSnapshot()
                hostName = fresh.host
            }
        }
    }

    private func persistRoom(room: String, hub: String) {
        var settings = model.settings
        remember(
            PairedDevice(name: hostName, transport: .room, hubURL: hub, roomCode: room),
            in: &settings
        )
        Task { await model.saveSettings(settings) }
    }

    /// Adds (or refreshes) the Mac in the saved list and marks it active. One
    /// settings mutation per pairing, so two saves never race on a stale copy.
    private func remember(_ device: PairedDevice, in settings: inout AppSettings) {
        settings.pairedDevices.upsert(device)
        remoteSession.activeDeviceID = settings.pairedDevices
            .first { $0.endpointKey == device.endpointKey }?.id
    }

    /// Reconnects to a Mac picked in the 可控设备 list.
    private func consumeRequestedDevice() {
        guard let device = remoteSession.requestedDevice else { return }
        remoteSession.requestedDevice = nil
        disconnect()
        switch device.transport {
        case .lan:
            mode = .lan
            hostField = device.host
            portField = String(device.port)
            tokenField = device.token
        case .room:
            mode = .room
            roomField = device.roomCode
            hubField = device.hubURL
        }
        connect()
    }

    /// Whichever transport is live (LAN or hub) for the remote screens.
    private var activeSink: (any RelayCommandSink)? {
        if let hubClient { return hubClient }
        return client
    }

    private func loadSavedConnection() {
        // Prefill from the saved Macs (vault-backed), newest first; the old
        // single-connection settings fields are only read once, for migration.
        let devices = model.settings.pairedDevices
        let fresh = roomField.isEmpty && hostField.isEmpty
        if roomField.isEmpty, let room = devices.first(where: { $0.transport == .room }) {
            roomField = room.roomCode
            hubField = room.hubURL
        }
        if hostField.isEmpty, let lan = devices.first(where: { $0.transport == .lan }) {
            hostField = lan.host
            portField = String(lan.port)
            tokenField = lan.token
        }
        if fresh, let newest = devices.first {
            mode = newest.transport == .room ? .room : .lan
        }
    }

    private func persistConnection(host: String, port: UInt16, token: String) {
        var settings = model.settings
        remember(
            PairedDevice(name: hostName, transport: .lan, host: host, port: port, token: token),
            in: &settings
        )
        Task { await model.saveSettings(settings) }
    }

    private func disconnect() {
        revisionsTask?.cancel()
        revisionsTask = nil
        client = nil
        hubClient?.stopHost()
        hubClient = nil
        remoteSession.detach()
        if status == .connected { status = .idle }
    }

    /// Consume the SSE revision stream while the tab is visible; the stream in
    /// `revisions()` reconnects with backoff on its own, this task just refetches
    /// the full snapshot each time the host announces a change.
    private func watchRevisions() async {
        guard let client else { return }
        for await _ in client.revisions() {
            guard status == .connected else { return }
            if let fresh = try? await client.snapshot() {
                snapshot = fresh
                remoteSession.noteSnapshot()
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if let relay = error as? RelayClientError { return relay.errorDescription ?? String(describing: relay) }
        return error.localizedDescription
    }
}

// MARK: - Conversation Row

struct RemoteConversationRow: View {
    let conversation: RelayConversation
    /// The Mac's agent in this conversation is waiting on an approval card.
    var waitingApproval = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.title.isEmpty ? "未命名会话" : conversation.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ompText)
                        .lineLimit(1)
                    if waitingApproval {
                        approvalBadge
                    } else if conversation.isStreaming {
                        streamingBadge
                    }
                }
                HStack(spacing: 6) {
                    if let project = conversation.project, !project.isEmpty {
                        Text(project)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text("·")
                            .foregroundStyle(Color.ompTextTertiary)
                    }
                    Text("\(conversation.messages.count) 条")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                    Text("·")
                        .foregroundStyle(Color.ompTextTertiary)
                    Text(RelativeDateTimeFormatter.ompRelay.string(for: conversation.updatedAt) ?? "")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.ompTextTertiary)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ompTextTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.ompCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var streamingBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.yellow).frame(width: 5, height: 5)
            Text("生成中")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Color.yellow)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.yellow.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    /// Same capsule as 生成中, in the approval card's orange.
    private var approvalBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 8, weight: .bold))
            Text("待批准")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityIdentifier("remote.row.waitingApproval")
    }
}

// MARK: - Helpers

private extension RelativeDateTimeFormatter {
    static let ompRelay: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
#endif
