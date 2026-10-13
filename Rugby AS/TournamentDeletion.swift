//
//  TournamentDeletion.swift
//  Rugby AS
//
//  間違えて取り込んだ大会を、試合・記録ごとまとめて消す。
//  あわせて「この大会の試合にしか出ていないチーム・選手」も消せる(取り込みで作られたものを残さないため)。
//  - チーム: この大会に試合があり、ほかの大会には試合がないチーム(選手名簿ごと消す)
//  - 選手: 残るチームの選手のうち、この大会の試合にしか記録(メンバー表・得点など・交代)がない選手
//  試合に1度も出ていないチーム・選手(自分で登録しただけのもの)は消さない。元に戻せない。
//

import Foundation
import SwiftData

enum TournamentDeletion {
    /// 消す前に見せる内容
    struct Plan {
        var matchIDs: [UUID] = []
        var eventCount = 0
        var lineupCount = 0
        var substitutionCount = 0
        /// この大会にしか出ていないチーム(名前順)
        var onlyHereTeams: [Team] = []
        /// そのチームの選手の数
        var onlyHereTeamPlayerCount: [UUID: Int] = [:]
        /// 残るチームにいる、この大会にしか出ていない選手
        var onlyHerePlayers: [Player] = []
    }

    static func plan(for tournament: Tournament, context: ModelContext) throws -> Plan {
        let tournamentID = tournament.id
        let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { $0.tournamentID == tournamentID }))
        let matchIDs = matches.map(\.id)
        var plan = Plan()
        plan.matchIDs = matchIDs
        let events = try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { matchIDs.contains($0.matchID) }))
        let lineups = try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { matchIDs.contains($0.matchID) }))
        let substitutions = try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate { matchIDs.contains($0.matchID) }))
        plan.eventCount = events.count
        plan.lineupCount = lineups.count
        plan.substitutionCount = substitutions.count

        // チーム: ほかの大会の試合に出ているか
        let teamIDs = Set(matches.flatMap { [$0.homeTeamID, $0.awayTeamID] })
        let teamList = Array(teamIDs)
        let otherMatches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate {
            $0.tournamentID != tournamentID && (teamList.contains($0.homeTeamID) || teamList.contains($0.awayTeamID))
        }))
        let teamsElsewhere = Set(otherMatches.flatMap { [$0.homeTeamID, $0.awayTeamID] })
        let onlyHereTeamIDs = teamIDs.subtracting(teamsElsewhere)
        let onlyHereList = Array(onlyHereTeamIDs)
        plan.onlyHereTeams = try context.fetch(FetchDescriptor<Team>(predicate: #Predicate { onlyHereList.contains($0.id) }))
            .sorted { $0.name < $1.name }
        for player in try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { onlyHereList.contains($0.teamID) })) {
            plan.onlyHereTeamPlayerCount[player.teamID, default: 0] += 1
        }

        // 選手: この大会の試合に記録があり、ほかの試合には記録がない(残るチームの選手だけ)
        var herePlayerIDs = Set(lineups.map(\.playerID))
        herePlayerIDs.formUnion(events.compactMap(\.playerID))
        herePlayerIDs.formUnion(substitutions.flatMap { [$0.playerInID, $0.playerOutID] })
        let playerList = Array(herePlayerIDs)
        let optionalPlayerList: [UUID?] = playerList
        var elsewhere = Set<UUID>()
        for lineup in try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate {
            playerList.contains($0.playerID) && !matchIDs.contains($0.matchID)
        })) { elsewhere.insert(lineup.playerID) }
        for event in try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate {
            optionalPlayerList.contains($0.playerID) && !matchIDs.contains($0.matchID)
        })) { if let id = event.playerID { elsewhere.insert(id) } }
        for substitution in try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate {
            !matchIDs.contains($0.matchID) && (playerList.contains($0.playerInID) || playerList.contains($0.playerOutID))
        })) { elsewhere.formUnion([substitution.playerInID, substitution.playerOutID]) }
        let onlyHerePlayerIDs = Array(herePlayerIDs.subtracting(elsewhere))
        plan.onlyHerePlayers = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { onlyHerePlayerIDs.contains($0.id) }))
            .filter { !onlyHereTeamIDs.contains($0.teamID) }
        return plan
    }

    /// 大会と試合・記録を消す。teamIDsToDelete のチーム(選手名簿ごと)と playerIDsToDelete の選手も消す。
    @MainActor
    @discardableResult
    static func delete(
        _ tournament: Tournament,
        teamIDsToDelete: Set<UUID>,
        playerIDsToDelete: Set<UUID>,
        context: ModelContext,
        removeImage: @escaping (String) -> Void,
        afterMatchesDeleted: @escaping ([UUID]) -> Void = { _ in }
    ) -> Bool {
        var images: [String] = []
        var deletedMatchIDs: [UUID] = []
        var restores: [() -> Void] = []
        return AppPersistence.transaction(context, restoreVisibleValues: {
            restores.reversed().forEach { $0() }
        }, mutation: {
            let tournamentID = tournament.id
            let matches = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { $0.tournamentID == tournamentID }))
            let matchIDs = matches.map(\.id)
            deletedMatchIDs = matchIDs
            try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { matchIDs.contains($0.matchID) })).forEach { context.delete($0) }
            try context.fetch(FetchDescriptor<MatchLineup>(predicate: #Predicate { matchIDs.contains($0.matchID) })).forEach { context.delete($0) }
            try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate { matchIDs.contains($0.matchID) })).forEach { context.delete($0) }
            matches.forEach { context.delete($0) }

            // 消すチームは、ほかの大会で試合がないことを確かめ直す(画面を開いてから変わっていても安全に)
            let teamList = Array(teamIDsToDelete)
            let stillUsed = try context.fetch(FetchDescriptor<Match>(predicate: #Predicate {
                $0.tournamentID != tournamentID && (teamList.contains($0.homeTeamID) || teamList.contains($0.awayTeamID))
            }))
            guard stillUsed.isEmpty else { throw RecordingWidgetError.invalid("ほかの大会で試合のあるチームは削除できません。") }
            for team in try context.fetch(FetchDescriptor<Team>(predicate: #Predicate { teamList.contains($0.id) })) {
                images += [team.logoPath].compactMap { $0 }
                context.delete(team)
            }
            let playersOfTeams = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { teamList.contains($0.teamID) }))
            let extraList = Array(playerIDsToDelete)
            let extraPlayers = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { extraList.contains($0.id) }))
            for player in playersOfTeams + extraPlayers {
                images += [player.imagePath].compactMap { $0 }
                context.delete(player)
            }
            // ほかの大会の出場チームから、消したチームを外す
            for other in try context.fetch(FetchDescriptor<Tournament>()) where other.id != tournamentID
                && other.teamIDs.contains(where: { teamIDsToDelete.contains($0) }) {
                let original = other.teamIDs
                restores.append { other.teamIDs = original }
                other.teamIDs.removeAll { teamIDsToDelete.contains($0) }
            }
            images += [tournament.logoPath].compactMap { $0 }
            context.delete(tournament)
        }, afterSave: {
            afterMatchesDeleted(deletedMatchIDs)
            SafeDeletion.removeUnreferencedImages(images, context: context, remove: removeImage)
        })
    }
}
