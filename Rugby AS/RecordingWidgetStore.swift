import Combine
import Foundation
import SwiftData

// widgetData は JSON で持っている。並べ替えや一覧では記録1件につき何度も
// 中身を見るため、毎回ほどくと記録が増えるほど重くなる。
// ほどいた結果を、元の JSON と一緒に控えておいて使い回す
// (元の JSON が変わっていたら作り直すので、古い内容は出ない)。
nonisolated private final class RecordingDetailsBox: Sendable {
    let source: Data?
    let details: RecordingEventDetails
    init(source: Data?, details: RecordingEventDetails) {
        self.source = source
        self.details = details
    }
}

// NSCache synchronizes access; boxes contain only immutable Sendable values.
nonisolated(unsafe) private let recordingDetailsCache: NSCache<NSUUID, RecordingDetailsBox> = {
    let cache = NSCache<NSUUID, RecordingDetailsBox>()
    cache.countLimit = 4096
    return cache
}()

// 分析の計算は裏でも行うので、記録の中身を読む部分は画面に縛らない
nonisolated extension StatEvent {
    var recordingOrigin: PlayOrigin? { PlayOrigin.recorded(origin) }
    var recordingDetails: RecordingEventDetails {
        get {
            let key = id as NSUUID
            let stored = widgetData
            if let box = recordingDetailsCache.object(forKey: key), box.source == stored { return box.details }
            let details = RecordingEventDetails.decoded(from: stored)
            recordingDetailsCache.setObject(RecordingDetailsBox(source: stored, details: details), forKey: key)
            return details
        }
        set {
            widgetData = try? JSONEncoder().encode(newValue)
            // 控えは捨てるだけにする。次に読むときに JSON からほどき直すので、
            // 「保存した値」と「読み戻した値」が食い違うことがない。
            recordingDetailsCache.removeObject(forKey: id as NSUUID)
        }
    }
}

extension StatEvent {
    var recordingTitle: String { Self.recordingTitle(category: category, customTitle: recordingDetails.title) }

    /// 記録の表示名。記録に付けた名前があればそれ、なければ種類ごとの名前
    static func recordingTitle(category: String, customTitle: String?) -> String {
        if let customTitle { return customTitle }
        return ["try": "トライ", "tackle": "タックル", "conversion": "コンバージョン",
                "penalty_goal": "PG", "drop_goal": "DG", ScoringRules.penaltyTryCategory: "認定トライ", "lineout": "ラインアウト",
                "scrum": "スクラム", "kick": "キック", "penalty": "反則", "review": "要確認"] [category]
            ?? RecordingMetricCatalog.titlesByCategory[category] ?? category
    }
}

// Undo は1操作単位。同時ONで作成された記録もまとめて戻す。
private struct RecordingEventSnapshot: Equatable {
    let id: UUID
    let teamID: UUID?
    let playerID: UUID?
    let category: String
    let outcome: String
    let seconds: Int
    let startSeconds: Int?
    let startSecondsExact: Double?
    let durationSecondsExact: Double?
    let half: Int
    let origin: String?
    let widgetData: Data?
    let recordedAt: Date
    init(_ event: StatEvent) {
        id = event.id; teamID = event.teamID; playerID = event.playerID
        category = event.category; outcome = event.outcome; seconds = event.seconds
        startSeconds = event.startSeconds; half = event.half; origin = event.origin; widgetData = event.widgetData
        startSecondsExact = event.startSecondsExact; durationSecondsExact = event.durationSecondsExact
        recordedAt = event.recordingDetails.recordedAt
    }
    func isRecordedBefore(_ other: Self) -> Bool {
        let time = category == "possession" ? startSeconds ?? 0 : seconds
        let otherTime = other.category == "possession" ? other.startSeconds ?? 0 : other.seconds
        return (half, time, recordedAt, id.uuidString) < (other.half, otherTime, other.recordedAt, other.id.uuidString)
    }
    func apply(to event: StatEvent) {
        event.teamID = teamID; event.playerID = playerID; event.category = category
        event.outcome = outcome; event.seconds = seconds; event.startSeconds = startSeconds
        event.half = half; event.origin = origin; event.widgetData = widgetData
        event.startSecondsExact = startSecondsExact; event.durationSecondsExact = durationSecondsExact
    }
}

@MainActor
final class RecordingWidgetStore: ObservableObject {
    @Published private(set) var layout: RecordingLayout
    @Published private(set) var session: RecordingSession
    @Published private(set) var revision = 0
    @Published private(set) var canUndo = false
    // この試合の記録の控え。以前は events を読むたびに DB へ問い合わせていたが、
    // ボード上のカードは1枚ごとに events を見るので、1回の描画で何十回も
    // 問い合わせが走り、タップのたびに固まる原因になっていた。
    // 記録が変わるのは保存したときだけなので、そのときだけ読み直す。
    @Published private(set) var events: [StatEvent] = []
    private var loadedEventSnapshots: [UUID: RecordingEventSnapshot] = [:]
    private var eventsByID: [UUID: StatEvent] = [:]
    private var possessionEventsByID: [UUID: StatEvent] = [:]
    private var contextSaveObserver: AnyCancellable?
    private var isPerformingSave = false
    private var needsExternalRefresh = false
    private struct MetricKey: Hashable {
        let teamID: UUID
        let category: String
    }
    private var eventsByMetric: [MetricKey: [StatEvent]] = [:]
    private var countsByMetric: [MetricKey: Int] = [:]
    private var summariesByMetric: [MetricKey: RecordingMetricSummary] = [:]
    private var latestByTeam: [UUID: StatEvent] = [:]
    private var recentByTeam: [UUID: [StatEvent]] = [:]
    private var scoresByTeam: [UUID: Int] = [:]
    private var leadersByTeam: [UUID: (playerID: UUID, points: Int, eventIDs: [UUID])] = [:]
    // 保存済みポゼッション時間の合計(HOME / AWAY / BIP)。時計の表示で毎秒使う。
    private var savedPossessionSeconds: [RecordingTimerTarget: Double] = [:]
    private var savedBIPInterval: RecordingActiveInterval?
    @Published var error: String?
    let match: Match
    let context: ModelContext
    private var undoFrame: (session: RecordingSession, events: [UUID: RecordingEventSnapshot])?

    init(match: Match, context: ModelContext, initialSeconds: Int = 0, initialHalf: Int = 0) {
        self.match = match; self.context = context
        if let data = match.recordingLayoutData,
           let saved = try? JSONDecoder().decode(RecordingLayout.self, from: data),
           let valid = try? saved.validated() {
            layout = valid
        } else {
            layout = .standard
            if match.recordingLayoutData != nil { error = "保存したレイアウトを読めませんでした。標準表示で開きました。" }
        }
        if let data = match.recordingSessionData, let saved = try? JSONDecoder().decode(RecordingSession.self, from: data) {
            session = saved
        } else {
            session = RecordingSession(clock: RecordingClock(accumulated: Double(initialSeconds), half: initialHalf))
        }
        // 従来画面で時計が進んだ場合は、その時刻を引き継ぐ。
        if initialHalf > session.clock.half || (initialHalf == session.clock.half && Double(initialSeconds) > session.clock.elapsed(at: .now)) {
            session.clock = RecordingClock(accumulated: Double(initialSeconds), half: initialHalf)
        }
        // セッション保存に対応する前の試合も、最後の記録より前には戻さない。
        if session.selectedTeamID != match.homeTeamID && session.selectedTeamID != match.awayTeamID {
            session.selectedTeamID = match.homeTeamID
        }
        reloadEvents()
        session.clock.advanceToRecordedEvents(events)
        // The owning context is main-actor confined. Saves outside this store must
        // invalidate the cache, while our own saves have an explicit change set.
        contextSaveObserver = NotificationCenter.default.publisher(for: ModelContext.willSave, object: context)
            .sink { [weak self] _ in
                guard let self, !self.isPerformingSave else { return }
                self.needsExternalRefresh = true
            }
    }

    var selectedTeamID: UUID { session.selectedTeamID ?? match.homeTeamID }
    var latestEvent: StatEvent? { latestByTeam[selectedTeamID] }
    var recentEvents: [StatEvent] {
        let team = selectedTeamID
        if let cached = recentByTeam[team] { return cached }
        let sorted = events.filter { $0.category != "possession" && $0.category != "match_state" && $0.teamID == team }
            .sorted { $1.isRecordedBefore($0) }
        recentByTeam[team] = sorted
        return sorted
    }

    /// Only timed clips have deadlines. The view waits for this date instead of polling five times a second.
    var nextIntervalExpiration: Date? { session.active.compactMap(\.endsAt).min() }

    func teamID(for widget: RecordingWidgetDefinition) -> UUID {
        widget.scope == .home ? match.homeTeamID : widget.scope == .away ? match.awayTeamID : selectedTeamID
    }
    func latestEvent(for widget: RecordingWidgetDefinition) -> StatEvent? {
        latestByTeam[teamID(for: widget)]
    }
    func matchingEvents(_ widget: RecordingWidgetDefinition) -> [StatEvent] {
        eventsByMetric[MetricKey(teamID: teamID(for: widget), category: widget.category)] ?? []
    }
    func count(_ widget: RecordingWidgetDefinition) -> Int {
        countsByMetric[MetricKey(teamID: teamID(for: widget), category: widget.category)] ?? 0
    }
    func summary(_ widget: RecordingWidgetDefinition) -> RecordingMetricSummary {
        let key = MetricKey(teamID: teamID(for: widget), category: widget.category)
        if let cached = summariesByMetric[key] { return cached }
        let summary = RecordingMetricAggregation.summary(events: eventsByMetric[key] ?? [], category: widget.category)
        summariesByMetric[key] = summary
        return summary
    }
    func score(teamID: UUID) -> Int {
        scoresByTeam[teamID] ?? 0
    }
    func scoringLeader(teamID: UUID) -> (playerID: UUID, points: Int, eventIDs: [UUID])? {
        leadersByTeam[teamID]
    }
    func activeInterval(_ widget: RecordingWidgetDefinition) -> RecordingActiveInterval? {
        session.active.first { $0.id == intervalKey(widget) }
    }
    func timerTotal(_ target: RecordingTimerTarget, at date: Date) -> Double {
        // 時計の表示更新では、保存済みの合計は記録が変わるまで動かないので
        // 控えから引き、走っている区間ぶんだけをその場で足す。
        let saved = savedPossessionSeconds[target] ?? 0
        let running = session.active.first { $0.id == target.rawValue }.map { max(0, date.timeIntervalSince($0.startedAt)) } ?? 0
        return saved + running
    }

    func selectTeam(_ teamID: UUID) {
        if needsExternalRefresh { reloadEvents(invalidateExternalUndo: true) }
        guard selectedTeamID != teamID else { return }
        perform(rememberUndo: false) { session.selectedTeamID = teamID }
    }
    func saveLayout(_ draft: RecordingLayout) -> Bool {
        do {
            let valid = try draft.validated()
            guard session.active.isEmpty else {
                throw RecordingWidgetError.invalid("計測を停止してからレイアウトを保存してください。")
            }
            let previous = layout
            layout = valid
            do { match.recordingLayoutData = try JSONEncoder().encode(valid); try context.save(); revision += 1; return true }
            catch { layout = previous; context.rollback(); throw error }
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func activate(_ widget: RecordingWidgetDefinition, outcome: String = "success", at date: Date = .now) -> StatEvent? {
        var created: StatEvent?
        perform {
            if widget.kind == .possession, activeInterval(widget) != nil {
                stop(key: intervalKey(widget), at: date)
                return
            }
            if widget.kind == .timed, let index = session.active.firstIndex(where: { $0.id == intervalKey(widget) }) {
                session.active[index].endsAt = date.addingTimeInterval(widget.lagTime)
                return // 延長は同じ1件。カウントやON連動を重複させない。
            }
            let plan = try RecordingRuleEngine.plan(source: widget.id, layout: layout)
            for id in plan.stop {
                if let target = layout.widgets.first(where: { $0.id == id }) { stop(key: intervalKey(target), at: date) }
            }
            for id in plan.start {
                guard let target = layout.widgets.first(where: { $0.id == id }) else { continue }
                let event = start(target, outcome: outcome, at: date)
                if id == widget.id { created = event }
            }
        }
        return created
    }

    /// Validate and save the complete input as one undoable operation; opening a menu creates no record.
    @discardableResult
    func submitInput(_ widget: RecordingWidgetDefinition, number: Double? = nil, choice: String? = nil,
                     playerID: UUID? = nil, zone: Int? = nil, attackUp: Bool = true) -> Bool {
        perform {
            guard [.number, .choice, .player, .zone].contains(widget.kind) else {
                throw RecordingWidgetError.invalid("この項目は直接入力に対応していません。")
            }
            let event: StatEvent
            if widget.attachesToLatest {
                guard let latest = latestEvent(for: widget) else {
                    throw RecordingWidgetError.invalid("先に対象チームのプレーを1件記録してください。")
                }
                event = latest
            } else {
                guard let created = start(widget, outcome: "success", at: .now) else { return }
                event = created
            }
            var details = event.recordingDetails
            switch widget.kind {
            case .number:
                let minimum: Double = event.category == "carry_metres" ? -1_000_000 : 0
                guard let number, number.isFinite, (minimum...1_000_000).contains(number) else {
                    throw RecordingWidgetError.invalid("有効な数値を入力してください（最大1,000,000）。")
                }
                details.number = number; details.unit = widget.unit
            case .choice:
                guard let choice else { throw RecordingWidgetError.invalid("選択肢を選んでください。") }
                if widget.category == "origin" {
                    guard PlayOrigin(rawValue: choice) != nil else { throw RecordingWidgetError.invalid("起点を選んでください。") }
                    event.origin = choice
                } else {
                    guard widget.choices.contains(choice) else { throw RecordingWidgetError.invalid("選択肢を確認してください。") }
                    details.choice = choice
                }
            case .player:
                guard let playerID,
                      let player = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.id == playerID })).first,
                      player.teamID == event.teamID else {
                    throw RecordingWidgetError.invalid("記録したチームの選手を選択してください。")
                }
                event.playerID = playerID
            case .zone:
                guard let zone, (0..<9).contains(zone) else { throw RecordingWidgetError.invalid("場所を選んでください。") }
                details.zone = zone; details.attackUp = attackUp
            default: break
            }
            event.recordingDetails = details
        }
    }

    func eventForInput(_ widget: RecordingWidgetDefinition) -> StatEvent? {
        if widget.attachesToLatest {
            if let latest = latestEvent(for: widget) { return latest }
            if widget.kind != .note {
                error = "先にプレーを1件記録してください。選手や場所は、その記録に追加できます。"
                return nil
            }
        }
        return activate(widget)
    }

    /// 新規入力シートが保存されずに閉じられたときだけ呼ぶ。既存記録への追記には使わない。
    @discardableResult
    func discardUnconfirmedEvent(_ event: StatEvent) -> Bool {
        guard event.matchID == match.id else { return false }
        let discarded = perform(rememberUndo: false) {
            if let pending = try fetchEvents().first(where: { $0.id == event.id }) {
                context.delete(pending)
            }
        }
        if discarded {
            // 破棄した新規入力が、直前の編集スナップショットから復活することを防ぐ。
            undoFrame = nil
            canUndo = false
        }
        return discarded
    }

    func updateEvent(_ event: StatEvent, playerID: UUID?, details: RecordingEventDetails, outcome: String? = nil,
                     seconds: Int? = nil, half: Int? = nil, origin: String? = nil, clearOrigin: Bool = false) -> Bool {
        perform {
            if let playerID {
                let player = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.id == playerID })).first
                guard let player, player.teamID == event.teamID else {
                    throw RecordingWidgetError.invalid("記録したチームの選手を選択してください。")
                }
            }
            let minimum: Double = event.category == "carry_metres" ? -1_000_000 : 0
            if let number = details.number, !number.isFinite || number < minimum || number > 1_000_000 {
                throw RecordingWidgetError.invalid(minimum < 0 ? "数値は−1,000,000〜1,000,000の範囲で入力してください。" : "数値は0〜1,000,000の範囲で入力してください。")
            }
            event.playerID = playerID
            event.recordingDetails = details
            if let outcome { event.outcome = outcome }
            if let seconds { event.seconds = max(0, seconds) }
            if let half { event.half = min(1, max(0, half)) }
            if clearOrigin { event.origin = nil }
            else if let origin { event.origin = origin }
        }
    }

    func toggleClock(at date: Date = .now) {
        perform {
            session.measurementRevision = (session.measurementRevision ?? 0) + 1
            if session.clock.startedAt == nil { session.clock.start(at: date) }
            else { stopAll(at: date); session.clock.pause(at: date) }
        }
    }
    @discardableResult
    func pause(at date: Date = .now) -> Bool {
        guard session.clock.startedAt != nil || !session.active.isEmpty else { return true }
        return perform(rememberUndo: false) {
            session.measurementRevision = (session.measurementRevision ?? 0) + 1
            stopAll(at: date); session.clock.pause(at: date)
        }
    }
    func nextHalf(at date: Date = .now) {
        guard session.clock.half == 0 else { return }
        perform {
            session.measurementRevision = (session.measurementRevision ?? 0) + 1
            stopAll(at: date)
            context.insert(StatEvent(matchID: match.id, category: "match_state", outcome: "half_finished",
                seconds: Int(session.clock.elapsed(at: date)), half: 0))
            session.clock = RecordingClock(half: 1)
        }
    }
    func finish(at date: Date = .now) -> Bool {
        perform {
            session.measurementRevision = (session.measurementRevision ?? 0) + 1
            stopAll(at: date); session.clock.pause(at: date)
            let marker = StatEvent(matchID: match.id, category: "match_state", outcome: "finished",
                                   seconds: Int(session.clock.accumulated), half: session.clock.half)
            context.insert(marker)
        }
    }
    func reconcile(at date: Date = .now) {
        let expired = session.active.filter { $0.endsAt.map { $0 <= date } ?? false }
        guard !expired.isEmpty else { return }
        perform(rememberUndo: false) {
            for item in expired { stop(key: item.id, at: item.endsAt ?? date) }
        }
    }
    func refresh() { reloadEvents(invalidateExternalUndo: true); reconcile() }

    func undo() {
        if needsExternalRefresh { reloadEvents() }
        guard let frame = undoFrame else { return }
        let successful = perform(rememberUndo: false) {
            let desired = Set(frame.events.keys)
            for (id, event) in eventsByID where !desired.contains(id) { context.delete(event) }
            for snapshot in frame.events.values {
                guard loadedEventSnapshots[snapshot.id] != snapshot else { continue }
                let event: StatEvent
                if let existing = eventsByID[snapshot.id] { event = existing }
                else {
                    event = StatEvent(id: snapshot.id, matchID: match.id, category: snapshot.category,
                                      outcome: snapshot.outcome, seconds: snapshot.seconds)
                    context.insert(event)
                }
                snapshot.apply(to: event)
            }
            session = frame.session
        }
        if successful { undoFrame = nil; canUndo = false; reconcile() }
    }

    private func intervalKey(_ widget: RecordingWidgetDefinition) -> String {
        widget.kind == .possession ? widget.timerTarget.rawValue : widget.id.uuidString
    }
    private func fetchEvents() throws -> [StatEvent] {
        let id = match.id
        return try context.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { $0.matchID == id }))
    }
    /// 控えを DB の中身に合わせ直す。保存・取り消し・他画面から戻ったときだけ呼ぶ。
    private func reloadEvents(invalidateExternalUndo: Bool = false) {
        let loaded: [StatEvent]
        do { loaded = try fetchEvents() }
        catch { self.error = "記録を読み込めませんでした。\n" + error.localizedDescription; return }
        let snapshots = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, RecordingEventSnapshot($0)) })
        let recordsChanged = snapshots != loadedEventSnapshots
        if invalidateExternalUndo && recordsChanged {
            // 映像編集など別画面で変わった記録を、古いボードのUndoで消さない。
            undoFrame = nil
            canUndo = false
        }
        if recordsChanged {
            loadedEventSnapshots = snapshots
            eventsByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            possessionEventsByID = eventsByID.filter { snapshots[$0.key]?.category == "possession" }
            rebuildEventIndex()
            events = loaded
        }
        needsExternalRefresh = false
        updatePossessionCache(recordsChanged: recordsChanged)
    }

    /// Local transactions already know exactly which models changed. Avoid fetching
    /// and decoding every saved event after each count or possession toggle.
    private func applySavedChanges(upserts: [StatEvent], deletedIDs: Set<UUID>) {
        var changed = false
        var possessionChanged = false
        for id in deletedIDs {
            if let old = loadedEventSnapshots.removeValue(forKey: id) {
                changed = true
                possessionChanged = possessionChanged || old.category == "possession"
            }
            eventsByID.removeValue(forKey: id)
            possessionEventsByID.removeValue(forKey: id)
        }
        for event in upserts where !deletedIDs.contains(event.id) {
            let snapshot = RecordingEventSnapshot(event)
            let old = loadedEventSnapshots[snapshot.id]
            guard old != snapshot else { continue }
            changed = true
            possessionChanged = possessionChanged || old?.category == "possession" || snapshot.category == "possession"
            loadedEventSnapshots[snapshot.id] = snapshot
            eventsByID[snapshot.id] = event
            if snapshot.category == "possession" { possessionEventsByID[snapshot.id] = event }
            else { possessionEventsByID.removeValue(forKey: snapshot.id) }
        }
        if changed {
            rebuildEventIndex()
            events = Array(eventsByID.values)
        }
        updatePossessionCache(recordsChanged: possessionChanged)
    }

    private func updatePossessionCache(recordsChanged: Bool) {
        let runningBIP = session.active.first { $0.id == RecordingTimerTarget.bip.rawValue }
        if recordsChanged || runningBIP != savedBIPInterval {
            savedBIPInterval = runningBIP
            savedPossessionSeconds = MatchStatistics.possessionTotals(events: Array(possessionEventsByID.values), match: match,
                excludingBIPInterval: runningBIP.map { (half: $0.half, start: $0.matchStart) })
        }
    }

    /// Card drawing only looks up results. Rebuild once when records actually change.
    private func rebuildEventIndex() {
        eventsByMetric.removeAll(keepingCapacity: true)
        countsByMetric.removeAll(keepingCapacity: true)
        summariesByMetric.removeAll(keepingCapacity: true)
        latestByTeam.removeAll(keepingCapacity: true)
        recentByTeam.removeAll(keepingCapacity: true)
        scoresByTeam.removeAll(keepingCapacity: true)
        leadersByTeam.removeAll(keepingCapacity: true)
        var latestSnapshots: [UUID: RecordingEventSnapshot] = [:]
        var scorerTotals: [UUID: [UUID: Int]] = [:]
        var scorerEvents: [UUID: [UUID: [UUID]]] = [:]
        let scoringCategories = Set(ScoringRules.categories)
        for event in loadedEventSnapshots.values {
            guard let teamID = event.teamID, let model = eventsByID[event.id] else { continue }
            let key = MetricKey(teamID: teamID, category: event.category)
            eventsByMetric[key, default: []].append(model)
            if !scoringCategories.contains(event.category) || event.outcome == "success" {
                countsByMetric[key, default: 0] += 1
            }
            if event.category != "possession" && event.category != "match_state",
               latestSnapshots[teamID].map({ $0.isRecordedBefore(event) }) ?? true {
                latestSnapshots[teamID] = event
                latestByTeam[teamID] = model
            }
            let points = RecordingFormatting.score(category: event.category, outcome: event.outcome, widgetData: event.widgetData)
            scoresByTeam[teamID, default: 0] += points
            if points > 0, let playerID = event.playerID {
                scorerTotals[teamID, default: [:]][playerID, default: 0] += points
                scorerEvents[teamID, default: [:]][playerID, default: []].append(event.id)
            }
        }
        for (teamID, totals) in scorerTotals {
            if let leader = totals.max(by: { $0.value == $1.value ? $0.key.uuidString > $1.key.uuidString : $0.value < $1.value }) {
                leadersByTeam[teamID] = (leader.key, leader.value, scorerEvents[teamID]?[leader.key] ?? [])
            }
        }
    }
    private func start(_ widget: RecordingWidgetDefinition, outcome: String, at date: Date) -> StatEvent? {
        if widget.kind == .possession {
            guard widget.timerTarget != .bip || session.clock.startedAt != nil else { return nil }
            session.clock.start(at: date)
            if widget.timerTarget != .bip {
                stop(key: widget.timerTarget == .home ? "away" : "home", at: date)
                startPossession(key: "bip", widgetID: nil, teamID: nil, at: date)
                session.selectedTeamID = widget.timerTarget == .home ? match.homeTeamID : match.awayTeamID
            }
            let team: UUID? = widget.timerTarget == .bip ? nil : widget.timerTarget == .home ? match.homeTeamID : match.awayTeamID
            startPossession(key: widget.timerTarget.rawValue, widgetID: widget.id, teamID: team, at: date)
            return nil
        }
        if widget.kind == .timed {
            if activeInterval(widget) != nil { return nil }
            session.clock.start(at: date)
        }
        let event = StatEvent(matchID: match.id, teamID: teamID(for: widget), category: widget.category,
                              outcome: widget.category == "penalty" ? "conceded" : outcome,
                              seconds: Int(session.clock.elapsed(at: date)), half: session.clock.half)
        var details = RecordingEventDetails()
        details.timeBasis = .halfClock
        details.widgetID = widget.id; details.title = widget.title
        details.leadTime = widget.leadTime; details.lagTime = widget.lagTime; details.recordedAt = date
        details.needsReview = widget.kind == .note
        event.recordingDetails = details
        context.insert(event)
        if widget.kind == .timed {
            session.active.append(RecordingActiveInterval(id: widget.id.uuidString, widgetID: widget.id, eventID: event.id,
                teamID: event.teamID, half: event.half, startedAt: date, matchStart: session.clock.elapsed(at: date),
                endsAt: date.addingTimeInterval(widget.lagTime), duration: widget.lagTime))
        }
        return event
    }
    private func startPossession(key: String, widgetID: UUID?, teamID: UUID?, at date: Date) {
        guard !session.active.contains(where: { $0.id == key }) else { return }
        session.measurementRevision = (session.measurementRevision ?? 0) + 1
        session.active.append(RecordingActiveInterval(id: key, widgetID: widgetID, teamID: teamID,
            half: session.clock.half, startedAt: date, matchStart: session.clock.elapsed(at: date)))
    }
    private func stop(key: String, at date: Date) {
        if key == "bip" { stop(key: "home", at: date); stop(key: "away", at: date) }
        guard let index = session.active.firstIndex(where: { $0.id == key }) else { return }
        session.measurementRevision = (session.measurementRevision ?? 0) + 1
        let interval = session.active.remove(at: index)
        let end = min(date, interval.endsAt ?? date)
        let duration = max(0, end.timeIntervalSince(interval.startedAt))
        if let eventID = interval.eventID, let event = events.first(where: { $0.id == eventID }) {
            var details = event.recordingDetails
            details.intervalDuration = duration
            event.recordingDetails = details
        } else if ["home", "away", "bip"].contains(key), duration > 0 {
            let event = StatEvent(matchID: match.id, teamID: interval.teamID, category: "possession",
                outcome: interval.teamID == nil ? "none" : "own", seconds: Int(duration),
                startSeconds: Int(interval.matchStart), half: interval.half, origin: interval.origin,
                startSecondsExact: interval.matchStart, durationSecondsExact: duration)
            var details = RecordingEventDetails()
            details.timeBasis = .halfClock
            details.recordedAt = date
            event.recordingDetails = details
            context.insert(event)
        }
    }
    private func stopAll(at date: Date) {
        for key in session.active.map(\.id) { stop(key: key, at: date) }
    }
    @discardableResult
    private func perform(rememberUndo: Bool = true, _ change: () throws -> Void) -> Bool {
        if needsExternalRefresh { reloadEvents(invalidateExternalUndo: true) }
        let previous = session
        isPerformingSave = true
        defer { isPerformingSave = false }
        do {
            // Value snapshots share storage until actual records change. Draft selections
            // must not read every SwiftData property again just to support Undo.
            let snapshots = rememberUndo ? loadedEventSnapshots : [:]
            try change()
            match.recordingSessionData = try JSONEncoder().encode(session)
            let upserts = (context.insertedModelsArray + context.changedModelsArray).compactMap { $0 as? StatEvent }
                .filter { $0.matchID == match.id }
            let deletedIDs = Set(context.deletedModelsArray.compactMap { $0 as? StatEvent }
                .filter { $0.matchID == match.id }.map(\.id))
            try context.save()
            applySavedChanges(upserts: upserts, deletedIDs: deletedIDs)
            if rememberUndo { undoFrame = (previous, snapshots); canUndo = true }
            revision += 1
            return true
        } catch {
            context.rollback(); session = previous
            reloadEvents()
            self.error = "保存できませんでした。\n" + error.localizedDescription
            return false
        }
    }
}

extension RecordingWidgetStore {
    @discardableResult
    func beginTry(_ widget: RecordingWidgetDefinition, at date: Date = .now) -> Bool {
        guard widget.category == "try" else { return false }
        if let flow = session.scoringFlow, !flow.isComplete { return true }
        return perform {
            let previous = session.active.filter { ["home", "away", "bip"].contains($0.id) }
            let existing = Set(context.insertedModelsArray.compactMap { ($0 as? StatEvent)?.id })
            let flow = RecordingScoringFlow(widget: widget, teamID: teamID(for: widget),
                half: session.clock.half, seconds: Int(session.clock.elapsed(at: date)), recordedAt: date,
                origin: previous.first { $0.teamID == teamID(for: widget) }?.origin,
                previousIntervals: previous, measurementRevision: 0)
            stop(key: "bip", at: date)
            var pending = flow
            pending.stoppedEventIDs = context.insertedModelsArray.compactMap { $0 as? StatEvent }
                .filter { $0.matchID == match.id && !existing.contains($0.id) }.map(\.id)
            pending.measurementRevision = session.measurementRevision ?? 0
            session.scoringFlow = pending
        }
    }

    @discardableResult
    func setScoringPlayer(_ playerID: UUID?, flowID: UUID) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID else { return false }
        return perform {
            try validateScoringPlayer(playerID, teamID: flow.teamID)
            if flow.tryID == nil { session.scoringFlow?.scorerID = playerID }
            else {
                session.scoringFlow?.kickerID = playerID
                if let id = flow.conversionID, let event = events.first(where: { $0.id == id }) {
                    event.playerID = playerID
                    var details = event.recordingDetails; details.needsReview = playerID == nil
                    event.recordingDetails = details
                }
            }
        }
    }

    func setTryOrigin(_ origin: String?, flowID: UUID) {
        guard session.scoringFlow?.id == flowID, session.scoringFlow?.tryID == nil else { return }
        perform { session.scoringFlow?.origin = origin }
    }

    @discardableResult
    func confirmTry(flowID: UUID) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, flow.tryID == nil else { return false }
        return perform {
            try validateScoringPlayer(flow.scorerID, teamID: flow.teamID)
            let event = StatEvent(matchID: match.id, teamID: flow.teamID, playerID: flow.scorerID,
                category: "try", outcome: "success", seconds: flow.seconds, half: flow.half, origin: flow.origin)
            var details = RecordingEventDetails()
            details.widgetID = flow.widget.id; details.title = flow.widget.title
            details.timeBasis = .halfClock; details.recordedAt = flow.recordedAt
            details.leadTime = flow.widget.leadTime; details.lagTime = flow.widget.lagTime
            details.needsReview = flow.scorerID == nil
            event.recordingDetails = details
            context.insert(event)
            session.scoringFlow?.tryID = event.id
        }
    }

    @discardableResult
    func recordConversionTime(flowID: UUID, at date: Date = .now) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, flow.tryID != nil,
              !flow.isComplete else { return false }
        return perform {
            try validatePendingTry(flow)
            session.scoringFlow?.kickSeconds = Int(session.clock.elapsed(at: date))
            session.scoringFlow?.kickHalf = session.clock.half
            session.scoringFlow?.kickRecordedAt = date
        }
    }

    @discardableResult
    func correctConversionTime(flowID: UUID, clockText: String) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, flow.kickSeconds != nil, !flow.isComplete else { return false }
        let parts = clockText.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              (0...999).contains(minutes), (0...59).contains(seconds),
              flow.kickHalf != flow.half || minutes * 60 + seconds >= flow.seconds else {
            error = "トライ以降の時刻を分:秒で入力してください。"
            return false
        }
        return perform { session.scoringFlow?.kickSeconds = minutes * 60 + seconds }
    }

    @discardableResult
    func completeConversion(flowID: UUID, success: Bool) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, let seconds = flow.kickSeconds,
              let half = flow.kickHalf, !flow.isComplete else { return false }
        return perform {
            try validatePendingTry(flow)
            try validateScoringPlayer(flow.kickerID, teamID: flow.teamID)
            let event = StatEvent(matchID: match.id, teamID: flow.teamID, playerID: flow.kickerID,
                category: "conversion", outcome: success ? "success" : "fail", seconds: seconds, half: half)
            var details = RecordingEventDetails()
            details.relatedTryID = flow.tryID; details.title = "コンバージョン"
            details.timeBasis = .halfClock; details.recordedAt = flow.kickRecordedAt ?? flow.recordedAt
            details.needsReview = flow.kickerID == nil
            event.recordingDetails = details
            context.insert(event)
            session.scoringFlow?.conversionID = event.id
        }
    }

    @discardableResult
    func declineConversion(flowID: UUID) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, flow.tryID != nil, !flow.isComplete else { return false }
        return perform { session.scoringFlow?.conversionDeclined = true }
    }

    /// 入力中・確定後のどちらのトライも認定トライ(7点1件)に変える。
    /// 通常トライと、あればコンバージョンの記録を消す。時刻・チーム・起点はトライのものを引き継ぐ。
    @discardableResult
    func recordPenaltyTry(flowID: UUID) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, flow.penaltyTryID == nil else { return false }
        return perform {
            if flow.tryID != nil { try validatePendingTry(flow) }
            for id in [flow.tryID, flow.conversionID].compactMap({ $0 }) {
                if let event = eventsByID[id] { context.delete(event) }
            }
            let event = StatEvent(matchID: match.id, teamID: flow.teamID, playerID: nil,
                category: ScoringRules.penaltyTryCategory, outcome: "success",
                seconds: flow.seconds, half: flow.half, origin: flow.origin)
            var details = RecordingEventDetails()
            details.widgetID = flow.widget.id; details.title = "認定トライ"
            details.timeBasis = .halfClock; details.recordedAt = flow.recordedAt
            details.leadTime = flow.widget.leadTime; details.lagTime = flow.widget.lagTime
            event.recordingDetails = details
            context.insert(event)
            session.scoringFlow?.tryID = nil
            session.scoringFlow?.conversionID = nil
            session.scoringFlow?.conversionDeclined = false
            session.scoringFlow?.penaltyTryID = event.id
        }
    }

    @discardableResult
    func cancelTry(flowID: UUID, accidental: Bool) -> Bool {
        guard let flow = session.scoringFlow, flow.id == flowID, flow.tryID == nil, !flow.isComplete else { return false }
        if accidental && (session.measurementRevision ?? 0) != flow.measurementRevision {
            error = "入力中に計測が変更されています。現在の計測を維持するには「判定による取消」を選択してください。"
            return false
        }
        let saved = perform(rememberUndo: false) {
            if accidental {
                for id in flow.stoppedEventIDs {
                    if let event = eventsByID[id] { context.delete(event) }
                }
                session.active.append(contentsOf: flow.previousIntervals)
            }
            session.scoringFlow = nil
        }
        if saved { undoFrame = nil; canUndo = false }
        return saved
    }

    private func validatePendingTry(_ flow: RecordingScoringFlow) throws {
        guard let id = flow.tryID, let event = eventsByID[id], event.category == "try", event.outcome == "success" else {
            throw RecordingWidgetError.invalid("対象のトライが変更されています。記録一覧を確認してください。")
        }
    }

    private func validateScoringPlayer(_ id: UUID?, teamID: UUID) throws {
        guard let id else { return }
        guard let player = try context.fetch(FetchDescriptor<Player>(predicate: #Predicate { $0.id == id })).first,
              player.teamID == teamID else { throw RecordingWidgetError.invalid("記録したチームの選手を選択してください。") }
    }
}
