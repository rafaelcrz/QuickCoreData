import Foundation
@preconcurrency import CoreData
import XCTest
@testable import QuickCoreData

final class CoreDataManagerTests: XCTestCase {
    var container: NSPersistentCloudKitContainer!
    var manager: CoreDataManager!
    private var saveObserver: NSObjectProtocol?

    override func setUp() async throws {
        try await super.setUp()
        container = TestContainerFactory.makeInMemoryContainer()
        manager = CoreDataManager(container: container)
        // Merge background context saves into view context so fetch() sees persisted data
        let viewContext = manager.viewContext
        saveObserver = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
            guard let savedContext = notification.object as? NSManagedObjectContext,
                  savedContext !== viewContext else { return }
            viewContext.perform {
                viewContext.mergeChanges(fromContextDidSave: notification)
            }
        }
    }

    override func tearDown() async throws {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        manager = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Save (conditional hasChanges)

    func testSave_createsObjectAndPersists() async throws {
        let object = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("Hello", forKey: "title")
            return item
        }
        XCTAssertEqual(object.value(forKey: "title") as? String, "Hello")

        // Wait for view context to merge the background save (observer merges asynchronously)
        await manager.viewContext.perform { }

        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        let results = try await manager.fetch(fetchRequest: request)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.value(forKey: "title") as? String, "Hello")
    }

    func testSave_whenContextHasNoChanges_doesNotThrow() async throws {
        _ = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("One", forKey: "title")
            return item
        }
        await manager.viewContext.perform { }
        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        let existing = try await manager.fetch(fetchRequest: request)
        XCTAssertEqual(existing.count, 1)
    }

    // MARK: - Update by objectID

    func testUpdate_modifiesObjectInBackground() async throws {
        let object = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("Original", forKey: "title")
            return item
        }
        let id = object.objectID

        try await manager.update(objectID: id) { obj, _ in
            obj.setValue("Updated", forKey: "title")
        }
        await manager.viewContext.perform { }

        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        let results = try await manager.fetch(fetchRequest: request)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.value(forKey: "title") as? String, "Updated")
    }

    // MARK: - Delete by objectID

    func testDelete_removesObject() async throws {
        let object = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("ToDelete", forKey: "title")
            return item
        }
        let id = object.objectID

        try await manager.delete(objectID: id)
        await manager.viewContext.perform { }

        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        let results = try await manager.fetch(fetchRequest: request)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Batch delete (requires SQLite; NSBatchDeleteRequest is not supported on in-memory store)

    func testBatchDelete_removesMatchingObjects() async throws {
        let (sqliteContainer, storeURL) = TestContainerFactory.makeTemporarySQLiteContainer()
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + "-shm"))
        }
        let batchManager = CoreDataManager(container: sqliteContainer)

        for i in 0..<5 {
            _ = try await batchManager.save { context in
                let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
                item.setValue("Item \(i)", forKey: "title")
                return item
            }
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        request.predicate = NSPredicate(format: "title BEGINSWITH %@", "Item")
        try await batchManager.batchDelete(fetchRequest: request)

        let fetchAll = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        let results = try await batchManager.fetch(fetchRequest: fetchAll)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Fetch

    func testFetch_returnsObjectsFromViewContext() async throws {
        _ = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("A", forKey: "title")
            return item
        }
        _ = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("B", forKey: "title")
            return item
        }
        await manager.viewContext.perform { }

        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        let results = try await manager.fetch(fetchRequest: request)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].value(forKey: "title") as? String, "A")
        XCTAssertEqual(results[1].value(forKey: "title") as? String, "B")
    }

    func testFetch_requestWithNilPredicate_usesResolvedCopy_notMutatingCallerRequest() async throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        XCTAssertNil(request.predicate)

        _ = try await manager.fetch(fetchRequest: request)

        // Caller's request should still have nil predicate (no mutation)
        XCTAssertNil(request.predicate)
    }

    // MARK: - Fetch in background

    func testFetchInBackground_returnsObjectIDs_resolvableOnViewContext() async throws {
        _ = try await manager.save { context in
            let item = NSEntityDescription.insertNewObject(forEntityName: TestContainerFactory.testEntityName, into: context)
            item.setValue("Background", forKey: "title")
            return item
        }
        await manager.viewContext.perform { }

        let request = NSFetchRequest<NSManagedObject>(entityName: TestContainerFactory.testEntityName)
        let ids = try await manager.fetchInBackground(fetchRequest: request)
        XCTAssertEqual(ids.count, 1)

        let resolved = await manager.getObject(with: ids[0])
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.value(forKey: "title") as? String, "Background")
    }

    // MARK: - newTaskContext name/author

    func testNewTaskContext_withNameAndAuthor_setsContextIdentity() async throws {
        let context = manager.newTaskContext(name: "Test.Import", transactionAuthor: "TestApp")
        XCTAssertEqual(context.name, "Test.Import")
        XCTAssertEqual(context.transactionAuthor, "TestApp")
    }

    func testNewTaskContext_withNils_doesNotSetNameOrAuthor() async throws {
        let context = manager.newTaskContext(name: nil, transactionAuthor: nil)
        XCTAssertNil(context.name)
        XCTAssertNil(context.transactionAuthor)
    }
}
