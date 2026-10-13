import SwiftUI
import UIKit

struct RecordingLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecordingWidgetStore
    @State private var draft: RecordingLayout
    @State private var tab = 0
    @State private var selectedID: UUID?
    @State private var editing: RecordingWidgetDefinition?
    @State private var showGallery = false
    @State private var showTrial = false
    @State private var message: String?
    @State private var history: [RecordingLayout] = []
    @State private var minimumCanvasRows = 6
    @AppStorage("recording.savedBoardTemplates.v1") private var savedTemplateData = Data()

    init(store: RecordingWidgetStore) {
        self.store = store
        _draft = State(initialValue: store.layout)
        _selectedID = State(initialValue: store.layout.widgets.first?.id)
    }

    private var selected: RecordingWidgetDefinition? { draft.widgets.first { $0.id == selectedID } }
    private var usedRows: Int { RecordingBoardPacking.rowCount(widgets: draft.widgets) }
    private var canvasRows: Int { min(RecordingBoardPacking.maximumRows, max(minimumCanvasRows, usedRows)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    TextField("マイボードの名前", text: $draft.name)
                        .font(.headline).accessibilityLabel("ボード名")
                    Text("\(draft.widgets.count)項目 · \(usedRows)段")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                Picker("編集モード", selection: $tab) {
                    Text("ボード").tag(0)
                    Text("テンプレート").tag(1)
                    Text("連動").tag(2)
                }.pickerStyle(.segmented)
                if tab == 0 { placement }
                else if tab == 1 { templatePicker }
                else { RecordingLinkEditor(layout: $draft) }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            .background(Color(red: 0.02, green: 0.06, blue: 0.12).ignoresSafeArea())
            .navigationTitle("自分の記録ボード").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.saveLayout(draft) { dismiss() }
                        else { message = store.error; store.error = nil }
                    }.bold()
                }
            }
            .sheet(isPresented: $showGallery) {
                RecordingMetricGallery { widget in try add(widget) }
            }
            .sheet(item: $editing) { widget in
                RecordingWidgetSettings(widget: widget, availableWidgets: draft.widgets) { updated in try update(updated) }
            }
            .sheet(isPresented: $showTrial) {
                NavigationStack {
                    RecordingLayoutPreview(layout: draft).padding(12)
                        .navigationTitle("記録ボードを試す").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showTrial = false } } }
                }.preferredColorScheme(.dark)
            }
            .alert("ボードを確認してください", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("閉じる", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private var placement: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("ドラッグで並べ替え · 空きマスへ移動")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    ForEach([4, 6, 8, 10], id: \.self) { rows in
                        Button("\(rows)段を表示") { minimumCanvasRows = rows }
                    }
                } label: { Label("\(canvasRows)段", systemImage: "square.grid.3x3") }
                .font(.caption)
            }
            RecordingPlacementCanvas(layout: draft, rows: canvasRows, selectedID: selectedID,
                                     onSelect: { selectedID = $0 }, onPlace: place)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            selectedTools
            HStack(spacing: 8) {
                Button { showGallery = true } label: {
                    Label("指標を追加", systemImage: "plus").font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent)
                Button { commit(RecordingBoardPacking.compacting(draft)) } label: {
                    Image(systemName: "rectangle.compress.vertical").frame(width: 30, height: 36)
                }.buttonStyle(.bordered).accessibilityLabel("空きマスを詰めて自動整列")
                Button { showTrial = true } label: {
                    Image(systemName: "play.rectangle").frame(width: 30, height: 36)
                }.buttonStyle(.bordered).accessibilityLabel("記録ボードを試す")
                Button {
                    guard let previous = history.popLast() else { return }
                    draft = previous
                    if !draft.widgets.contains(where: { $0.id == selectedID }) { selectedID = draft.widgets.first?.id }
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 36)
                }.buttonStyle(.bordered).disabled(history.isEmpty).accessibilityLabel("配置の編集をひとつ戻す")
            }
        }
    }

    @ViewBuilder
    private var selectedTools: some View {
        if let selected {
            VStack(spacing: 4) {
                HStack {
                    Text(selected.title).font(.subheadline.bold()).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { editing = selected } label: { Label("デザイン・設定", systemImage: "slider.horizontal.3") }
                        .font(.caption.bold()).frame(minHeight: 36)
                    Menu {
                        Button("複製", systemImage: "plus.square.on.square") {
                            do { try add(selected) } catch { message = error.localizedDescription }
                        }
                        Button("この色を全体に適用", systemImage: "paintpalette") { applyAppearance(selected, colorOnly: true) }
                        Button("この形・スタイルを全体に適用", systemImage: "square.on.square") { applyAppearance(selected, colorOnly: false) }
                        Button("ボードから外す", systemImage: "trash", role: .destructive) { remove(selected.id) }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 40, height: 40) }
                    .accessibilityLabel("選択したカードの操作")
                }
                HStack(spacing: 0) {
                    moveButton("arrow.left", label: "左へ移動", x: -1, y: 0)
                    moveButton("arrow.right", label: "右へ移動", x: 1, y: 0)
                    moveButton("arrow.up", label: "上へ移動", x: 0, y: -1)
                    moveButton("arrow.down", label: "下へ移動", x: 0, y: 1)
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(RecordingWidgetSize.allCases) { size in
                            Button(size.title) {
                                var updated = selected; updated.size = size
                                do { try update(updated) } catch { message = error.localizedDescription }
                            }
                        }
                    } label: { Label(selected.size.title, systemImage: "arrow.up.left.and.arrow.down.right").font(.caption) }
                    .frame(minHeight: 40)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text("追加したカードをタップして、色・サイズ・アイコンを編集できます。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func moveButton(_ symbol: String, label: String, x: Int, y: Int) -> some View {
        Button {
            guard let index = draft.widgets.firstIndex(where: { $0.id == selectedID }) else { return }
            let cell = RecordingBoardPacking.cells(widgets: draft.widgets)[index]
            _ = place(draft.widgets[index].id, cell.column + x * cell.width, cell.row + y * cell.height)
        } label: { Image(systemName: symbol).font(.subheadline.bold()).frame(width: 38, height: 40) }
        .accessibilityLabel(label)
    }

    private var templatePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("分析したいテーマから始め、使う指標と見た目を自由に変えられます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { saveTemplate() } label: {
                    Label("このボードをテンプレートに保存", systemImage: "square.and.arrow.down")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                if !savedTemplates.isEmpty {
                    Text("マイテンプレート").font(.headline)
                    ForEach(Array(savedTemplates.enumerated()), id: \.offset) { index, saved in
                        HStack {
                            Button {
                                commit(copyTemplate(saved)); selectedID = draft.widgets.first?.id; tab = 0
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(saved.name).font(.subheadline.bold())
                                    Text("\(saved.widgets.count)項目 · 別の試合でも使えます").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button(role: .destructive) { removeTemplate(at: index) } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }.accessibilityLabel(saved.name + "のテンプレートを削除")
                        }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Text("おすすめの構成").font(.headline)
                ForEach(RecordingLayoutTemplate.all) { template in
                    Button {
                        commit(template.layout)
                        selectedID = draft.widgets.first?.id
                        tab = 0
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: template.symbol).font(.title2).frame(width: 42, height: 42)
                                    .background(.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.title).font(.headline)
                                    Text(template.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.down.left.circle.fill").foregroundStyle(.cyan)
                            }
                            HStack(spacing: 5) {
                                ForEach(Array(template.layout.widgets.prefix(10))) { widget in
                                    RoundedRectangle(cornerRadius: 4).fill(widget.color.color.opacity(0.85)).frame(height: 16)
                                }
                            }.accessibilityHidden(true)
                            Text("\(template.layout.widgets.count)項目 · タップしてこの構成を適用")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
                Button {
                    commit(RecordingLayout(name: "マイボード", widgets: []))
                    selectedID = nil; tab = 0; showGallery = true
                } label: { Label("空のボードから作る", systemImage: "square.dashed").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.bordered)
            }
        }
    }

    private var savedTemplates: [RecordingLayout] {
        let decoded = (try? JSONDecoder().decode([RecordingLayout].self, from: savedTemplateData)) ?? []
        return decoded.compactMap { try? $0.validated() }
    }

    private func saveTemplate() {
        do {
            var saved = try draft.validated()
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if saved.name.isEmpty { saved.name = "マイボード" }
            var templates = savedTemplates.filter { $0.name != saved.name }
            guard savedTemplates.contains(where: { $0.name == saved.name }) || templates.count < 20 else {
                message = "テンプレートは20件まで保存できます。不要なテンプレートを削除するか、同じ名前で更新してください。"
                return
            }
            templates.insert(saved, at: 0)
            savedTemplateData = try JSONEncoder().encode(templates)
            message = "「" + saved.name + "」を保存しました。別の試合のマイテンプレートからも使えます。同じ名前で保存すると更新されます。"
        } catch { message = error.localizedDescription }
    }

    private func removeTemplate(at index: Int) {
        var templates = savedTemplates
        guard templates.indices.contains(index) else { return }
        templates.remove(at: index)
        do { savedTemplateData = try JSONEncoder().encode(templates) }
        catch { message = error.localizedDescription }
    }

    private func copyTemplate(_ saved: RecordingLayout) -> RecordingLayout {
        var copy = saved
        let ids = Dictionary(uniqueKeysWithValues: saved.widgets.map { ($0.id, UUID()) })
        for index in copy.widgets.indices { copy.widgets[index].id = ids[copy.widgets[index].id]! }
        copy.links = saved.links.compactMap { link in
            guard let source = ids[link.source], let target = ids[link.target] else { return nil }
            return RecordingWidgetLink(source: source, target: target, action: link.action)
        }
        return copy
    }

    private func commit(_ value: RecordingLayout) {
        guard draft != value else { return }
        history.append(draft)
        if history.count > 30 { history.removeFirst() }
        draft = value
    }

    private func add(_ source: RecordingWidgetDefinition) throws {
        var widget = source
        widget.id = UUID(); widget.position = nil
        var candidate = draft
        candidate.widgets.append(widget)
        candidate = try candidate.validated()
        commit(candidate); selectedID = widget.id
    }

    private func update(_ widget: RecordingWidgetDefinition) throws {
        guard let index = draft.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        var candidate = draft
        let sizeChanged = candidate.widgets[index].size != widget.size
        candidate.widgets[index] = widget
        do { candidate = try candidate.validated() }
        catch {
            guard sizeChanged else { throw error }
            candidate = try RecordingBoardPacking.compacting(candidate).validated()
        }
        commit(candidate)
    }

    @discardableResult
    private func place(_ id: UUID, _ column: Int, _ row: Int) -> Bool {
        do {
            let cells = RecordingBoardPacking.cells(widgets: draft.widgets)
            if let source = draft.widgets.firstIndex(where: { $0.id == id }),
               let target = cells.indices.first(where: { $0 != source && cells[$0].column == column && cells[$0].row == row }),
               cells[source].width == cells[target].width, cells[source].height == cells[target].height {
                var swapped = draft
                for index in swapped.widgets.indices {
                    swapped.widgets[index].position = .init(column: cells[index].column, row: cells[index].row)
                }
                swapped.widgets[source].position = .init(column: cells[target].column, row: cells[target].row)
                swapped.widgets[target].position = .init(column: cells[source].column, row: cells[source].row)
                commit(try swapped.validated())
            } else {
                commit(try RecordingBoardPacking.placing(widgetID: id, column: column, row: row, in: draft))
            }
            selectedID = id; return true
        } catch { message = error.localizedDescription; return false }
    }

    private func remove(_ id: UUID) {
        var candidate = draft
        candidate.widgets.removeAll { $0.id == id }
        candidate.links.removeAll { $0.source == id || $0.target == id }
        commit(candidate); selectedID = draft.widgets.first?.id
    }

    private func applyAppearance(_ source: RecordingWidgetDefinition, colorOnly: Bool) {
        var candidate = draft
        for index in candidate.widgets.indices {
            var appearance = candidate.widgets[index].effectiveAppearance
            if colorOnly {
                candidate.widgets[index].color = source.color
                appearance.customColorHex = source.effectiveAppearance.customColorHex
            } else {
                appearance.style = source.effectiveAppearance.style
                appearance.corner = source.effectiveAppearance.corner
                appearance.showIcon = source.effectiveAppearance.showIcon
            }
            candidate.widgets[index].appearance = appearance
        }
        commit(candidate)
    }
}

private struct RecordingPlacementCanvas: View {
    let layout: RecordingLayout
    let rows: Int
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onPlace: (UUID, Int, Int) -> Bool
    private let spacing: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let cells = RecordingBoardPacking.cells(widgets: layout.widgets)
            let width = max(1, (geometry.size.width - spacing * 5) / 6)
            let height = max(1, (geometry.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            ZStack(alignment: .topLeading) {
                ForEach(0..<(rows * 6), id: \.self) { index in
                    let column = index % 6
                    let row = index / 6
                    Button {
                        if let selectedID { _ = onPlace(selectedID, column, row) }
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.025))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    .buttonStyle(.plain).frame(width: width, height: height)
                    .position(x: CGFloat(column) * (width + spacing) + width / 2, y: CGFloat(row) * (height + spacing) + height / 2)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                        return onPlace(id, column, row)
                    }
                    .accessibilityLabel("\(row + 1)段目、\(column + 1)列目に移動")
                    .accessibilityHidden(cells.contains { column >= $0.column && column < $0.column + $0.width && row >= $0.row && row < $0.row + $0.height })
                }
                ForEach(Array(layout.widgets.enumerated()), id: \.element.id) { index, widget in
                    let cell = cells[index]
                    let cardWidth = CGFloat(cell.width) * width + CGFloat(cell.width - 1) * spacing
                    let cardHeight = CGFloat(cell.height) * height + CGFloat(cell.height - 1) * spacing
                    Button { onSelect(widget.id) } label: {
                        RecordingWidgetFace(widget: widget) {
                            RecordingWidgetSampleValue(widget: widget)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(widget.id == selectedID ? Color.white : .clear, lineWidth: 2))
                        .overlay(alignment: .topTrailing) {
                            if widget.id == selectedID {
                                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.black, .white).padding(4)
                            }
                        }
                    }
                    .buttonStyle(.plain).frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .position(x: CGFloat(cell.column) * (width + spacing) + cardWidth / 2,
                              y: CGFloat(cell.row) * (height + spacing) + cardHeight / 2)
                    .draggable(widget.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let id = UUID(uuidString: raw), id != widget.id else { return false }
                        return onPlace(id, cell.column, cell.row)
                    }
                    .accessibilityLabel(widget.title + "、" + widget.size.title + "、\(cell.row + 1)段目、\(cell.column + 1)列目")
                    .accessibilityAddTraits(widget.id == selectedID ? .isSelected : [])
                }
                if layout.widgets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3").font(.largeTitle)
                        Text("使いたい指標を追加").font(.headline)
                        Text("色もサイズも配置も、自分の使い方に。 ").font(.caption)
                    }.foregroundStyle(.secondary).frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct RecordingWidgetSampleValue: View {
    let widget: RecordingWidgetDefinition
    var body: some View {
        Text(value).font(.system(size: widget.size == .large ? 24 : 17, weight: .bold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }
    private var value: String {
        switch widget.kind {
        case .possession: return "02:34"
        case .timed: return "残り 5秒"
        case .result: return "8 / 10"
        case .successRate: return "80%"
        case .number: return "12 " + widget.unit
        case .leader: return "7番 · 10点"
        case .player: return "選手を選択"
        case .choice: return widget.choices.first ?? "選択する"
        case .zone: return "場所を選択"
        case .note: return "メモを追加"
        case .clip: return "最新プレー"
        case .count: return "3"
        case .teamBadge: return "チーム名"
        case .matchClock: return "12:34"
        case .scoreboard: return "12 – 7"
        }
    }
}

private struct RecordingMetricGallery: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter = "すべて"
    @State private var message: String?
    @State private var lastAdded: String?
    private let presets = RecordingMetricCatalog.templates
    let onAdd: (RecordingWidgetDefinition) throws -> Void

    private var groups: [String] { RecordingMetricCatalog.groups + ["時間・入力・表示", "オリジナル"] }
    private var matches: [RecordingMetricPreset] {
        presets.filter { (filter == "すべて" || $0.group == filter) && (query.isEmpty || ($0.title + $0.subtitle + $0.group).localizedCaseInsensitiveContains(query)) }
    }
    private var utilities: [RecordingWidgetDefinition] {
        let timers = RecordingTimerTarget.allCases.map { target -> RecordingWidgetDefinition in
            var widget = RecordingWidgetDefinition.make(.possession)
            widget.title = target == .bip ? "BIP" : target.title
            widget.timerTarget = target; widget.size = .compact
            widget.scope = target == .home ? .home : target == .away ? .away : .selected
            widget.color = target == .home ? .blue : target == .away ? .red : .orange
            return widget
        }
        let badges = [RecordingTeamScope.home, .away].map { scope -> RecordingWidgetDefinition in
            var widget = RecordingWidgetDefinition.make(.teamBadge)
            widget.scope = scope
            widget.title = scope == .home ? "HOME" : "AWAY"
            widget.color = scope == .home ? .blue : .red
            return widget
        }
        return timers + badges
            + [RecordingWidgetKind.matchClock, .scoreboard, .player, .note, .leader, .clip, .timed]
                .map { RecordingWidgetDefinition.make($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(["すべて"] + groups, id: \.self) { group in
                            Button(group) { filter = group }
                                .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 9)
                                .background(filter == group ? Color.blue : .white.opacity(0.08), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
                List {
                    ForEach(RecordingMetricCatalog.groups, id: \.self) { group in
                        let entries = matches.filter { $0.group == group }
                        if !entries.isEmpty {
                            Section(group) {
                                ForEach(entries) { preset in
                                    galleryRow(preset.widget, title: preset.title, subtitle: preset.subtitle)
                                }
                            }
                        }
                    }
                    if filter == "すべて" || filter == "時間・入力・表示" {
                        Section("時間・入力・表示") {
                            ForEach(utilities.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { widget in
                                galleryRow(widget, title: widget.title, subtitle: widget.kind.title)
                            }
                        }
                    }
                    if filter == "すべて" || filter == "オリジナル" {
                        Section("自分だけの指標") {
                            ForEach(RecordingWidgetKind.allCases.filter { ![.possession, .leader, .clip, .teamBadge, .matchClock, .scoreboard].contains($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { kind in
                                Button {
                                    var widget = RecordingWidgetDefinition.make(kind)
                                    widget.title = "マイ" + kind.title
                                    widget.category = kind.isDisplay ? "lineout" : "custom_" + widget.id.uuidString
                                    add(widget)
                                } label: {
                                    Label(kind.title + "を作る", systemImage: kind.symbol).frame(minHeight: 40)
                                }
                            }
                        }
                    }
                    if matches.isEmpty && !query.isEmpty {
                        Text("見つからない項目は「オリジナル」から作成できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.listStyle(.insetGrouped)
                if let lastAdded {
                    Label(lastAdded + "を追加しました", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green).padding(10)
                }
            }
            .searchable(text: $query, prompt: "指標・プレー名で検索")
            .navigationTitle("分析指標を追加").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .alert("この指標を追加できません", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("閉じる", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }.preferredColorScheme(.dark)
    }

    private func galleryRow(_ widget: RecordingWidgetDefinition, title: String, subtitle: String) -> some View {
        Button { add(widget) } label: {
            HStack(spacing: 12) {
                Image(systemName: widget.symbol).font(.title3).foregroundStyle(widget.color.color)
                    .frame(width: 38, height: 38).background(widget.color.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
            }.padding(.vertical, 4)
        }.accessibilityLabel(title + "を追加。" + subtitle)
    }

    private func add(_ widget: RecordingWidgetDefinition) {
        do { try onAdd(widget); lastAdded = widget.title }
        catch { message = error.localizedDescription }
    }
}

struct RecordingWidgetSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RecordingWidgetDefinition
    @State private var choicesText: String
    @State private var message: String?
    @State private var tab = 0
    let onSave: (RecordingWidgetDefinition) throws -> Void
    private let presets = RecordingMetricCatalog.templates
    private let availableWidgets: [RecordingWidgetDefinition]

    init(widget: RecordingWidgetDefinition, availableWidgets: [RecordingWidgetDefinition] = [],
         onSave: @escaping (RecordingWidgetDefinition) throws -> Void) {
        _draft = State(initialValue: widget)
        _choicesText = State(initialValue: widget.choices.joined(separator: "\n"))
        self.onSave = onSave
        self.availableWidgets = availableWidgets
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    RecordingWidgetFace(widget: draft) { RecordingWidgetSampleValue(widget: draft) }
                        .frame(width: previewWidth, height: draft.size == .large ? 136 : 78)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 16)
                .accessibilityLabel("見た目のプレビュー。数値はサンプルです")
                Picker("設定", selection: $tab) { Text("デザイン").tag(0); Text("記録内容").tag(1) }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                Form {
                    if tab == 0 { appearanceSections }
                    else { recordingSections }
                }
            }
            .padding(.top, 8)
            .navigationTitle("カードをカスタマイズ").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") {
                        draft.choices = choicesText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        do {
                            var validation = draft; validation.position = nil
                            _ = try RecordingLayout(widgets: [validation]).validated()
                            try onSave(draft); dismiss()
                        } catch { message = error.localizedDescription }
                    }.bold()
                }
            }
            .alert("設定を確認してください", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("閉じる", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }.preferredColorScheme(.dark)
    }

    private var previewWidth: CGFloat {
        draft.size == .compact ? 126 : [.small, .row].contains(draft.size) ? 180 : 320
    }

    @ViewBuilder
    private var appearanceSections: some View {
        Section("名前・サイズ") {
            TextField("表示名（24文字まで）", text: $draft.title)
            Picker("サイズ", selection: $draft.size) { ForEach(RecordingWidgetSize.allCases) { Text($0.title).tag($0) } }
            Text("大きさの変更で重なる場合は、ボードを自動整列します。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("カラー") {
            HStack(spacing: 0) {
                ForEach(RecordingWidgetColor.allCases) { color in
                    Button {
                        draft.color = color
                        var appearance = draft.effectiveAppearance; appearance.customColorHex = nil; draft.appearance = appearance
                    } label: {
                        Circle().fill(color.color).frame(width: 30, height: 30)
                            .overlay {
                                if draft.color == color && draft.effectiveAppearance.customColorHex == nil {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel(color.title)
                }
            }
            ColorPicker("好きな色を選ぶ", selection: customColor, supportsOpacity: false)
            if let hex = draft.effectiveAppearance.normalizedCustomColorHex {
                HStack { Text("カスタムカラー"); Spacer(); Text(hex).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        }
        Section("スタイル・形") {
            Picker("スタイル", selection: appearanceBinding(\.style)) {
                ForEach(RecordingWidgetStyle.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("角の形", selection: appearanceBinding(\.corner)) {
                ForEach(RecordingWidgetCorner.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
        }
        Section("アイコン") {
            Toggle("アイコンを表示", isOn: appearanceBinding(\.showIcon))
            if draft.effectiveAppearance.showIcon {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(RecordingIconChoice.all) { icon in
                        Button { draft.symbol = icon.id } label: {
                            Image(systemName: icon.id).font(.system(size: 20, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(draft.symbol == icon.id ? Color.blue : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(.white)
                        }.buttonStyle(.plain).accessibilityLabel(icon.title)
                            .accessibilityAddTraits(draft.symbol == icon.id ? .isSelected : [])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordingSections: some View {
        Section("記録する内容") {
            LabeledContent("入力方法", value: draft.kind.title)
            if draft.kind == .possession {
                Picker("計測対象", selection: $draft.timerTarget) { ForEach(RecordingTimerTarget.allCases) { Text($0.title).tag($0) } }
                Text("保持側を切り替えるとBIPも開始します。HOMEとAWAYは同時に計測しません。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if ![.player, .zone, .note, .clip, .leader, .teamBadge, .matchClock, .scoreboard].contains(draft.kind) {
                Picker("集計するプレー", selection: $draft.category) {
                    ForEach(categoryOptions, id: \.category) { entry in Text(entry.title).tag(entry.category) }
                    if !categoryOptions.contains(where: { $0.category == draft.category }) { Text("オリジナル項目").tag(draft.category) }
                    if draft.category != "custom_" + draft.id.uuidString { Text("新しいオリジナル項目").tag("custom_" + draft.id.uuidString) }
                }
                Text("表示名やデザインを変えても、集計するプレーは変わりません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if ![.possession, .matchClock, .scoreboard].contains(draft.kind) {
                Picker("対象チーム", selection: $draft.scope) { ForEach(RecordingTeamScope.allCases) { Text($0.title).tag($0) } }
            }
            if [.player, .zone, .number, .choice, .note].contains(draft.kind) { Toggle("直前の記録に追加する", isOn: $draft.attachesToLatest) }
            if [.player, .zone, .number, .choice].contains(draft.kind) {
                Toggle("ボード上で入力", isOn: Binding(get: { draft.inlineInput ?? false }, set: { draft.inlineInput = $0 }))
                Text("数値はカード内で入力し、選手・場所・選択肢はメニューから記録します。小さいカードは従来の入力画面を開きます。数値入力には全幅・2段がおすすめです。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.kind == .number { TextField("単位（m、秒など）", text: $draft.unit) }
            if draft.kind == .choice {
                Text("選択肢を1行に1つ（1〜8個）").font(.caption)
                TextEditor(text: $choicesText).frame(minHeight: 140)
            }
        }
        if !draft.kind.isDisplay && draft.kind != .possession {
            Section("映像に含める時間") {
                Stepper("押す前 \(Int(draft.leadTime))秒", value: $draft.leadTime, in: 0...120, step: 1)
                Stepper("押した後 \(Int(draft.lagTime))秒", value: $draft.lagTime, in: 1...120, step: 1)
                if draft.kind == .timed { Text("残り時間が0秒で終了します。計測中の再タップで延長できます。").font(.caption) }
            }
        }
    }

    private var categoryOptions: [(category: String, title: String)] {
        var seen = Set<String>()
        return (presets.map(\.widget) + availableWidgets).compactMap { widget in
            guard !widget.kind.isDisplay,
                  draft.kind != .successRate || widget.kind == .result,
                  seen.insert(widget.category).inserted else { return nil }
            return (widget.category, widget.title)
        }
    }

    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<RecordingWidgetAppearance, Value>) -> Binding<Value> {
        Binding(get: { draft.effectiveAppearance[keyPath: keyPath] }, set: { value in
            var appearance = draft.effectiveAppearance; appearance[keyPath: keyPath] = value; draft.appearance = appearance
        })
    }

    private var customColor: Binding<Color> {
        Binding(get: {
            guard let hex = draft.effectiveAppearance.normalizedCustomColorHex,
                  let value = UInt32(hex.dropFirst(), radix: 16) else { return draft.color.color }
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }, set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            var appearance = draft.effectiveAppearance
            appearance.customColorHex = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
            draft.appearance = appearance
        })
    }
}

private struct RecordingIconChoice: Identifiable {
    let id: String
    let title: String
    static let all: [Self] = [
        .init(id: "rugbyball.fill", title: "ラグビーボール"), .init(id: "figure.rugby", title: "ラグビー選手"),
        .init(id: "shield.fill", title: "守備"), .init(id: "star.fill", title: "スター"),
        .init(id: "flag.fill", title: "フラッグ"), .init(id: "target", title: "ターゲット"),
        .init(id: "stopwatch.fill", title: "ストップウォッチ"), .init(id: "timer", title: "タイマー"),
        .init(id: "person.3.fill", title: "チーム"), .init(id: "person.2.fill", title: "ペア"),
        .init(id: "person.crop.circle.fill", title: "選手"), .init(id: "sportscourt.fill", title: "フィールド"),
        .init(id: "arrow.up.right", title: "前進"), .init(id: "arrow.triangle.2.circlepath", title: "切り替え"),
        .init(id: "arrow.triangle.branch", title: "起点"), .init(id: "arrow.left.arrow.right", title: "パス"),
        .init(id: "hand.raised.fill", title: "手"), .init(id: "bolt.fill", title: "稲妻"),
        .init(id: "flame.fill", title: "炎"), .init(id: "checkmark.circle.fill", title: "成功"),
        .init(id: "xmark.circle.fill", title: "失敗"), .init(id: "plus.circle.fill", title: "加算"),
        .init(id: "chart.pie.fill", title: "成功率"), .init(id: "chart.bar.fill", title: "グラフ"),
        .init(id: "ruler.fill", title: "距離"), .init(id: "number", title: "数値"),
        .init(id: "pencil", title: "メモ"), .init(id: "play.rectangle.fill", title: "映像"),
        .init(id: "p.circle.fill", title: "PG"), .init(id: "d.circle.fill", title: "DG")
    ]
}
struct RecordingLinkEditor: View {
    @Binding var layout: RecordingLayout
    @State private var action: RecordingLinkAction = .start
    @State private var source: UUID?
    @State private var dragging: CGPoint?
    @State private var message: String?
    private var nodes: [RecordingWidgetDefinition] { layout.widgets.filter { $0.kind.canLink } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("連動の種類", selection: $action) { ForEach(RecordingLinkAction.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text("丸い点から相手のボタンへドラッグ\n開始元・連動先の順にタップしても設定できます")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if nodes.count < 2 { Text("回数・保持時間・自動終了ボタンを2つ以上追加してください。").padding() }
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for link in layout.links {
                                guard let from = nodes.firstIndex(where: { $0.id == link.source }),
                                      let to = nodes.firstIndex(where: { $0.id == link.target }) else { continue }
                                drawArrow(context: context, from: center(from, width: geometry.size.width),
                                          to: center(to, width: geometry.size.width), action: link.action)
                            }
                            if let source, let from = nodes.firstIndex(where: { $0.id == source }), let dragging {
                                drawArrow(context: context, from: center(from, width: geometry.size.width), to: dragging, action: action)
                            }
                        }.allowsHitTesting(false)
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                            Button {
                                if let source, source != node.id { connect(source, node.id) }
                                else { source = node.id }
                            } label: {
                                VStack(spacing: 5) {
                                    Label(node.title, systemImage: node.symbol).font(.headline).lineLimit(2)
                                    Text(source == node.id ? "開始元" : node.kind.title).font(.caption)
                                }
                                .padding(8).frame(width: (geometry.size.width - 52) / 2, height: 86)
                                .background(node.tintColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(source == node.id ? .white : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                Circle().fill(.cyan).frame(width: 16, height: 16)
                                    .frame(width: 44, height: 44).contentShape(Rectangle()).offset(y: 22)
                                    .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("links"))
                                        .onChanged { value in source = node.id; dragging = value.location }
                                        .onEnded { value in
                                            if let target = nodes.indices.first(where: {
                                                let point = center($0, width: geometry.size.width)
                                                return abs(value.location.x - point.x) < (geometry.size.width - 52) / 4 + 12 && abs(value.location.y - point.y) < 62
                                            }), nodes[target].id != node.id { connect(node.id, nodes[target].id) }
                                            dragging = nil
                                        })
                                    .accessibilityLabel(node.title + "から連動")
                            }
                            .position(center(index, width: geometry.size.width))
                        }
                    }.coordinateSpace(name: "links")
                }
                .frame(height: CGFloat((nodes.count + 1) / 2) * 150 + 16)
                if source != nil { Button("選択を解除") { source = nil; dragging = nil }.frame(minHeight: 44) }
                ForEach(layout.links) { link in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((nodes.first { $0.id == link.source }?.title ?? "") + " → " + (nodes.first { $0.id == link.target }?.title ?? ""))
                            Text(link.action.title).font(.caption).foregroundStyle(linkColor(link.action))
                        }
                        Spacer()
                        Button(role: .destructive) { layout.links.removeAll { $0.id == link.id } } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.accessibilityLabel("この連動を削除")
                    }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert("この連動は設定できません", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("閉じる", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
    private func center(_ index: Int, width: CGFloat) -> CGPoint {
        CGPoint(x: index % 2 == 0 ? width / 4 : width * 3 / 4, y: 52 + CGFloat(index / 2) * 150)
    }
    private func connect(_ from: UUID, _ to: UUID) {
        var candidate = layout
        candidate.links.removeAll { $0.source == from && $0.target == to }
        candidate.links.append(RecordingWidgetLink(source: from, target: to, action: action))
        do { layout = try candidate.validated(); source = nil }
        catch { message = error.localizedDescription }
    }
    private func linkColor(_ action: RecordingLinkAction) -> Color { action == .start ? .green : action == .stop ? .red : .purple }
    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint, action: RecordingLinkAction) {
        let start = CGPoint(x: from.x, y: from.y + 43)
        let end = CGPoint(x: to.x, y: to.y - 48)
        let midY = max(start.y + 25, (start.y + end.y) / 2)
        var path = Path()
        path.move(to: start); path.addLine(to: CGPoint(x: start.x, y: midY))
        path.addLine(to: CGPoint(x: end.x, y: midY)); path.addLine(to: end)
        context.stroke(path, with: .color(linkColor(action)), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        var tip = Path()
        let sign: CGFloat = end.y < midY ? 1 : -1
        tip.move(to: CGPoint(x: end.x - 6, y: end.y + 10 * sign)); tip.addLine(to: end)
        tip.addLine(to: CGPoint(x: end.x + 6, y: end.y + 10 * sign))
        context.stroke(tip, with: .color(linkColor(action)), lineWidth: 3)
        if action == .exclusive {
            var reverse = Path(); reverse.move(to: CGPoint(x: start.x - 6, y: start.y + 10))
            reverse.addLine(to: start); reverse.addLine(to: CGPoint(x: start.x + 6, y: start.y + 10))
            context.stroke(reverse, with: .color(.purple), lineWidth: 3)
        }
    }
}


struct RecordingLayoutPreview: View {
    let layout: RecordingLayout
    @State private var active: Set<UUID> = []
    @State private var counts: [UUID: Int] = [:]
    @State private var deadlines: [UUID: Date] = [:]
    @State private var message = "ボタンを試せます。試合の記録は保存されません。"

    var body: some View {
        VStack(spacing: 10) {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 34)
            GeometryReader { geometry in
                let cells = RecordingBoardPacking.cells(widgets: layout.widgets)
                let rows = max(1, RecordingBoardPacking.rowCount(widgets: layout.widgets))
                let gap: CGFloat = 6
                let width = max(1, (geometry.size.width - gap * 5) / 6)
                let height = max(1, (geometry.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
                TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(layout.widgets.enumerated()), id: \.element.id) { index, widget in
                            let cell = cells[index]
                            let cardWidth = CGFloat(cell.width) * width + CGFloat(cell.width - 1) * gap
                            let cardHeight = CGFloat(cell.height) * height + CGFloat(cell.height - 1) * gap
                            let remaining = max(0, deadlines[widget.id]?.timeIntervalSince(timeline.date) ?? 0)
                            let running = active.contains(widget.id) && (widget.kind != .timed || remaining > 0)
                            Button { simulate(widget, at: timeline.date) } label: {
                                RecordingWidgetFace(widget: widget, active: running,
                                                    fraction: widget.kind == .timed ? remaining / max(1, widget.lagTime) : 1) {
                                    if widget.kind.canLink || widget.kind == .result {
                                        Text(running ? (widget.kind == .timed ? String(format: "残り %.1f秒", remaining) : "計測中") : "\(counts[widget.id, default: 0])")
                                            .font(.system(size: 19, weight: .bold, design: .rounded))
                                            .lineLimit(1).minimumScaleFactor(0.5)
                                    } else { RecordingWidgetSampleValue(widget: widget) }
                                }
                            }
                            .buttonStyle(.plain).frame(width: cardWidth, height: cardHeight).clipped()
                            .position(x: CGFloat(cell.column) * (width + gap) + cardWidth / 2,
                                      y: CGFloat(cell.row) * (height + gap) + cardHeight / 2)
                        }
                    }
                }
            }
            Button("テストをリセット") {
                active = []; counts = [:]; deadlines = [:]
                message = "ボタンを試せます。試合の記録は保存されません。"
            }.buttonStyle(.bordered).frame(minHeight: 44)
        }
    }

    private func simulate(_ widget: RecordingWidgetDefinition, at date: Date) {
        if widget.kind == .result { counts[widget.id, default: 0] += 1; message = widget.title + "：成功の記録を試しました。"; return }
        guard widget.kind.canLink else {
            message = widget.kind.isDisplay ? widget.title + "：プレビューではサンプル値を表示しています。" : widget.title + "：試合では入力画面が開きます。"
            return
        }
        if widget.kind == .possession, active.contains(widget.id) { active.remove(widget.id); return }
        if widget.kind == .timed, (deadlines[widget.id] ?? .distantPast) > date {
            deadlines[widget.id] = date.addingTimeInterval(widget.lagTime); return
        }
        do {
            let plan = try RecordingRuleEngine.plan(source: widget.id, layout: layout)
            for id in plan.stop { active.remove(id); deadlines[id] = nil }
            for id in plan.start {
                guard let target = layout.widgets.first(where: { $0.id == id }) else { continue }
                if target.kind == .count { counts[id, default: 0] += 1 }
                else {
                    if target.kind == .possession {
                        for other in layout.widgets where other.kind == .possession && other.timerTarget != target.timerTarget && other.timerTarget != .bip && target.timerTarget != .bip { active.remove(other.id) }
                    }
                    if !active.contains(id) || (deadlines[id] ?? .distantPast) <= date { counts[id, default: 0] += 1 }
                    active.insert(id)
                    if target.kind == .timed { deadlines[id] = date.addingTimeInterval(target.lagTime) }
                }
            }
        } catch { message = error.localizedDescription }
    }
}
