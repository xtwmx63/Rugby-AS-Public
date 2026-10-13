// 得点の種類。画面の表示名などに使う(点数は Models.swift の ScoringRules)。
// もとは使われなくなった旧記録画面 RecordingView.swift の中にあった。

enum ScoringCategory: String {
    case tryScore = "try"
    case conversion = "conversion"
    case penaltyGoal = "penalty_goal"
    case dropGoal = "drop_goal"
    case penaltyTry = "penalty_try"

    var displayName: String {
        switch self {
        case .tryScore:
            return "トライ"
        case .conversion:
            return "コンバージョン"
        case .penaltyGoal:
            return "PG"
        case .dropGoal:
            return "DG"
        case .penaltyTry:
            return "認定トライ"
        }
    }

    var requiresResultSelection: Bool {
        switch self {
        case .conversion, .penaltyGoal, .dropGoal:
            return true
        case .tryScore, .penaltyTry:
            return false
        }
    }
}

