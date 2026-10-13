import SwiftUI

// iPad 向けのレイアウト判定をここ 1 箇所にまとめる。
// 各画面はこれを見て「広い画面用の値」に切り替えるだけにする。

extension EnvironmentValues {
    // 画面が iPad サイズかどうか。
    // 横も縦も regular になるのは iPad（と iPad の広いウインドウ）だけ。
    // iPhone は Pro Max の横向きでも縦が compact なので false になり、
    // 狭いところで値だけ大きくなって崩れる事故を防げる。
    var isPadLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }
}

extension View {
    // 広い画面で内容が横に伸びきらないよう、最大幅を決めて中央に置く。
    // iPhone では何もしない（maxWidth を付けない）ので表示は今までどおり。
    func padContentWidth(_ maxWidth: CGFloat = 760) -> some View {
        modifier(PadContentWidth(maxWidth: maxWidth))
    }
}

private struct PadContentWidth: ViewModifier {
    @Environment(\.isPadLayout) private var isPadLayout
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if isPadLayout {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {
    // iPad では画面いっぱいに開き、iPhone では今までどおり下から出るシートで開く。
    // (iPad のシートは中央の小さな枠になり、順位表やランキングが窮屈になるため)
    func padFullScreenSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(PadFullScreenSheet(isPresented: isPresented, sheetContent: content))
    }
}

private struct PadFullScreenSheet<SheetContent: View>: ViewModifier {
    @Environment(\.isPadLayout) private var isPadLayout
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        if isPadLayout {
            content.fullScreenCover(isPresented: $isPresented, content: sheetContent)
        } else {
            content.sheet(isPresented: $isPresented, content: sheetContent)
        }
    }
}
