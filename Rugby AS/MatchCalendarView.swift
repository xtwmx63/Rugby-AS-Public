//
//  MatchCalendarView.swift
//  Rugby AS
//
//  試合一覧のカレンダー。月ごとに日付と「N試合」を並べ、試合のある日を
//  タップするとその日を選んで閉じる(試合一覧がその日の試合だけになる)。
//  試合の数は保存せず、開いたときの試合一覧から数える。
//

import SwiftUI

struct MatchCalendarView: View {
    /// 日(その日の0時)ごとの試合数
    let matchCountsByDay: [Date: Int]
    let selectedDay: Date?
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    // 表示中の月(その月の1日)
    @State private var month: Date

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        calendar.firstWeekday = 2 // 月曜はじまり
        return calendar
    }()
    private static let weekdaySymbols = ["月", "火", "水", "木", "金", "土", "日"]

    init(matchCountsByDay: [Date: Int], selectedDay: Date?, onSelect: @escaping (Date) -> Void) {
        self.matchCountsByDay = matchCountsByDay
        self.selectedDay = selectedDay
        self.onSelect = onSelect
        let base = selectedDay ?? Date()
        _month = State(initialValue: Self.calendar.dateInterval(of: .month, for: base)?.start ?? base)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    monthBar
                    weekdayHeader
                    dayGrid
                }
                .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RugbyTheme.border, lineWidth: 1))
                .padding(16)
                .padContentWidth(760)

                Text("試合のある日をタップすると、その日の試合だけを表示します。")
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .padding(.horizontal, 20)
            }
            .background(RugbyTheme.background)
            .navigationTitle("カレンダー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("今月") { month = startOfMonth(Date()) }
                        .disabled(Self.calendar.isDate(month, equalTo: Date(), toGranularity: .month))
                }
            }
        }
    }

    // MARK: - 月の切り替え

    private var monthBar: some View {
        HStack {
            Button { moveMonth(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("前の月")
            Spacer()
            VStack(spacing: 2) {
                Text(monthTitle)
                    .font(.title3.weight(.heavy).monospacedDigit())
                    .foregroundStyle(RugbyTheme.textPrimary)
                Text("\(monthMatchCount)試合")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            Spacer()
            Button { moveMonth(1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .accessibilityLabel("次の月")
        }
        .font(.headline)
        .foregroundStyle(RugbyTheme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(weekdayColor(column: index) ?? RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .background(RugbyTheme.accentSoft)
    }

    // MARK: - 日付の並び

    private var dayGrid: some View {
        let cells = monthCells
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, day in
                        dayCell(day, column: column)
                    }
                }
                Divider().overlay(RugbyTheme.border)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, column: Int) -> some View {
        if let day {
            let count = matchCountsByDay[day] ?? 0
            let isSelected = selectedDay.map { Self.calendar.isDate($0, inSameDayAs: day) } ?? false
            let isToday = Self.calendar.isDateInToday(day)
            Button {
                onSelect(day)
                dismiss()
            } label: {
                VStack(spacing: 6) {
                    Text("\(Self.calendar.component(.day, from: day))")
                        .font(.subheadline.weight(isToday ? .heavy : .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? RugbyTheme.onAccent
                            : (weekdayColor(column: column) ?? RugbyTheme.textPrimary))
                    Text(count > 0 ? "\(count)試合" : " ")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isSelected ? RugbyTheme.onAccent : RugbyTheme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(cellBackground(isSelected: isSelected, isToday: isToday, hasMatches: count > 0))
                .opacity(count > 0 || isSelected ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .accessibilityLabel(accessibilityLabel(for: day, count: count))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 64)
        }
    }

    private func cellBackground(isSelected: Bool, isToday: Bool, hasMatches: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? RugbyTheme.accent : (isToday ? RugbyTheme.elevated : Color.clear))
            .padding(3)
    }

    // 土曜は青、日曜は赤。平日は nil(ふつうの色)。日曜の赤は配色を変えても変わらない
    private func weekdayColor(column: Int) -> Color? {
        switch column {
        case 5: return .blue
        case 6: return RugbyTheme.fixedRed
        default: return nil
        }
    }

    // MARK: - 計算

    /// 月曜はじまりで、1日の前を空欄(nil)で埋めた日付の並び
    private var monthCells: [Date?] {
        let calendar = Self.calendar
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        // weekday: 日=1 … 土=7。月曜を0列目にする
        let leadingBlanks = (calendar.component(.weekday, from: month) + 5) % 7
        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in range {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var monthMatchCount: Int {
        matchCountsByDay.reduce(0) { total, entry in
            Self.calendar.isDate(entry.key, equalTo: month, toGranularity: .month) ? total + entry.value : total
        }
    }

    private var monthTitle: String {
        let calendar = Self.calendar
        return "\(calendar.component(.year, from: month))年\(calendar.component(.month, from: month))月"
    }

    private func moveMonth(_ value: Int) {
        if let moved = Self.calendar.date(byAdding: .month, value: value, to: month) {
            month = startOfMonth(moved)
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        Self.calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    private func accessibilityLabel(for day: Date, count: Int) -> String {
        let calendar = Self.calendar
        let text = "\(calendar.component(.month, from: day))月\(calendar.component(.day, from: day))日"
        return count > 0 ? "\(text)、\(count)試合" : "\(text)、試合なし"
    }
}

#Preview {
    let today = Calendar.current.startOfDay(for: Date())
    return MatchCalendarView(
        matchCountsByDay: [today: 2, Calendar.current.date(byAdding: .day, value: -3, to: today)!: 5],
        selectedDay: nil
    ) { _ in }
}
