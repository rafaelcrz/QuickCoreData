import Foundation
@preconcurrency import CoreData

/// In-memory container and model for QuickCoreData tests. Uses a minimal programmatic model (entity "TestItem", attribute "title") so the package has no dependency on an app .xcdatamodeld.
enum TestContainerFactory {
    static let testEntityName = "TestItem"

    static func makeModel() -> NSManagedObjectModel {
        let titleAttr = NSAttributeDescription()
        titleAttr.name = "title"
        titleAttr.attributeType = .stringAttributeType
        titleAttr.isOptional = true

        let entity = NSEntityDescription()
        entity.name = testEntityName
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = [titleAttr]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    /// In-memory NSPersistentCloudKitContainer for tests. No CloudKit sync; store is volatile.
    static func makeInMemoryContainer() -> NSPersistentCloudKitContainer {
        let model = makeModel()
        let container = NSPersistentCloudKitContainer(name: "Test", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            fatalError("In-memory store failed to load: \(loadError)")
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }

    /// SQLite container in a temporary directory. Use for tests that require batch operations (NSBatchDeleteRequest is not supported on in-memory store).
    /// Caller should remove the store URL after the test (e.g. in tearDown).
    static func makeTemporarySQLiteContainer() -> (container: NSPersistentCloudKitContainer, storeURL: URL) {
        let model = makeModel()
        let container = NSPersistentCloudKitContainer(name: "Test", managedObjectModel: model)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickCoreDataTests-\(UUID().uuidString).sqlite")
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            fatalError("SQLite store failed to load: \(loadError)")
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return (container, storeURL)
    }
}
