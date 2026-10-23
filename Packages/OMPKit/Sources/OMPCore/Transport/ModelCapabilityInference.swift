import Foundation

/// Heuristic capability mapping from model identifiers, used when relays do not
/// publish structured capability metadata.
public enum ModelCapabilityInference {
    public static func infer(modelID: String, raw: [String: String] = [:]) -> ModelCapabilities {
        let id = modelID.lowercased()
        var capabilities = ModelCapabilities()

        capabilities.thinking = containsAny(id, [
            "thinking", "reason", "o1", "o3", "o4", "r1", "qwq", "deepseek-v4", "deepseek-r", "sonnet-4", "opus-4", "gemini-2.5",
        ])
        capabilities.vision = containsAny(id, [
            "vision", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini", "qwen-vl", "llava", "glm-4v", "internvl",
        ])
        capabilities.tools = capabilities.chat && !containsAny(id, ["embed", "rerank", "tts", "whisper"])
        capabilities.imageGeneration = containsAny(id, [
            "dall-e", "gpt-image", "imagen", "flux", "stable-diffusion", "sdxl", "seedream", "kolors", "midjourney", "cogview",
        ])
        capabilities.imageEditing = capabilities.imageGeneration
        capabilities.videoGeneration = containsAny(id, [
            "sora", "veo", "kling", "runway", "pika", "seedance", "hailuo", "vidu", "cogvideo", "wan2",
        ])
        if capabilities.imageGeneration || capabilities.videoGeneration {
            capabilities.chat = containsAny(id, ["gpt-image", "gpt-5"])
        }
        if let declared = raw["modality"], declared.contains("image") {
            capabilities.imageGeneration = true
        }
        return capabilities
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

public enum ModelLimitInference {
    public static func infer(modelID: String) -> ModelLimits {
        let id = modelID.lowercased()
        if id.contains("claude") { return ModelLimits(contextWindow: 200_000, maxOutputTokens: 32_000) }
        if id.contains("gemini") { return ModelLimits(contextWindow: 1_000_000, maxOutputTokens: 65_536) }
        if id.contains("gpt-4.1") { return ModelLimits(contextWindow: 1_047_576, maxOutputTokens: 32_768) }
        if id.contains("gpt-5") || id.contains("o3") || id.contains("o4") {
            return ModelLimits(contextWindow: 400_000, maxOutputTokens: 128_000)
        }
        if id.contains("deepseek") { return ModelLimits(contextWindow: 128_000, maxOutputTokens: 16_384) }
        if id.contains("qwen") { return ModelLimits(contextWindow: 131_072, maxOutputTokens: 16_384) }
        return ModelLimits(contextWindow: 128_000, maxOutputTokens: 8_192)
    }
}
