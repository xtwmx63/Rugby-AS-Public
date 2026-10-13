//
//  LongImportSession.swift
//  Rugby AS
//
//  公式記録のまとめ取り込みを、ホームに戻ったり画面を消したりしても続けるための仕組み。
//  iOS 26 以降: 「続けて処理するタスク」(BGContinuedProcessingTask)を使う。
//    ロック画面などに進み具合が出て、そこから止めることもできる。
//  それより前、または iOS が受け付けなかったとき:
//    取り込み中は画面が自動で消えないようにし、アプリを離れても iOS が許す短い時間だけ続ける。
//  どちらでも、止められたら「停止」と同じ扱い(保存済みの試合は残り、次回は残りから取り込める)。
//

import BackgroundTasks
import UIKit

@MainActor
final class LongImportSession {
    /// Info.plist の BGTaskSchedulerPermittedIdentifiers に「この接頭辞 + .*」を書いてある
    nonisolated static let identifierPrefix = "com.63.Rugby-AS.officialImport"

    private let title: String
    private let total: Int64
    private let onExpire: @MainActor () -> Void
    private var continuedTask: AnyObject?          // iOS 26 の BGContinuedProcessingTask
    private var fallbackTask: UIBackgroundTaskIdentifier = .invalid
    private var keepsScreenOn = false
    private var completed: Int64 = 0
    private var subtitle = ""
    private var finished = false

    /// - Parameter onExpire: iOS やユーザーが処理を止めたときに呼ばれる。保存を区切りよく止めること。
    init(title: String, total: Int, onExpire: @escaping @MainActor () -> Void) {
        self.title = title
        self.total = Int64(max(1, total))
        self.onExpire = onExpire
    }

    /// iOS 26 の仕組みで続けられるようになったら true。
    private(set) var runsInBackground = false

    func start() {
        if #available(iOS 26.0, *), submitContinuedTask() {
            runsInBackground = true
            return
        }
        startFallback()
    }

    func update(completed: Int, subtitle: String) {
        self.completed = Int64(completed)
        self.subtitle = subtitle
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = min(self.completed, total)
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = success ? total : min(completed, total)
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        if fallbackTask != .invalid {
            UIApplication.shared.endBackgroundTask(fallbackTask)
            fallbackTask = .invalid
        }
        if keepsScreenOn {
            UIApplication.shared.isIdleTimerDisabled = false
            keepsScreenOn = false
        }
    }

    // MARK: - iOS 26 以降

    @available(iOS 26.0, *)
    private func submitContinuedTask() -> Bool {
        // 毎回ちがう名前にする(同じ名前を2回登録するとアプリが終了させられるため)
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.attach(task)
            }
        }
        guard registered else {
            NSLog("LongImportSession: 登録できませんでした(Info.plist の BGTaskSchedulerPermittedIdentifiers を確認)")
            return false
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "準備しています")
        // すぐ始められないなら待たせず、短い時間だけ続ける方式に切り替える
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            NSLog("LongImportSession: 続けて処理するタスクを開始できませんでした: %@", String(describing: error))
            return false
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        // 取り込みが先に終わっていたら、すぐ完了を伝える
        guard !finished else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = min(completed, total)
        if !subtitle.isEmpty { task.updateTitle(title, subtitle: subtitle) }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.onExpire() }
        }
    }

    // MARK: - iOS 25 以前、または受け付けられなかったとき

    private func startFallback() {
        UIApplication.shared.isIdleTimerDisabled = true
        keepsScreenOn = true
        fallbackTask = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            // iOS はメインスレッドでこれを呼び、戻るまでに終了の連絡を求める
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onExpire()
                if self.fallbackTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.fallbackTask)
                    self.fallbackTask = .invalid
                }
            }
        }
    }
}
