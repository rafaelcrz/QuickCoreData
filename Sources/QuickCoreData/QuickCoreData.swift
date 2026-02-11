import Foundation
@preconcurrency import CoreData

public protocol CoreDataManagerProtocol {
    var viewContext: NSManagedObjectContext { get }
    
    /// Creates a background context. Pass `name` and `transactionAuthor` so the app can identify this context in Instruments and in persistent history (e.g. filter by author).
    func newTaskContext(name: String?, transactionAuthor: String?) -> NSManagedObjectContext
    
    func delete(objectID id: NSManagedObjectID) async throws
    func batchDelete<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws
    func update(objectID id: NSManagedObjectID, _ block: @escaping @Sendable (NSManagedObject, NSManagedObjectContext) -> Void) async throws
    func saveV2(_ block: @escaping @Sendable (NSManagedObject, NSManagedObjectContext) -> Void) async throws
    
    func save(_ block: @escaping @Sendable (NSManagedObjectContext) -> NSManagedObject) async throws -> NSManagedObject
    /// Use for light UI-bound fetches (runs on view context / main thread). For heavy work, use `fetchInBackground` and then resolve object IDs on the view context.
    func fetch<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws -> [T]
    /// Runs on a background context; returns object IDs. Resolve on view context with `object(with:)` or `getObject(with:)` for UI. Prefer over `fetch` for large result sets.
    func fetchInBackground<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws -> [NSManagedObjectID]
}

extension CoreDataManagerProtocol {
    /// Convenience: creates a task context without name/author. Prefer `newTaskContext(name:transactionAuthor:)` so the app can identify the context in Instruments and persistent history.
    public func newTaskContext() -> NSManagedObjectContext {
        newTaskContext(name: nil, transactionAuthor: nil)
    }
}

public final class CoreDataManager: CoreDataManagerProtocol {
    public let viewContext: NSManagedObjectContext
    
    private let container: NSPersistentCloudKitContainer
    
    public init(container: NSPersistentCloudKitContainer) {
        self.container = container
        self.viewContext = container.viewContext
    }
    
    // MARK: - Public Functions
    public func newTaskContext(name: String?, transactionAuthor: String?) -> NSManagedObjectContext {
        let taskContext: NSManagedObjectContext = container.newBackgroundContext()
        if let name { taskContext.name = name }
        if let transactionAuthor { taskContext.transactionAuthor = transactionAuthor }
        // Store wins on conflict; required for constraints and CloudKit sync (per Core Data best practices)
        taskContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)
        taskContext.automaticallyMergesChangesFromParent = true
        return taskContext
    }
    
    public func saveV2(_ block: @escaping (NSManagedObject, NSManagedObjectContext) -> Void) async throws {
//        let context: NSManagedObjectContext = newTaskContext()
//        let work = block
//        
//        return try await context.perform {
//            do {
//                let object = work(context)
//                guard context.hasChanges else {
//                    return object
//                }
//                
//                try context.save()
//                object.objectWillChange.send()
//            } catch {
//                context.rollback()
//                throw error
//            }
//        }
    }
    
    public func save(_ block: @escaping @Sendable (NSManagedObjectContext) -> NSManagedObject) async throws -> NSManagedObject {
        let context: NSManagedObjectContext = newTaskContext()
        let work = block
        
        return try await context.perform {
            do {
                let object = work(context)
                guard context.hasChanges else {
                    return object
                }
                
                try context.save()
                object.objectWillChange.send()
                return object
            } catch {
                context.rollback()
                throw error
            }
        }
    }
    
    public func update(objectID id: NSManagedObjectID, _ block: @escaping @Sendable (NSManagedObject, NSManagedObjectContext) -> Void) async throws {
        let context: NSManagedObjectContext = newTaskContext()
        let work = block
        
        try await context.perform {
            let object: NSManagedObject = context.object(with: id)
            
            do {
                work(object, context)
                guard context.hasChanges else { return }
                try context.save()
                object.objectWillChange.send()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
    
    public func delete(objectID id: NSManagedObjectID) async throws {
        let context: NSManagedObjectContext = newTaskContext()
        
        try await context.perform {
            let object: NSManagedObject = context.object(with: id)
            context.delete(object)
            do {
                guard context.hasChanges else { return }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
    
    public func batchDelete<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws {
        let context: NSManagedObjectContext = newTaskContext()
        
        try await context.perform { [weak self] in
            guard let self, let entityName = fetchRequest.entityName else { return }
            // Convert to NSFetchRequestResult for batch delete
            let batchFetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
            batchFetchRequest.predicate = fetchRequest.predicate
            
            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: batchFetchRequest)
            batchDeleteRequest.resultType = .resultTypeObjectIDs
            
            do {
                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                
                // Merge changes to update the view context
                if let objectIDArray = result?.result as? [NSManagedObjectID], !objectIDArray.isEmpty {
                    let changes = [NSDeletedObjectsKey: objectIDArray]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context, self.viewContext])
                }
                
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
    
    public func fetch<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws -> [T] {
        let context = viewContext
        let request = Self.resolvedRequest(from: fetchRequest)
        return try await context.perform {
            try context.fetch(request)
        }
    }

    public func fetchInBackground<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws -> [NSManagedObjectID] {
        let context = newTaskContext()
        let request = Self.resolvedRequest(from: fetchRequest)
        return try await context.perform {
            let objects: [T] = try context.fetch(request)
            return objects.map(\.objectID)
        }
    }

    /// Builds a request copy with predicate defaulting to true when nil, so the original request is never mutated.
    private static func resolvedRequest<T: NSManagedObject>(from request: NSFetchRequest<T>) -> NSFetchRequest<T> {
        let resolved = NSFetchRequest<T>()
        resolved.entity = request.entity
        resolved.predicate = request.predicate ?? NSPredicate(value: true)
        resolved.sortDescriptors = request.sortDescriptors
        resolved.fetchLimit = request.fetchLimit
        resolved.fetchBatchSize = request.fetchBatchSize
        resolved.propertiesToFetch = request.propertiesToFetch
        resolved.relationshipKeyPathsForPrefetching = request.relationshipKeyPathsForPrefetching
        return resolved
    }
}
