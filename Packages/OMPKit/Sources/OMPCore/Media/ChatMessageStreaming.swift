import Foundation

public extension ChatMessage {
    /// Folds one stream event into the message in place. Tool call deltas are
    /// matched by their wire index onto the ordered list of tool-call parts.
    mutating func apply(_ event: StreamEvent) {
        switch event {
        case .textDelta(let delta):
            self = appendingText(delta)
            if status != .streaming { status = .streaming }
        case .thinkingDelta(let delta):
            self = appendingThinking(delta)
            if status != .streaming { status = .streaming }
        case .thinkingSeal(let seal):
            // A part of its own: the next thinking delta starts a new block
            // instead of growing the text this seal was issued for.
            parts.append(.thinkingSeal(seal))
        case .toolCallDelta(let index, let id, let name, let argumentsDelta):
            applyToolDelta(index: index, id: id, name: name, argumentsDelta: argumentsDelta)
        case .usage(let value):
            usage = value
        case .finished:
            break
        }
    }

    private mutating func applyToolDelta(index: Int, id: String?, name: String?, argumentsDelta: String?) {
        var callPositions: [Int] = []
        for (position, part) in parts.enumerated() {
            if case .toolCall = part { callPositions.append(position) }
        }

        if index < callPositions.count {
            let position = callPositions[index]
            guard case .toolCall(var call) = parts[position] else { return }
            if let id, !id.isEmpty { call.id = id }
            if let name, !name.isEmpty { call.name = name }
            if let argumentsDelta { call.argumentsJSON += argumentsDelta }
            parts[position] = .toolCall(call)
            return
        }

        while callPositions.count < index {
            parts.append(.toolCall(ToolCall(id: "pending-\(callPositions.count)", name: "", argumentsJSON: "")))
            callPositions.append(parts.count - 1)
        }
        parts.append(.toolCall(ToolCall(
            id: id ?? "call-\(index)",
            name: name ?? "",
            argumentsJSON: argumentsDelta ?? ""
        )))
    }
}
