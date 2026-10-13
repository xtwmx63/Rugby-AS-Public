//
//  ModelChangeTracker.swift
//  Rugby AS
//
//  保存のたびに「どの試合の記録が変わったか」を覚えておく係。
//  公式記録の取り込みで試合が2万を超えたため、起動時の背番号の点検や試合一覧の得点集計を
//  毎回全試合ぶん行うと、起動に1分近くかかっていた。変わった試合だけを処理するために使う。
//
//  覚えた内容は端末設定(UserDefaults)に残すので、アプリを閉じても次の起動で続きを処理できる。
//  一度にたくさん変わったとき(取り込み・復元など)や、どの試合か分からない変更は「全部」として扱う
//  (そのときは画面を止めずに、裏で全体をやり直す)。
//

import Foundation
import SwiftData

/// 処理が必要な試合
nonisolated struct PendingMatchWork: Equatable, Sendable {
    var matchIDs: Set<UUID> = []
    /// どの試合か特定できない変更があった(全試合をやり直す)
    var all = false
    /// 書き足すたびに増える番号。処理している間に新しい変更が入ったかを見分ける
    var version = 0

    var isEmpty: Bool { !all && matchIDs.isEmpty }
}

/// 何のためにやり直すか(目的ごとに別々に覚え、別々に片付ける)
nonisolated enum MatchWorkKind: String, Sendable {
    /// 試合一覧の得点(記録の追加・変更・削除、試合の対戦チームの変更で変わる)
    case tallies
    /// 背番号の控え(選手付きの記録・交代が増えたときに作る)
    case numbers
}

nonisolated enum MatchWorkStore {
    /// これ以上の試合が一度に変わったら「全部」として扱う(覚える量を抑えるため)
    static let matchLimit = 300

    private static func idsKey(_ kind: MatchWorkKind) -> String { "changes.\(kind.rawValue).matchIDs" }
    private static func allKey(_ kind: MatchWorkKind) -> String { "changes.\(kind.rawValue).all" }
    private static func versionKey(_ kind: MatchWorkKind) -> String { "changes.\(kind.rawValue).version" }

    static func pending(_ kind: MatchWorkKind, defaults: UserDefaults = .standard) -> PendingMatchWork {
        let ids = (defaults.stringArray(forKey: idsKey(kind)) ?? []).compactMap(UUID.init(uuidString:))
        return PendingMatchWork(matchIDs: Set(ids), all: defaults.bool(forKey: allKey(kind)),
                                version: defaults.integer(forKey: versionKey(kind)))
    }

    static func add(_ work: PendingMatchWork, to kind: MatchWorkKind, defaults: UserDefaults = .standard) {
        guard !work.isEmpty else { return }
        var current = pending(kind, defaults: defaults)
        current.all = current.all || work.all
        current.matchIDs.formUnion(work.matchIDs)
        if current.matchIDs.count > matchLimit { current.all = true }
        if current.all { current.matchIDs = [] }
        current.version += 1
        save(current, kind: kind, defaults: defaults)
    }

    /// 処理し終えた分を消す。処理している間に新しい変更が入っていたら、その分は残す
    static func clear(_ handled: PendingMatchWork, from kind: MatchWorkKind, defaults: UserDefaults = .standard) {
        var current = pending(kind, defaults: defaults)
        if current.version == handled.version {
            current.matchIDs = []
            current.all = false
        } else if !handled.all {
            // 新しい変更が入った。処理した試合だけ消し、「全部」の印はそのまま(もう一度やり直す)
            current.matchIDs.subtract(handled.matchIDs)
        }
        save(current, kind: kind, defaults: defaults)
    }

    private static func save(_ work: PendingMatchWork, kind: MatchWorkKind, defaults: UserDefaults) {
        defaults.set(work.matchIDs.map(\.uuidString), forKey: idsKey(kind))
        defaults.set(work.all, forKey: allKey(kind))
        defaults.set(work.version, forKey: versionKey(kind))
    }
}

/// 保存の知らせを受けて、変わった試合を MatchWorkStore に書き足す
@MainActor
final class ModelChangeTracker {
    static let shared = ModelChangeTracker()
    /// 覚えた内容が変わったときの合図(試合一覧が得点を更新するのに使う)
    static let didRecord = Notification.Name("RugbyAS.ModelChangeTracker.didRecord")

    /// いま開いている試合。記録の削除は、どの試合のものか保存の知らせからは分からないため、
    /// 試合の画面を開いているあいだの削除はその試合のものとして扱う
    var activeMatchID: UUID?

    private var container: ModelContainer?
    private var observer: NSObjectProtocol?

    func start(container: ModelContainer) {
        guard observer == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let changes = SavedChanges(note)
            MainActor.assumeIsolated { self?.record(changes) }
        }
    }

    /// 保存の知らせの中身(変わったデータの印)。知らせは裏からも届くので、値だけを取り出して渡す
    struct SavedChanges: @unchecked Sendable {
        let changed: [PersistentIdentifier]
        let deleted: [PersistentIdentifier]

        init(_ note: Notification) {
            let info = note.userInfo ?? [:]
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                info[key.rawValue] as? [PersistentIdentifier] ?? []
            }
            changed = ids(.insertedIdentifiers) + ids(.updatedIdentifiers)
            deleted = ids(.deletedIdentifiers)
        }
    }

    func record(_ changes: SavedChanges) {
        guard let container else { return }
        // 調べるたびに新しい作業場所を使う(古い値を持ち越さず、読んだデータを溜め込まないように)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var tallies = PendingMatchWork()
        var numbers = PendingMatchWork()
        let relevant = changes.changed.filter { ["StatEvent", "Match", "Substitution"].contains($0.entityName) }
        let deletedEvents = changes.deleted.filter { $0.entityName == "StatEvent" }
        let deletedMatches = changes.deleted.contains { $0.entityName == "Match" }

        if relevant.count > MatchWorkStore.matchLimit {
            // 取り込みや復元などの大量の変更。1件ずつ調べると時間がかかるので、全体をやり直す
            tallies.all = true
            if relevant.contains(where: { $0.entityName != "Match" }) { numbers.all = true }
        } else {
            // 印から読み直す。知らせが届くまでに消えたものは読めないので飛ばす
            // (消えた分は、消したときの保存の知らせで扱う)
            let eventIDs = relevant.filter { $0.entityName == "StatEvent" }
            let substitutionIDs = relevant.filter { $0.entityName == "Substitution" }
            let matchIDs = relevant.filter { $0.entityName == "Match" }
            do {
                if !eventIDs.isEmpty {
                    for event in try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { eventIDs.contains($0.persistentModelID) })) {
                        tallies.matchIDs.insert(event.matchID)
                        if event.playerID != nil { numbers.matchIDs.insert(event.matchID) }
                    }
                }
                if !substitutionIDs.isEmpty {
                    for substitution in try context.fetch(FetchDescriptor<Substitution>(predicate: #Predicate { substitutionIDs.contains($0.persistentModelID) })) {
                        numbers.matchIDs.insert(substitution.matchID)
                    }
                }
                if !matchIDs.isEmpty {
                    for match in try context.fetch(FetchDescriptor<Match>(predicate: #Predicate { matchIDs.contains($0.persistentModelID) })) {
                        tallies.matchIDs.insert(match.id)
                    }
                }
            } catch {
                // 読めなかったときは、取りこぼさないよう全体をやり直す
                tallies.all = true
                numbers.all = true
            }
        }
        // 記録の削除: 試合ごと消したときは得点を数え直す必要はない。
        // 試合の画面を開いているならその試合、そうでなければどの試合か分からないので全体
        if !deletedEvents.isEmpty && !deletedMatches {
            if let activeMatchID { tallies.matchIDs.insert(activeMatchID) } else { tallies.all = true }
        }

        guard !tallies.isEmpty || !numbers.isEmpty else { return }
        MatchWorkStore.add(tallies, to: .tallies)
        MatchWorkStore.add(numbers, to: .numbers)
        NotificationCenter.default.post(name: Self.didRecord, object: nil)
    }
}
