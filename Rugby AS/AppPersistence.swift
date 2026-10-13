import Foundation
import SwiftData

enum AppPersistence {
    static let failureNotification = Notification.Name("RugbyAS.persistenceFailure")

    static func report(_ error: Error) {
        NotificationCenter.default.post(name: failureNotification, object: nil,
            userInfo: ["message": "保存できませんでした。編集内容を確認し、空き容量などを確認してもう一度保存してください。\n" + error.localizedDescription])
    }

    /// Ordinary edits stay pending so the user can retry without losing input.
    @discardableResult static func save(_ context: ModelContext) -> Bool {
        do { try context.save(); return true }
        catch { report(error); return false }
    }

    /// Files and defaults must only be removed after the database commits.
    @discardableResult static func transaction(_ context: ModelContext,
        restoreVisibleValues: () -> Void = {}, mutation: () throws -> Void, afterSave: () -> Void = {}) -> Bool {
        if context.hasChanges && !save(context) { return false }
        do {
            try mutation()
            try context.save()
            afterSave()
            return true
        } catch {
            context.rollback()
            restoreVisibleValues()
            context.processPendingChanges()
            context.rollback()
            report(error)
            return false
        }
    }
}

enum SafeDeletion {
    static func removeUnreferencedImages(_ images: [String], context: ModelContext, remove: (String) -> Void) {
        do {
            let referenced = Set(try context.fetch(FetchDescriptor<Team>()).compactMap(\.logoPath)
                + context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.imagePath != nil })).compactMap(\.imagePath)
                + context.fetch(FetchDescriptor<Tournament>()).compactMap(\.logoPath))
            Set(images).subtracting(referenced).forEach(remove)
        } catch { AppPersistence.report(error) }
    }
    @discardableResult static func match(_ match: Match, context: ModelContext, afterSave: () -> Void) -> Bool {
        let id = match.id
        return AppPersistence.transaction(context, mutation: {
            let events = try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.matchID == id }))
            let lineups = try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.matchID == id }))
            let substitutions = try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate { $0.matchID == id }))
            events.forEach { context.delete($0) }
            lineups.forEach { context.delete($0) }
            substitutions.forEach { context.delete($0) }
            context.delete(match)
        }, afterSave: afterSave)
    }

    @discardableResult static func team(_ team: Team, context: ModelContext, removeImage: (String) -> Void) -> Bool {
        var memberships: [(Tournament, [UUID])] = []
        var images: [String] = []
        return AppPersistence.transaction(context, restoreVisibleValues: {
            memberships.forEach { $0.0.teamIDs = $0.1 }
        }, mutation: {
            let id = team.id
            let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { $0.homeTeamID == id || $0.awayTeamID == id }))
            guard matches.isEmpty else { throw RecordingWidgetError.invalid("試合で使用しているチームは削除できません。") }
            let players = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == id }))
            memberships = try context.fetch(FetchDescriptor<Tournament>()).filter { $0.teamIDs.contains(id) }.map { ($0, $0.teamIDs) }
            images = players.compactMap(\.imagePath) + [team.logoPath].compactMap { $0 }
            memberships.forEach { $0.0.teamIDs.removeAll { $0 == id } }
            players.forEach { context.delete($0) }
            context.delete(team)
        }, afterSave: { removeUnreferencedImages(images, context: context, remove: removeImage) })
    }

    @discardableResult static func player(_ player: Player, context: ModelContext, removeImage: (String) -> Void) -> Bool {
        let image = player.imagePath
        return AppPersistence.transaction(context, mutation: {
            let id = player.id
            let events = try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.playerID == id }))
            let lineups = try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { $0.playerID == id }))
            let substitutions = try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate { $0.playerInID == id || $0.playerOutID == id }))
            guard events.isEmpty && lineups.isEmpty && substitutions.isEmpty else {
                throw RecordingWidgetError.invalid("試合で使用している選手は削除できません。")
            }
            context.delete(player)
        }, afterSave: { removeUnreferencedImages([image].compactMap { $0 }, context: context, remove: removeImage) })
    }
}

enum SafeImageMutation {
    @discardableResult static func replace(old: String?, new: String?, context: ModelContext,
        set: (String?) -> Void, removeImage: (String) -> Void) -> Bool {
        let saved = AppPersistence.transaction(context, restoreVisibleValues: { set(old) },
            mutation: { set(new) }, afterSave: {
                SafeDeletion.removeUnreferencedImages([old].compactMap { $0 }, context: context, remove: removeImage)
            })
        if !saved, let new, new != old { removeImage(new) }
        return saved
    }
}
