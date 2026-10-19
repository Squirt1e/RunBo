import SwiftUI

struct CardCopyCommands: Commands {
    @ObservedObject var model: AppModel
    var body: some Commands {
        CommandMenu("分身") {
            Button("解除全部一次性分身") {
                model.openWindowAction?()
                model.removeAllCopies()
            }
            .disabled(model.copyKeys.isEmpty || !model.removingCopies.isEmpty)
        }
    }
}
