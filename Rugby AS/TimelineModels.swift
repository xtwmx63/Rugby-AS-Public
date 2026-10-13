// TimelineEditorView.swift から分割(中身は変更なし)

import AVFoundation
import Combine
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TimelineTrackType: Identifiable, Hashable {
    case video
    case match
    case home
    case away
    case bip
    case tryEvent
    case conv
    case pg
    case dg
    case lo
    case scr
    case metric(category: String, title: String)
    case halfTime
    case stoppage
    case deleteTool

    var id: String {
        if case .metric(let category, _) = self { return "metric:" + category }
        return String(describing: self)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func tracks(for clips: [TimelineClip]) -> [Self] {
        let metrics = Set(clips.compactMap { clip -> Self? in
            if case .metric = clip.trackType { return clip.trackType }
            return nil
        }).sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
        return timelineTracks + metrics
    }

    var title: String {
        switch self {
        case .video: return "VIDEO"
        case .match: return "MATCH"
        case .home: return "HOME"
        case .away: return "AWAY"
        case .bip: return "BIP"
        case .tryEvent: return "TRY"
        case .conv: return "CONV"
        case .pg: return "PG"
        case .dg: return "DG"
        case .lo: return "LO"
        case .scr: return "SCR"
        case .metric(_, let title): return title
        case .halfTime: return "ハーフタイム"
        case .stoppage: return "中断"
        case .deleteTool: return "DELETE"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "film.stack.fill"
        case .match: return "timer"
        case .home: return "house.fill"
        case .away: return "a.circle.fill"
        case .bip: return "j.circle.fill"
        case .tryEvent: return "rugbyball.fill"
        case .conv: return "figure.rugby"
        case .pg: return "p.circle.fill"
        case .dg: return "d.circle.fill"
        case .lo: return "arrow.up.and.down.and.sparkles"
        case .scr: return "person.3.fill"
        case .metric: return "chart.bar.xaxis"
        case .halfTime: return "hourglass"
        case .stoppage: return "pause.circle.fill"
        case .deleteTool: return "trash.fill"
        }
    }

    var color: Color {
        switch self {
        case .video: return Color(red: 0.55, green: 0.30, blue: 0.95)
        case .match: return Color(red: 0.16, green: 0.78, blue: 0.55)
        case .home: return Color(red: 0.02, green: 0.35, blue: 0.96)
        case .away: return Color(red: 0.96, green: 0.10, blue: 0.18)
        case .bip: return Color(red: 0.38, green: 0.16, blue: 0.88)
        case .tryEvent: return Color(red: 0.20, green: 0.72, blue: 0.22)
        case .conv: return Color(red: 0.06, green: 0.66, blue: 0.76)
        case .pg: return Color(red: 0.94, green: 0.72, blue: 0.10)
        case .dg: return Color(red: 0.96, green: 0.60, blue: 0.08)
        case .lo: return Color(red: 0.06, green: 0.72, blue: 0.82)
        case .scr: return Color(red: 0.92, green: 0.36, blue: 0.06)
        case .metric: return .mint
        case .halfTime: return Color(red: 0.24, green: 0.52, blue: 0.50)
        case .stoppage: return Color(red: 0.42, green: 0.47, blue: 0.58)
        case .deleteTool: return Color(red: 0.86, green: 0.12, blue: 0.18)
        }
    }

    // タイムラインに行を持つか。DELETE・中断・ハーフタイムは「道具」なので行を持たない。
    var isTimelineTrack: Bool {
        self != .deleteTool && self != .stoppage && self != .halfTime
    }

    // 長さ(始まり〜終わり)を持つ帯の行。「分割」ができるのはここだけ。
    // TRY などは一瞬の出来事なので、切っても意味がない。
    var isIntervalTrack: Bool {
        switch self {
        case .home, .away, .bip:
            return true
        default:
            return false
        }
    }

    // 左のラベルをタップして「その行のクリップだけを連続再生」できる行。
    // VIDEO/MATCH は場面の行ではないので対象外。
    var supportsSequentialPlayback: Bool {
        switch self {
        case .home, .away, .bip, .tryEvent, .conv, .pg, .dg, .lo, .scr, .metric:
            return true
        case .video, .match, .halfTime, .stoppage, .deleteTool:
            return false
        }
    }

    static let timelineTracks: [TimelineTrackType] = [
        .video, .match, .home, .away, .bip, .tryEvent, .conv, .pg, .dg, .lo, .scr
    ]

    static let toolPalette: [TimelineTrackType] = [
        .home, .away, .bip, .tryEvent, .conv, .pg, .dg, .lo, .scr, .halfTime, .stoppage, .deleteTool
    ]
}

struct TimelineClip: Identifiable, Equatable {
    let id: UUID
    var trackType: TimelineTrackType
    var startTime: Double
    var endTime: Double
    var title: String
    var isSelected: Bool
    // 元の記録の「時間以外の中身」の控え。
    // クリップを消して取り消した(undo)とき、成否・前後半・選手・チーム・起点を
    // そのまま戻すために持ち歩く。見た目(時間と色)には影響しない。
    var details: StatEventDetails? = nil

    var color: Color { trackType.color }
}

enum MatchHalfType: String, Codable {
    case first
    case second

    var title: String {
        switch self {
        case .first: return "前半"
        case .second: return "後半"
        }
    }
}

// MATCH の行で「いま何を選んでいるか」。
// 帯は設定から毎回作り直すので、選択は id ではなく中身で覚える。
enum MatchSelection: Equatable {
    case half(Int)        // 前半(0)/後半(1)の試合時間そのもの
    case stoppage(UUID)   // 中断1つ
    case halfTime         // ハーフタイム(前半と後半のあいだ)
}

struct MatchSegment: Identifiable, Equatable {
    let id: UUID
    var halfType: MatchHalfType
    var startTime: Double
    var endTime: Double
    var displayLabel: String
    // この帯をタップしたときに選ばれるもの(nil = 選べない)
    var selectionKey: MatchSelection? = nil
    // 中断の帯なら true(試合が動いている帯と描き分ける)
    var isStoppage: Bool = false
    // ハーフタイムの帯なら true
    var isHalfTime: Bool = false
    // そのハーフの最後の帯。右端を引くとハーフの長さが変わる。
    var isHalfEnd: Bool = false
}

struct VideoSegment: Identifiable, Equatable {
    let id: UUID
    var sourceName: String
    var startTime: Double
    var endTime: Double
    var fileName: String? = nil
}

struct TimelineState {
    var timelineClips: [TimelineClip]
    var matchSegments: [MatchSegment]
    var videoSegments: [VideoSegment]
    var selectedClipID: UUID?
    var selectedVideoSegmentID: UUID?
}
