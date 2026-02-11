# QuickCoreData

Módulo Swift (SPM) que encapsula operações comuns de Core Data com suporte a `NSPersistentCloudKitContainer`, contextos em background e APIs async.

## Requisitos

- **Plataforma:** iOS 16+
- **Swift:** 6.x (compatível com o swift-tools-version do `Package.swift`)

## Uso

O módulo recebe um `NSPersistentCloudKitContainer` já configurado pelo app (store, model, CloudKit). Não inclui um `.xcdatamodeld`; o modelo é de responsabilidade do app.

```swift
let container = NSPersistentCloudKitContainer(name: "MyModel")
// … configurar persistentStoreDescriptions, loadPersistentStores, etc.

let manager = CoreDataManager(container: container)
```

### Contextos

- **View context:** `manager.viewContext` — use na UI (main thread).
- **Task context:** `manager.newTaskContext(name:transactionAuthor:)` — para trabalho em background. Passe `name` e `transactionAuthor` para identificar o contexto em Instruments e no Persistent History (ex.: filtrar por autor).

### Fetch

- **`fetch(fetchRequest:)`** — executa no view context. Indicado para listas leves na UI.
- **`fetchInBackground(fetchRequest:)`** — executa em background e retorna `[NSManagedObjectID]`. Resolva os IDs no view context (ex.: `getObject(with:)`) para atualizar a UI.

### Save, update e delete

- **`save(_:)`** — cria/alterar objeto em contexto de background e persiste (só salva se houver mudanças).
- **`update(objectID:_:)`** — atualiza um objeto por `NSManagedObjectID` em background.
- **`delete(objectID:)`** — remove um objeto por ID em background.
- **`batchDelete(fetchRequest:)`** — exclusão em lote; faz merge das mudanças no view context.

## CloudKit

Ao usar `NSPersistentCloudKitContainer` e sincronizar com CloudKit:

- O **schema em produção no CloudKit é imutável**. Planeje o modelo e as mudanças com cuidado; use o ambiente de desenvolvimento para iterar antes de promover para produção.

## Testes

Os testes do pacote usam store **in-memory** e um modelo programático mínimo (entidade de teste), sem depender de um `.xcdatamodeld` do app.

- **Terminal (destino iOS):** `swift test --build-path .build` pode falhar se o SPM construir para macOS; o pacote declara apenas iOS 16+.
- **Xcode:** abra a pasta do pacote no Xcode, escolha um destino **iOS Simulator** (ex.: iPhone 16) e rode os testes com ⌘U ou Product → Test.

## Licença

Conforme definido no repositório do projeto.
