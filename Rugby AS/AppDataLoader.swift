import Foundation
import SwiftData

enum AppDataLoader {
    nonisolated static func openStore(inMemory: Bool) throws -> ModelContainer {
        let container = try ModelContainer(for: Team.self, Player.self, Tournament.self, Match.self,
            StatEvent.self, MatchLineup.self, Substitution.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        // Keep legacy number snapshots correct, using a private context on the
        // loading task rather than blocking SwiftUI's first frame.
        // 公式記録の取り込みで試合が数万になったので、全試合の点検は毎回は行わない。
        // 前回から選手付きの記録・交代が増えた試合だけをここで点検する(数試合なら一瞬)。
        // 全体の点検が要るとき(初回・大量の取り込みの後)は、画面を出してから裏で行う(needsFullNumberCheck)。
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let pending = MatchWorkStore.pending(.numbers)
        if !inMemory && !pending.all && !pending.matchIDs.isEmpty {
            MatchNumbering.freezeNumbers(forMatches: pending.matchIDs, context: context)
            MatchWorkStore.clear(pending, from: .numbers)
        }
        if inMemory { MatchNumbering.freezeLineupNumbers(context: context) }
        if !inMemory { OfficialTournamentGrouping.backfillSeriesNames(context: context) }
        if !inMemory {
            TournamentCategory.backfill(context: context)
            TournamentCategory.backfillGender(context: context)
        }
        if !inMemory { VideoStorage.excludeAllVideosFromBackup() }
        return container
    }

    private static let fullNumberCheckKey = "changes.numbers.initialFullCheck.v1"

    /// 全試合の背番号の点検が要るか(この仕組みを入れて初めての起動か、大量の変更があった後)
    nonisolated static var needsFullNumberCheck: Bool {
        !UserDefaults.standard.bool(forKey: fullNumberCheckKey) || MatchWorkStore.pending(.numbers).all
    }

    /// 全試合の背番号の点検。時間がかかるので、画面を出した後に裏で呼ぶ
    nonisolated static func runFullNumberCheck(container: ModelContainer) {
        let pending = MatchWorkStore.pending(.numbers)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        MatchNumbering.freezeLineupNumbers(context: context)
        MatchWorkStore.clear(pending, from: .numbers)
        UserDefaults.standard.set(true, forKey: fullNumberCheckKey)
    }
}
