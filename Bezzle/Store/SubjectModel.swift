import Foundation

/// The learned subject matte, loaded the first time a background is taken away and kept while the
/// app runs. It comes with the app: BiRefNet.mlpackage, beside `SubjectMatte`, compiled when the app
/// is built (Scripts/subject-matte makes it). BEZZLE_MATTE_MODEL takes another; tests run without
/// one unless given it.
///
/// Without it, pictures are still cut out, by `CutoutMaker`'s own way, less fine round hair.
final class SubjectModel {
    static let shared = SubjectModel()

    private var loading: Task<SubjectMatte?, Never>?

    private init() {}

    /// The matte, loaded first if need be; nil when there is none.
    func matte() async -> SubjectMatte? {
        let task = loading ?? Task { await Self.load() }
        loading = task
        return await task.value
    }

    private nonisolated static func load() async -> SubjectMatte? {
        let environment = ProcessInfo.processInfo.environment
        let url = if let path = environment["BEZZLE_MATTE_MODEL"] {
            URL(fileURLWithPath: path)
        } else if environment["XCTestConfigurationFilePath"] == nil {
            Bundle.main.url(forResource: "BiRefNet", withExtension: "mlmodelc")
        } else {
            URL?.none
        }
        guard let url else { return nil }
        do {
            return try await SubjectMatte(contentsOf: url)
        } catch {
            NSLog("Bezzle could not load the subject matte: %@", String(describing: error))
            return nil
        }
    }
}
