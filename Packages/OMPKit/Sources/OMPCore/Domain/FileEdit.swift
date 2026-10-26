import Foundation

/// Writing an edited file back to disk. Extracted so the rule is testable
/// without a window: the side panel and the phone's file viewer both edit files,
/// and both must refuse to write something they only partially loaded.
public enum FileEdit {
    public enum Failure: Error, Equatable {
        /// The file was truncated when read; saving would drop the rest.
        case truncated
        case writeFailed(String)
    }

    /// Replaces `url`'s contents with `text`. `truncated` says whether the
    /// editor only ever saw the first part of the file.
    public static func write(_ text: String, to url: URL, truncated: Bool) throws {
        guard !truncated else { throw Failure.truncated }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
