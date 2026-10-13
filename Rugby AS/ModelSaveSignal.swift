//
//  ModelSaveSignal.swift
//  Rugby AS
//
//  データが保存されたことを画面に知らせる合図。
//  公式記録のまとめ取り込みは裏(メイン以外)で保存するため、その「保存しました」の通知も裏から届く。
//  画面の更新はメインでしかできないので、受け取る側はこの合図を使う(メインで届け直す)。
//

import Combine
import Foundation
import SwiftData

enum ModelSaveSignal {
    /// どれかの ModelContext が保存したとき。必ずメインで届く。
    static var didSave: AnyPublisher<Notification, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
