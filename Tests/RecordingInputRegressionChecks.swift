import Foundation
import SwiftData

@MainActor
enum RecordingInputRegressionChecks {
    private enum Failure: Error { case failed(String) }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }

    private static func fixture() throws -> (ModelContainer, Match, RecordingWidgetStore) {
        let container = try ModelContainer(for: Match.self, StatEvent.self, Player.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let match = Match(tournamentID: UUID(), homeTeamID: UUID(), awayTeamID: UUID(), playedAt: .now)
        container.mainContext.insert(match)
        try container.mainContext.save()
        return (container, match, RecordingWidgetStore(match: match, context: container.mainContext))
    }

    static func run() throws {
        try attachesToTheWidgetsTeam()
        try neverFallsBackToTheOtherTeam()
        try discardsOnlyTheUnconfirmedEvent()
        try refusesEventsFromAnotherMatch()
        try quickInputIsAtomicAndUndoable()
        try quickInputPreservesAttachments()
        print("PASS: 6 recording input regression checks")
    }

    private static func quickInputIsAtomicAndUndoable() throws {
        let (container, _, store) = try fixture()
        defer { withExtendedLifetime(container) {} }
        var number = RecordingWidgetDefinition.make(.number)
        number.category = "carry_metres"
        try expect(store.submitInput(number, number: -4.5), "Signed carry distance is supported")
        try expect(store.events.count == 1 && store.events[0].recordingDetails.number == -4.5, "One complete record is saved")
        store.undo()
        try expect(store.events.isEmpty, "One undo removes the entire quick input")
        try expect(!store.submitInput(number, number: .infinity) && store.events.isEmpty, "Invalid input leaves no phantom event")
        let choice = RecordingWidgetDefinition.make(.choice)
        try expect(!store.submitInput(choice, choice: "invalid") && store.events.isEmpty, "Unknown choice is rejected")
        try expect(store.submitInput(choice, choice: choice.choices[0]), "Valid choice saves")
        try expect(store.events.first?.recordingDetails.choice == choice.choices[0], "Choice is persisted")
    }

    private static func quickInputPreservesAttachments() throws {
        let (container, match, store) = try fixture()
        let event = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 10)
        var details = RecordingEventDetails(); details.note = "残すメモ"; details.videoFileName = "video.mov"
        event.recordingDetails = details
        container.mainContext.insert(event); try container.mainContext.save()
        store.selectTeam(match.homeTeamID)
        let zone = RecordingWidgetDefinition.make(.zone)
        try expect(store.submitInput(zone, zone: 8, attackUp: false), "Zone attaches to latest event")
        try expect(store.events.count == 1 && event.recordingDetails.zone == 8 && !event.recordingDetails.attackUp, "No additional event is created")
        try expect(event.recordingDetails.note == "残すメモ" && event.recordingDetails.videoFileName == "video.mov", "Other metadata remains")
        store.undo()
        try expect(store.events.first?.recordingDetails.zone == nil && store.events.first?.recordingDetails.note == "残すメモ", "Undo restores earlier details")
        var awayZone = zone; awayZone.scope = .away
        try expect(!store.submitInput(awayZone, zone: 0) && store.events.count == 1, "Missing team target never falls back")
    }

    private static func attachesToTheWidgetsTeam() throws {
        let (container, match, store) = try fixture()
        let own = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 10)
        let opponent = StatEvent(matchID: match.id, teamID: match.awayTeamID, category: "try", outcome: "success", seconds: 20)
        container.mainContext.insert(own)
        container.mainContext.insert(opponent)
        // 保持時間や状態マーカーは、時刻が新しくても追記先にしない。
        container.mainContext.insert(StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "possession", outcome: "own", seconds: 30))
        container.mainContext.insert(StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "match_state", outcome: "finished", seconds: 40))
        try container.mainContext.save()
        store.selectTeam(match.awayTeamID)
        var zone = RecordingWidgetDefinition.make(.zone)
        zone.scope = .home
        try expect(store.latestEvent(for: zone)?.id == own.id, "HOME attachment targets HOME while AWAY is selected")
        try expect(store.eventForInput(zone)?.id == own.id, "Opening attachment uses the scoped event")
        zone.scope = .selected
        try expect(store.eventForInput(zone)?.id == opponent.id, "Selected scope follows the current team")
    }

    private static func neverFallsBackToTheOtherTeam() throws {
        let (container, match, store) = try fixture()
        container.mainContext.insert(StatEvent(matchID: match.id, teamID: match.awayTeamID, category: "try", outcome: "success", seconds: 20))
        try container.mainContext.save()
        store.selectTeam(match.awayTeamID)
        var zone = RecordingWidgetDefinition.make(.zone)
        zone.scope = .home
        try expect(store.latestEvent(for: zone) == nil, "No HOME event means no HOME attachment target")
        try expect(store.eventForInput(zone) == nil && store.events.count == 1, "Missing target never edits AWAY or creates a phantom zone event")
    }

    private static func discardsOnlyTheUnconfirmedEvent() throws {
        let (container, match, store) = try fixture()
        let earlier = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 2)
        container.mainContext.insert(earlier)
        try container.mainContext.save()
        let penalty = store.layout.widgets.first { $0.category == "penalty" }!
        let pending = store.eventForInput(penalty)!
        let pendingID = pending.id
        try expect(store.count(penalty) == 1 && store.canUndo, "Opening new input creates a cancellable event")
        // 別の操作で新しい記録ができても、キャンセルするのは渡した ID だけ。
        let later = StatEvent(matchID: match.id, teamID: match.homeTeamID, category: "try", outcome: "success", seconds: 40)
        container.mainContext.insert(later)
        try container.mainContext.save()
        try expect(store.discardUnconfirmedEvent(pending), "Cancel persists successfully")
        try expect(Set(store.events.map(\.id)) == Set([earlier.id, later.id]), "Cancel preserves earlier and later real records")
        try expect(store.count(penalty) == 0 && !store.canUndo, "Cancel removes the phantom count and clears obsolete undo")
        store.undo()
        try expect(!store.events.contains { $0.id == pendingID } && store.events.count == 2, "Undo cannot resurrect cancelled input")
        let reopened = RecordingWidgetStore(match: match, context: container.mainContext)
        try expect(reopened.events.count == 2 && reopened.count(penalty) == 0, "Cancellation survives reopening")
    }

    private static func refusesEventsFromAnotherMatch() throws {
        let (container, _, store) = try fixture()
        let other = StatEvent(matchID: UUID(), category: "try", outcome: "success", seconds: 5)
        container.mainContext.insert(other)
        try container.mainContext.save()
        try expect(!store.discardUnconfirmedEvent(other), "A store cannot cancel another match's event")
        let id = other.id
        let persisted = try container.mainContext.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.id == id }))
        try expect(persisted.count == 1, "Other match data remains intact")
    }
}
