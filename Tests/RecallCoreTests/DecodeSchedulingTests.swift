import Foundation
import Testing

@testable import RecallCore

@Test func cancelledQueuedDecodeDoesNotAcquireAWorker() async throws {
  let limiter = DecodeLimiter(limit: 1)
  try await limiter.acquire()
  let pending = Task<Void, Error> { try await limiter.acquire() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while await limiter.queuedCount == 0, ContinuousClock.now < deadline { await Task.yield() }
  #expect(await limiter.queuedCount == 1)
  pending.cancel()
  await limiter.release()
  await #expect(throws: CancellationError.self) { try await pending.value }
}

@Test func tenThousandCancelledDecodesDrainWithoutWaitingForTheActiveWorker() async throws {
  let limiter = DecodeLimiter(limit: 1)
  try await limiter.acquire()
  var requests: [Task<Void, Error>] = []
  for _ in 0..<10_000 { requests.append(Task { try await limiter.acquire() }) }
  let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(10))
  while await limiter.queuedCount < 10_000, ContinuousClock.now < admissionDeadline {
    await Task.yield()
  }
  #expect(await limiter.queuedCount == 10_000)
  for request in requests { request.cancel() }
  let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(10))
  while await limiter.queuedCount > 0, ContinuousClock.now < cancellationDeadline {
    await Task.yield()
  }
  #expect(await limiter.queuedCount == 0)
  await limiter.release()
  var cancelled = 0
  for request in requests {
    do { try await request.value } catch is CancellationError { cancelled += 1 }
  }
  #expect(cancelled == 10_000)
  // All cancelled requests released or returned their permit. New work can proceed.
  try await limiter.acquire()
  await limiter.release()
}

@Test func decodeAdmissionPreservesFIFOForLiveRequests() async throws {
  let limiter = DecodeLimiter(limit: 1)
  try await limiter.acquire()
  let first = Task { try await limiter.acquire() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while await limiter.queuedCount < 1, ContinuousClock.now < deadline { await Task.yield() }
  let second = Task { try await limiter.acquire() }
  while await limiter.queuedCount < 2, ContinuousClock.now < deadline { await Task.yield() }
  #expect(await limiter.queuedCount == 2)
  await limiter.release()
  try await first.value
  #expect(await limiter.queuedCount == 1)
  await limiter.release()
  try await second.value
  #expect(await limiter.queuedCount == 0)
  await limiter.release()
}
