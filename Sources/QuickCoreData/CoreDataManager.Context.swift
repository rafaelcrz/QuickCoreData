//
//  File.swift
//  QuickCoreData
//
//  Created by Rafael Ramos on 28/10/25.
//

import Foundation
@preconcurrency import CoreData

extension CoreDataManager {
    public func getObject(with id: NSManagedObjectID) async -> NSManagedObject? {
        let context = viewContext
        return await context.perform {
            let object: NSManagedObject = context.object(with: id)
            return object
        }
    }
}

