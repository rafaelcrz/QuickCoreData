import Foundation
@preconcurrency import CoreData

protocol CoreDataManagerProtocol {
    var viewContext: NSManagedObjectContext { get }
    
    func newTaskContext() -> NSManagedObjectContext
    
    func delete(objectID id: NSManagedObjectID) async throws
    func update(objectID id: NSManagedObjectID, _ block: @escaping @Sendable (NSManagedObject, NSManagedObjectContext) -> Void) async throws
    func save(_ block: @escaping @Sendable (NSManagedObjectContext) -> NSManagedObject) async throws -> NSManagedObjectID
    func fetch<T: NSManagedObject>(fetchRequest: NSFetchRequest<T>) async throws -> [T]
}

public class CoreDataManager: CoreDataManagerProtocol {
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
    
    public func save(_ block: @escaping @Sendable (NSManagedObjectContext) -> NSManagedObject) async throws -> NSManagedObjectID {
        let context: NSManagedObjectContext = newTaskContext()
        let work = block
        
        return try await context.perform {
            do {
                let object = work(context)
                let objectID = object.objectID
                guard context.hasChanges else {
                    return objectID
                }
                
                try context.save()
                return objectID
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
                try context.save()
                
                object.objectWillChange.send()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
    
    func delete(objectID id: NSManagedObjectID) async throws {
        let context: NSManagedObjectContext = newTaskContext()
        
        try await context.perform {
            let object: NSManagedObject = context.object(with: id)
            context.delete(object)
            do {
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
