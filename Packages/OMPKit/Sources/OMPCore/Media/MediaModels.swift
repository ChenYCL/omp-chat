import Foundation

public struct ImageGenerationRequest: Sendable {
    public var modelID: String
    public var prompt: String
    public var size: String?
    public var count: Int

    public init(modelID: String, prompt: String, size: String? = nil, count: Int = 1) {
        self.modelID = modelID
        self.prompt = prompt
        self.size = size
        self.count = count
    }
}

public struct ImageEditRequest: Sendable {
    public var modelID: String
    public var prompt: String
    public var source: MediaRef
    public var mask: MediaRef?
    public var size: String?

    public init(modelID: String, prompt: String, source: MediaRef, mask: MediaRef? = nil, size: String? = nil) {
        self.modelID = modelID
        self.prompt = prompt
        self.source = source
        self.mask = mask
        self.size = size
    }
}

public struct VideoGenerationRequest: Sendable {
    public var modelID: String
    public var prompt: String
    public var sourceImage: MediaRef?
    public var durationSeconds: Int?
    public var aspectRatio: String?

    public init(modelID: String, prompt: String, sourceImage: MediaRef? = nil, durationSeconds: Int? = nil, aspectRatio: String? = nil) {
        self.modelID = modelID
        self.prompt = prompt
        self.sourceImage = sourceImage
        self.durationSeconds = durationSeconds
        self.aspectRatio = aspectRatio
    }
}

public enum MediaJobEvent: Sendable {
    case progress(Double)
    case status(String)
    case completed(MediaRef)
}
