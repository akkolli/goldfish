import Foundation

/// One queue owns archive export, import, and automatic/manual backup operations.
final class DataCoordinator {
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "goldfish.data-operations"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    return queue
  }()
  private let lock = NSLock()
  private var generation = 0
  private var backupEnabled = false

  func setBackupEnabled(_ enabled: Bool) {
    lock.withLock {
      if backupEnabled != enabled {
        generation += 1
        backupEnabled = enabled
      }
    }
  }

  func cancel() {
    setBackupEnabled(false)
    queue.cancelAllOperations()
  }

  func perform<Value>(_ work: @escaping () -> Value, completion: @escaping (Value) -> Void) {
    queue.addOperation {
      let result = work()
      DispatchQueue.main.async { completion(result) }
    }
  }

  func backupOperation<Value>(_ work: @escaping (ArchiveWrite) throws -> Value) -> () -> Result<Value, Error> {
    let token = lock.withLock { generation }
    return { [self] in
      Result {
        try authorize(token) {}
        return try work { write in try self.authorize(token, write) }
      }
    }
  }

  private func authorize(_ token: Int, _ write: () throws -> Void) throws {
    try lock.withLock {
      guard backupEnabled, token == generation else { throw CloudBackupError.cancelled }
      try write()
    }
  }
}
