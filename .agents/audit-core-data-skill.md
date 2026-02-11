# Auditoria QuickCoreData — Skill Core Data Expert

Análise do módulo **QuickCoreData** com base nas referências do skill `.agents/skills/core-data-expert/` (stack-setup, saving, threading, concurrency, batch-operations, persistent-history, performance, project-audit).

---

## Alta criticidade

### 1. Merge policy incorreta nos contextos de background

**Onde:** `QuickCoreData.swift` — `newTaskContext()` (linha 32).

**Atual:** `NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)` (memória ganha sobre a store).

**Recomendação do skill (stack-setup.md):** Usar **`NSMergeByPropertyStoreTrumpMergePolicy`** quando há constraints ou quando a store deve prevalecer. Necessário para constraints funcionarem sem crash em conflito.

**Ação:** Trocar para `NSMergeByPropertyStoreTrumpMergePolicy` (ou equivalente via `NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)`).

---

### 2. Uso de `objectWillChange.send()` em `NSManagedObject`

**Onde:** `QuickCoreData.swift` — `save()` (69), `update()` (88). Em `saveV2` comentado (49).

**Problema:** `NSManagedObject` não conforma `ObservableObject` na API padrão da Apple; não possui `objectWillChange`. O código pode não compilar ou depender de extensão externa. Mesmo que exista extensão, notificar “will change” após o save já ocorreu é semanticamente estranho.

**Recomendação do skill (concurrency.md):** Evitar “paper over” com tipos Core Data; garantir que APIs estejam corretas.

**Ação:** Remover as chamadas a `object.objectWillChange.send()` ou substituir por mecanismo documentado (ex.: notificação do context, `refresh(_:mergeChanges:)`, ou deixar o `automaticallyMergesChangesFromParent` + FetchedResultsController/observers atualizarem a UI).

---

### 3. `update()` e `delete()` sem checagem de `hasChanges` antes de `save()`

**Onde:** `QuickCoreData.swift` — `update(objectID:...)` (86), `delete(objectID:)` (103).

**Problema:** Chama `try context.save()` mesmo quando não há mudanças, gerando I/O e notificações desnecessárias.

**Recomendação do skill (saving.md):** Usar `saveIfNeeded()` / checar `hasPersistentChanges` (ou ao menos `hasChanges`) antes de salvar.

**Ação:** Em `update`, só chamar `save()` se `context.hasChanges`. Em `delete`, o delete já gera mudança; manter save, mas considerar `guard context.hasChanges else { return }` antes do save em ambos para consistência.

---

## Média criticidade

### 4. Contextos de background sem nome e sem `transactionAuthor`

**Onde:** `QuickCoreData.swift` — `newTaskContext()`.

**Recomendação do skill (stack-setup.md):** Dar `name` e `transactionAuthor` aos contextos para debug (Instruments, logs) e para persistent history (filtrar por autor).

**Ação:** Ex.: `taskContext.name = "QuickCoreData.TaskContext"` e `taskContext.transactionAuthor = "QuickCoreData"` (ou valor configurável).

---

### 5. `save()` já verifica `hasChanges`, mas não `hasPersistentChanges`

**Onde:** `QuickCoreData.swift` — `save()` (linha 64).

**Atual:** `guard context.hasChanges else { return object }`.

**Recomendação do skill (saving.md):** Preferir checar apenas mudanças **persistentes** (ex.: `hasPersistentChanges`) para não disparar save por propriedades transient.

**Ação:** Implementar/extensão `hasPersistentChanges` e usar `guard context.hasPersistentChanges else { return object }` antes de `save()` (e no `update()` quando aplicar a checagem).

---

### 6. `batchDelete`: `context.save()` após batch é redundante / confuso

**Onde:** `QuickCoreData.swift` — `batchDelete` (linha 131).

**Atual:** Após `execute(batchDeleteRequest)` e `mergeChanges(fromRemoteContextSave:into:)`, chama `try context.save()`.

**Contexto (batch-operations.md):** Batch delete já persiste no store; o context de background não “tem” os objetos deletados. O merge atualiza a view context. Salvar o background context após o merge pode ser desnecessário ou apenas limpar a transação; documentar a intenção ou remover se não houver outras mudanças nesse context.

**Ação:** Revisar se esse `save()` é necessário; em todo caso, documentar e, se houver outras mudanças no mesmo context, manter a checagem `hasChanges` antes de salvar.

---

### 7. `fetch()` sempre usa o view context

**Onde:** `QuickCoreData.swift` — `fetch(fetchRequest:)` (linhas 139–148).

**Risco:** Fetch pesado ou com muitos resultados no view context pode travar a UI (main thread).

**Recomendação do skill (threading.md, performance.md):** Operações pesadas em background context; view context só para UI e listas leves (ex.: com `fetchBatchSize` e prefetch).

**Ação:** Documentar que `fetch()` é para uso leve na UI; para cargas grandes, sugerir API em background (ex.: `fetchInBackground`) ou deixar isso explícito no nome/ documentação.

---

### 8. View context não é configurado pelo módulo

**Onde:** O módulo recebe `NSPersistentCloudKitContainer` e expõe `viewContext` sem configurá-lo.

**Recomendação do skill (stack-setup.md):** No container, configurar no view context: `mergePolicy`, `automaticallyMergesChangesFromParent`, `name`.

**Ação:** Como o container é injetado, o módulo pode: (a) documentar que o app deve configurar o view context conforme o skill; ou (b) oferecer um método de “configuração recomendada” que aplique essas opções ao `viewContext` do container recebido (se o design do módulo permitir).

---

## Baixa criticidade

### 9. `getObject(with:)` retorna `NSManagedObject` do view context

**Onde:** `CoreDataManager.Context.swift` — `getObject(with id:)`.

**Risco:** O consumidor pode guardar o objeto e usá-lo noutro context/thread, violando a regra do skill: nunca passar `NSManagedObject` entre contextos.

**Recomendação do skill (threading.md, concurrency.md):** Preferir passar apenas `NSManagedObjectID` entre contextos/tasks.

**Ação:** Documentar que o retorno é válido apenas no thread do view context e não deve ser passado para outros contextos; preferir que o consumidor use o `objectID` quando for fazer trabalho em background.

---

### 10. `saveV2` comentado e na API pública

**Onde:** `QuickCoreData.swift` — protocolo (linha 11) e implementação (37–55).

**Problema:** Código morto e assinatura confusa (block recebe `NSManagedObject` e `NSManagedObjectContext`; não fica claro quem cria o object).

**Ação:** Remover do protocolo e da implementação ou reativar com assinatura e implementação alinhadas ao skill (contexto correto, perform, save condicional, sem `objectWillChange` em NSManagedObject).

---

### 11. Mutação de `fetchRequest.predicate` dentro do `perform`

**Onde:** `QuickCoreData.swift` — `fetch()` (linhas 144–145).

**Atual:** Se `fetchRequest.predicate == nil`, atribui `NSPredicate(value: true)` ao request.

**Risco:** O mesmo `NSFetchRequest` pode ser reutilizado pelo chamador; mutá-lo pode ter efeitos colaterais em outras chamadas.

**Ação:** Preferir criar uma cópia do request ou um request novo dentro do `perform` com o predicate desejado, em vez de mutar o request recebido.

---

### 12. Falta de testes e documentação de deployment target

**Recomendação do skill (project-audit.md, testing.md):** Definir deployment target (já é iOS 16 no Package.swift) e ter testes com store in-memory para padrões de save/context/merge.

**Ação:** Adicionar testes unitários para save condicional, update/delete por objectID e batch delete; documentar no README que o módulo assume iOS 16+ e, se usar CloudKit, lembrar que schema de produção é imutável (cloudkit-integration.md).

---

## Resumo por criticidade

| Criticidade | Itens |
|------------|--------|
| **Alta**   | 1 (merge policy), 2 (objectWillChange em NSManagedObject), 3 (save sem hasChanges em update/delete) |
| **Média**  | 4 (nome/transactionAuthor), 5 (hasPersistentChanges), 6 (batchDelete save), 7 (fetch no view context), 8 (config do view context) |
| **Baixa**  | 9 (getObject documentação), 10 (saveV2 morto), 11 (mutação do fetchRequest), 12 (testes e doc) |

---

## Pontos positivos (alinhados ao skill)

- Uso de **NSManagedObjectID** em `update(objectID:)`, `delete(objectID:)` e fluxos que recebem ID.
- Uso de **context.perform** em operações assíncronas (save, update, delete, fetch, getObject).
- **batchDelete** usa `resultType = .resultTypeObjectIDs` e faz merge explícito para o view context com `mergeChanges(fromRemoteContextSave:into:)`.
- **Rollback** em todos os paths de erro antes de relançar o erro.
- **`automaticallyMergesChangesFromParent = true`** no task context.
- Uso de **@Sendable** nos closures onde faz sentido.
- **Injeção do container** facilita testes e uso com NSPersistentCloudKitContainer.

Implementar primeiro os itens de **alta** criticidade e, em seguida, os de **média**, mantendo as boas práticas já adotadas.
