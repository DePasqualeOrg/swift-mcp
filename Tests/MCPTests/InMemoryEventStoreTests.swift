// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

/// Tests for InMemoryEventStore - event storage for resumability support.
struct InMemoryEventStoreTests {
    // MARK: - Basic Operations

    @Test
    func `Initialization creates empty store`() async {
        let store = InMemoryEventStore()
        let count = await store.eventCount
        #expect(count == 0)
    }

    @Test
    func `Store event`() async throws {
        let store = InMemoryEventStore()
        let message = #"{"jsonrpc":"2.0","result":"test","id":"1"}"#.data(using: .utf8)!

        let eventId = try await store.storeEvent(streamId: "stream-1", message: message)

        #expect(!eventId.isEmpty)
        #expect(eventId.contains("stream-1"))

        let count = await store.eventCount
        #expect(count == 1)
    }

    @Test
    func `Store multiple events`() async throws {
        let store = InMemoryEventStore()

        for i in 0 ..< 5 {
            let message = #"{"jsonrpc":"2.0","result":"\#(i)","id":"\#(i)"}"#.data(using: .utf8)!
            _ = try await store.storeEvent(streamId: "stream-1", message: message)
        }

        let count = await store.eventCount
        #expect(count == 5)
    }

    @Test
    func `Stream ID for event ID`() async throws {
        let store = InMemoryEventStore()
        let message = #"{"jsonrpc":"2.0","result":"test","id":"1"}"#.data(using: .utf8)!

        let eventId = try await store.storeEvent(streamId: "my-stream-id", message: message)

        let streamId = await store.streamIdForEventId(eventId)
        #expect(streamId == "my-stream-id")
    }

    @Test
    func `Stream ID for unknown event ID returns nil`() async {
        let store = InMemoryEventStore()

        let streamId = await store.streamIdForEventId("unknown-event-id")
        #expect(streamId == nil)
    }

    @Test
    func `Stream ID for event ID with underscores`() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        // Stream ID with underscores
        let eventId = try await store.storeEvent(streamId: "stream_with_underscores", message: message)

        let streamId = await store.streamIdForEventId(eventId)
        #expect(streamId == "stream_with_underscores")
    }

    // MARK: - Event Replay

    @Test
    func `Replay events after`() async throws {
        let store = InMemoryEventStore()

        // Store some events
        var eventIds: [String] = []
        for i in 0 ..< 5 {
            let message = #"{"jsonrpc":"2.0","result":"\#(i)","id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream-1", message: message)
            eventIds.append(eventId)
        }

        // Replay events after the second one
        actor MessageCollector {
            var messages: [String] = []
            func add(_ msg: String) {
                messages.append(msg)
            }

            func get() -> [String] {
                messages
            }
        }
        let collector = MessageCollector()

        let streamId = try await store.replayEventsAfter(eventIds[1]) { _, message in
            if let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
               let result = json["result"] as? String
            {
                await collector.add(result)
            }
        }

        #expect(streamId == "stream-1")
        let replayedMessages = await collector.get()
        #expect(replayedMessages == ["2", "3", "4"]) // Events 2, 3, 4 (after event 1)
    }

    @Test
    func `Replay events only from same stream`() async throws {
        let store = InMemoryEventStore()

        // Store events for two different streams
        let message1 = #"{"stream":"1","id":"a"}"#.data(using: .utf8)!
        let eventId1 = try await store.storeEvent(streamId: "stream-1", message: message1)

        let message2 = #"{"stream":"2","id":"b"}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-2", message: message2)

        let message3 = #"{"stream":"1","id":"c"}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-1", message: message3)

        // Replay from stream-1's first event
        actor Counter {
            var count = 0
            func increment() {
                count += 1
            }

            func value() -> Int {
                count
            }
        }
        let counter = Counter()

        _ = try await store.replayEventsAfter(eventId1) { _, _ in
            await counter.increment()
        }

        // Should only replay event "c" from stream-1 (not "b" from stream-2)
        let replayedCount = await counter.value()
        #expect(replayedCount == 1)
    }

    @Test
    func `Replay events with unknown event ID throws`() async {
        let store = InMemoryEventStore()

        await #expect(throws: EventStoreError.self) {
            _ = try await store.replayEventsAfter("unknown-event") { _, _ in }
        }
    }

    // MARK: - Cleanup

    @Test
    func `Clear removes all events`() async throws {
        let store = InMemoryEventStore()

        // Store some events
        for _ in 0 ..< 5 {
            let message = Data()
            _ = try await store.storeEvent(streamId: "stream", message: message)
        }

        var count = await store.eventCount
        #expect(count == 5)

        await store.clear()

        count = await store.eventCount
        #expect(count == 0)
    }

    @Test
    func `Remove events for stream`() async throws {
        let store = InMemoryEventStore()

        // Store events for two streams
        for _ in 0 ..< 3 {
            _ = try await store.storeEvent(streamId: "stream-1", message: Data())
        }
        for _ in 0 ..< 2 {
            _ = try await store.storeEvent(streamId: "stream-2", message: Data())
        }

        var count = await store.eventCount
        #expect(count == 5)

        let removed = await store.removeEvents(forStream: "stream-1")
        #expect(removed == 3)

        count = await store.eventCount
        #expect(count == 2)
    }

    @Test
    func `Cleanup old events`() async throws {
        let store = InMemoryEventStore()

        // Store an event
        _ = try await store.storeEvent(streamId: "stream", message: Data())

        var count = await store.eventCount
        #expect(count == 1)

        // Clean up with zero age - should remove all
        let removed = await store.cleanUp(olderThan: .zero)
        #expect(removed == 1)

        count = await store.eventCount
        #expect(count == 0)
    }

    @Test
    func `Cleanup does not remove recent events`() async throws {
        let store = InMemoryEventStore()

        // Store an event
        _ = try await store.storeEvent(streamId: "stream", message: Data())

        // Clean up with 1 hour age - should not remove recent event
        let removed = await store.cleanUp(olderThan: .seconds(3600))
        #expect(removed == 0)

        let count = await store.eventCount
        #expect(count == 1)
    }

    // MARK: - Concurrency

    @Test
    func `Concurrent store and retrieve`() async {
        let store = InMemoryEventStore()

        // Concurrently store events
        await withTaskGroup(of: String.self) { group in
            for i in 0 ..< 100 {
                group.addTask {
                    let message = Data()
                    return try! await store.storeEvent(streamId: "stream-\(i % 10)", message: message)
                }
            }
        }

        let count = await store.eventCount
        #expect(count == 100)
    }

    @Test
    func `Concurrent replay`() async throws {
        let store = InMemoryEventStore()

        // Store events for multiple streams
        // Note: Use non-empty data because empty data is treated as priming events and skipped during replay
        var firstEventIds: [String] = []
        for stream in 0 ..< 5 {
            let message = Data("test".utf8)
            let eventId = try await store.storeEvent(streamId: "stream-\(stream)", message: message)
            firstEventIds.append(eventId)

            // Add more events to each stream
            for _ in 0 ..< 10 {
                _ = try await store.storeEvent(streamId: "stream-\(stream)", message: message)
            }
        }

        // Concurrently replay from each stream
        actor Counter {
            var value = 0
            func increment() {
                value += 1
            }

            func reset() -> Int {
                let v = value
                value = 0
                return v
            }
        }

        await withTaskGroup(of: Int.self) { group in
            for (_, eventId) in firstEventIds.enumerated() {
                group.addTask {
                    let counter = Counter()
                    _ = try? await store.replayEventsAfter(eventId) { _, _ in
                        await counter.increment()
                    }
                    return await counter.reset()
                }
            }

            for await count in group {
                #expect(count == 10) // Each stream should replay 10 events
            }
        }
    }

    // MARK: - Event ID Format

    @Test
    func `Event ID contains stream ID`() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        let eventId = try await store.storeEvent(streamId: "unique-stream-123", message: message)

        #expect(eventId.hasPrefix("unique-stream-123_"))
    }

    @Test
    func `Event IDs are unique`() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        var eventIds = Set<String>()
        for _ in 0 ..< 100 {
            let eventId = try await store.storeEvent(streamId: "stream", message: message)
            eventIds.insert(eventId)
        }

        #expect(eventIds.count == 100) // All IDs should be unique
    }

    // MARK: - Max Events Per Stream

    @Test
    func `Default maxEventsPerStream is 100`() {
        let store = InMemoryEventStore()
        #expect(store.maxEventsPerStream == 100)
    }

    @Test
    func `Custom maxEventsPerStream is respected`() {
        let store = InMemoryEventStore(maxEventsPerStream: 50)
        #expect(store.maxEventsPerStream == 50)
    }

    @Test
    func `Automatic eviction when max events reached`() async throws {
        let store = InMemoryEventStore(maxEventsPerStream: 5)
        let message = Data("test".utf8)

        // Store 5 events (at capacity)
        var eventIds: [String] = []
        for i in 0 ..< 5 {
            let msg = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: msg)
            eventIds.append(eventId)
        }

        var count = await store.eventCount
        #expect(count == 5)

        // Store one more - should evict the oldest
        let newEventId = try await store.storeEvent(streamId: "stream", message: message)

        count = await store.eventCount
        #expect(count == 5) // Still 5 events

        // The oldest event should be evicted
        let oldestStreamId = await store.streamIdForEventId(eventIds[0])
        // The event is no longer in the index, so we fall back to parsing
        #expect(oldestStreamId == "stream") // Parsing still works

        // But replay should fail for the evicted event
        await #expect(throws: EventStoreError.self) {
            _ = try await store.replayEventsAfter(eventIds[0]) { _, _ in }
        }

        // The new event should be retrievable
        let newStreamId = await store.streamIdForEventId(newEventId)
        #expect(newStreamId == "stream")
    }

    @Test
    func `Eviction is per-stream`() async throws {
        let store = InMemoryEventStore(maxEventsPerStream: 3)
        let message = Data("test".utf8)

        // Fill stream-1 to capacity
        for _ in 0 ..< 3 {
            _ = try await store.storeEvent(streamId: "stream-1", message: message)
        }

        // Fill stream-2 to capacity
        for _ in 0 ..< 3 {
            _ = try await store.storeEvent(streamId: "stream-2", message: message)
        }

        var count = await store.eventCount
        #expect(count == 6) // 3 per stream

        // Add to stream-1 - should only evict from stream-1
        _ = try await store.storeEvent(streamId: "stream-1", message: message)

        count = await store.eventCount
        #expect(count == 6) // Still 6 total (3 + 3)

        let streamCount = await store.streamCount
        #expect(streamCount == 2)
    }

    @Test
    func `Replay works correctly after eviction`() async throws {
        let store = InMemoryEventStore(maxEventsPerStream: 5)

        // Store 5 events
        var eventIds: [String] = []
        for i in 0 ..< 5 {
            let msg = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: msg)
            eventIds.append(eventId)
        }

        // Store 2 more (evicting the first 2)
        for i in 5 ..< 7 {
            let msg = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: msg)
            eventIds.append(eventId)
        }

        // eventIds[2] (id: "2") should still be valid and allow replay of 3, 4, 5, 6
        actor MessageCollector {
            var ids: [String] = []
            func add(_ id: String) {
                ids.append(id)
            }

            func get() -> [String] {
                ids
            }
        }
        let collector = MessageCollector()

        _ = try await store.replayEventsAfter(eventIds[2]) { _, message in
            if let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
               let id = json["id"] as? String
            {
                await collector.add(id)
            }
        }

        let replayedIds = await collector.get()
        #expect(replayedIds == ["3", "4", "5", "6"])
    }

    @Test
    func `Stream count tracks active streams`() async throws {
        let store = InMemoryEventStore()
        let message = Data()

        var streamCount = await store.streamCount
        #expect(streamCount == 0)

        _ = try await store.storeEvent(streamId: "stream-1", message: message)
        streamCount = await store.streamCount
        #expect(streamCount == 1)

        _ = try await store.storeEvent(streamId: "stream-2", message: message)
        streamCount = await store.streamCount
        #expect(streamCount == 2)

        // Adding to existing stream doesn't increase count
        _ = try await store.storeEvent(streamId: "stream-1", message: message)
        streamCount = await store.streamCount
        #expect(streamCount == 2)

        // Removing stream reduces count
        _ = await store.removeEvents(forStream: "stream-1")
        streamCount = await store.streamCount
        #expect(streamCount == 1)
    }

    // MARK: - Priming Events

    @Test
    func `Priming events (empty data) are stored but skipped during replay`() async throws {
        let store = InMemoryEventStore()

        // Store a regular event
        let msg1 = #"{"jsonrpc":"2.0","result":"first","id":"1"}"#.data(using: .utf8)!
        let eventId1 = try await store.storeEvent(streamId: "stream", message: msg1)

        // Store a priming event (empty data)
        let primingEventId = try await store.storeEvent(streamId: "stream", message: Data())

        // Store another regular event
        let msg2 = #"{"jsonrpc":"2.0","result":"second","id":"2"}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream", message: msg2)

        // All three events should be stored
        let count = await store.eventCount
        #expect(count == 3)

        // Priming event should have a valid stream ID
        let primingStreamId = await store.streamIdForEventId(primingEventId)
        #expect(primingStreamId == "stream")

        // Replay from first event - should only get the second regular event
        // (priming event should be skipped)
        actor MessageCollector {
            var messages: [Data] = []
            func add(_ msg: Data) {
                messages.append(msg)
            }

            func get() -> [Data] {
                messages
            }
        }
        let collector = MessageCollector()

        _ = try await store.replayEventsAfter(eventId1) { _, message in
            await collector.add(message)
        }

        let replayedMessages = await collector.get()
        #expect(replayedMessages.count == 1) // Only the non-priming event
        #expect(replayedMessages[0] == msg2) // The second regular message
    }

    @Test
    func `Replay events in strict chronological order`() async throws {
        let store = InMemoryEventStore()

        // Store events with explicit ordering in their content
        var eventIds: [String] = []
        for i in 0 ..< 10 {
            let message = #"{"order":\#(i)}"#.data(using: .utf8)!
            let eventId = try await store.storeEvent(streamId: "stream", message: message)
            eventIds.append(eventId)
        }

        // Replay from the first event
        actor OrderCollector {
            var orders: [Int] = []
            func add(_ order: Int) {
                orders.append(order)
            }

            func get() -> [Int] {
                orders
            }
        }
        let collector = OrderCollector()

        _ = try await store.replayEventsAfter(eventIds[0]) { _, message in
            if let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
               let order = json["order"] as? Int
            {
                await collector.add(order)
            }
        }

        let replayedOrders = await collector.get()

        // Should have events 1-9 (after event 0)
        #expect(replayedOrders.count == 9)

        // Verify strict chronological ordering
        for i in 0 ..< replayedOrders.count {
            #expect(replayedOrders[i] == i + 1)
        }
    }

    @Test
    func `Replay from most recent event returns empty`() async throws {
        let store = InMemoryEventStore()

        // Store some events
        var lastEventId = ""
        for i in 0 ..< 5 {
            let message = #"{"id":"\#(i)"}"#.data(using: .utf8)!
            lastEventId = try await store.storeEvent(streamId: "stream", message: message)
        }

        // Replay from the most recent event - nothing should be replayed
        actor Counter {
            var count = 0
            func increment() {
                count += 1
            }

            func value() -> Int {
                count
            }
        }
        let counter = Counter()

        let streamId = try await store.replayEventsAfter(lastEventId) { _, _ in
            await counter.increment()
        }

        #expect(streamId == "stream")
        let replayedCount = await counter.value()
        #expect(replayedCount == 0) // Nothing to replay after the most recent event
    }

    @Test
    func `Replay returns correct stream ID`() async throws {
        let store = InMemoryEventStore()

        // Store events on different streams
        let msg1 = Data("test".utf8)
        let eventIdStream1 = try await store.storeEvent(streamId: "stream-alpha", message: msg1)
        let eventIdStream2 = try await store.storeEvent(streamId: "stream-beta", message: msg1)

        // Add more events to both streams
        _ = try await store.storeEvent(streamId: "stream-alpha", message: msg1)
        _ = try await store.storeEvent(streamId: "stream-beta", message: msg1)

        // Replay from stream-alpha should return "stream-alpha"
        let streamId1 = try await store.replayEventsAfter(eventIdStream1) { _, _ in }
        #expect(streamId1 == "stream-alpha")

        // Replay from stream-beta should return "stream-beta"
        let streamId2 = try await store.replayEventsAfter(eventIdStream2) { _, _ in }
        #expect(streamId2 == "stream-beta")
    }

    // MARK: - Edge Cases

    @Test
    func `Store and replay with special characters in stream ID`() async throws {
        let store = InMemoryEventStore()

        // Test with various special characters that might be in a stream ID
        let specialStreamId = "stream-with-dashes_and_underscores.and.dots"
        let message = #"{"test":"value"}"#.data(using: .utf8)!

        let eventId1 = try await store.storeEvent(streamId: specialStreamId, message: message)
        _ = try await store.storeEvent(streamId: specialStreamId, message: message)

        // Verify stream ID can be retrieved
        let retrievedStreamId = await store.streamIdForEventId(eventId1)
        #expect(retrievedStreamId == specialStreamId)

        // Verify replay works
        actor Counter {
            var count = 0
            func increment() {
                count += 1
            }

            func value() -> Int {
                count
            }
        }
        let counter = Counter()

        let replayedStreamId = try await store.replayEventsAfter(eventId1) { _, _ in
            await counter.increment()
        }

        #expect(replayedStreamId == specialStreamId)
        #expect(await counter.value() == 1)
    }

    @Test
    func `Multiple streams interleaved storage and replay`() async throws {
        let store = InMemoryEventStore()

        // Interleave storage across multiple streams
        let msg1 = #"{"stream":"1","seq":1}"#.data(using: .utf8)!
        let eventIdS1_1 = try await store.storeEvent(streamId: "stream-1", message: msg1)

        let msg2 = #"{"stream":"2","seq":1}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-2", message: msg2)

        let msg3 = #"{"stream":"1","seq":2}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-1", message: msg3)

        let msg4 = #"{"stream":"2","seq":2}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-2", message: msg4)

        let msg5 = #"{"stream":"1","seq":3}"#.data(using: .utf8)!
        _ = try await store.storeEvent(streamId: "stream-1", message: msg5)

        // Replay from stream-1's first event
        actor MessageCollector {
            var sequences: [Int] = []
            func add(_ seq: Int) {
                sequences.append(seq)
            }

            func get() -> [Int] {
                sequences
            }
        }
        let collector = MessageCollector()

        let streamId = try await store.replayEventsAfter(eventIdS1_1) { _, message in
            if let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
               let stream = json["stream"] as? String,
               let seq = json["seq"] as? Int
            {
                // Verify only stream-1 messages are replayed
                #expect(stream == "1")
                await collector.add(seq)
            }
        }

        #expect(streamId == "stream-1")
        let sequences = await collector.get()
        #expect(sequences == [2, 3]) // Only stream-1 events after the first one
    }
}
