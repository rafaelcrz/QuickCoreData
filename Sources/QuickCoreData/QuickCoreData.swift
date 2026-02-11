import Foundation
@preconcurrency import CoreData

public protocol CoreDataManagerProtocol {
    var viewContext: NSManagedObjectContext { get }
    
    func newTaskContext() -> NSManagedObjectContext
    
    func delete(objectID id: NSManagedObjectID) async throws
    func batchDelete<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws
    func update(objectID id: NSManagedObjectID, _ block: @escaping @Sendable (NSManagedObject, NSManagedObjectContext) -> Void) async throws
    func saveV2(_ block: @escaping @Sendable (NSManagedObject, NSManagedObjectContext) -> Void) async throws
    
    func save(_ block: @escaping @Sendable (NSManagedObjectContext) -> NSManagedObject) async throws -> NSManagedObject
    func fetch<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws -> [T]
}

public final class CoreDataManager: CoreDataManagerProtocol {
    public let viewContext: NSManagedObjectContext
    
    private let container: NSPersistentCloudKitContainer
    
    public init(container: NSPersistentCloudKitContainer) {
        self.container = container
        self.viewContext = container.viewContext
    }
    
    // MARK: - Public Functions
    public func newTaskContext() -> NSManagedObjectContext {
        let taskContext: NSManagedObjectContext = container.newBackgroundContext()
        // Use a concurrency-safe merge policy instance rather than the global variable
        taskContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
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
        // Capture the context by value to avoid capturing `self` in the @Sendable closure
        let context = viewContext
        return try await context.perform {
            if fetchRequest.predicate == nil {
                fetchRequest.predicate = NSPredicate(value: true)
            }
            return try context.fetch(fetchRequest)
        }
    }
}
