import Foundation
import MacVisioInfrastructure

/// Package workers own frozen values. Native drafts are installed only when
/// their window and exact input are still current; Save As never overwrites input.
enum StencilPackageJobs {
    @discardableResult
    static func load(sourceURL: URL, input: LifecycleJobInput, owner: LifecycleJobOwner,
                     accepts: @escaping (LifecycleJobInput) -> Bool,
                     progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
                     completion: @escaping (Result<StencilPackageSnapshot, Error>) -> Void) throws -> LifecycleJobHandle {
        try submit(input: input, owner: owner, accepts: accepts, progress: progress, work: { context in
            context.progress("Reading custom stencil")
            return try StencilPackageEditing.read(from: sourceURL)
        }, completion: completion)
    }

    @discardableResult
    static func edit(_ edit: StencilPackageEdit, snapshot: StencilPackageSnapshot,
                     input: LifecycleJobInput, owner: LifecycleJobOwner,
                     accepts: @escaping (LifecycleJobInput) -> Bool,
                     progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
                     completion: @escaping (Result<StencilPackageSnapshot, Error>) -> Void) throws -> LifecycleJobHandle {
        try submit(input: input, owner: owner, accepts: accepts, progress: progress, work: { context in
            context.progress("Preparing stencil edit")
            return try StencilPackageEditing.applying(edit, to: snapshot)
        }, completion: completion)
    }

    @discardableResult
    static func saveCopy(_ snapshot: StencilPackageSnapshot, to destination: URL,
                         input: LifecycleJobInput, owner: LifecycleJobOwner,
                         accepts: @escaping (LifecycleJobInput) -> Bool,
                         progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
                         completion: @escaping (Result<URL, Error>) -> Void) throws -> LifecycleJobHandle {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "vssx" else {
            throw DiagramError.invalid("Save the edited copy with a .vssx extension.")
        }
        return try submit(input: input, owner: owner, accepts: accepts, progress: progress, work: { context in
            try checkAcceptance(input, owner: owner, accepts: accepts)
            context.progress("Writing edited stencil copy")
            try AtomicJobOutput.write(to: destination, input: snapshot.sourceURL, cancellation: context.cancellation) { staging in
                try VisioPackage.write(snapshot.parts, to: staging)
                try context.checkpoint()
                try checkAcceptance(input, owner: owner, accepts: accepts)
            }
            return destination
        }, completion: completion)
    }

    @discardableResult
    private static func submit<Output>(input: LifecycleJobInput, owner: LifecycleJobOwner,
                                       accepts: @escaping (LifecycleJobInput) -> Bool,
                                       progress: @escaping (LifecycleJobProgress) -> Void,
                                       work: @escaping (LifecycleJobContext) throws -> Output,
                                       completion: @escaping (Result<Output, Error>) -> Void) throws -> LifecycleJobHandle {
        try checkAcceptance(input, owner: owner, accepts: accepts)
        let id = UUID()
        let handle = try LifecycleJobService.shared.submit(id: id, kind: .library, input: input,
            accepts: { owner.isActive && $0.ownerID == owner.id && accepts($0) }, progress: progress,
            work: work, completion: { result in owner.finish(id); completion(result) })
        owner.track(handle)
        return handle
    }
    private static func checkAcceptance(_ input: LifecycleJobInput, owner: LifecycleJobOwner,
                                        accepts: @escaping (LifecycleJobInput) -> Bool) throws {
        let check = { owner.isActive && input.ownerID == owner.id && accepts(input) }
        let accepted = Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        guard accepted else { throw LifecycleJobError.staleInput }
    }
}
