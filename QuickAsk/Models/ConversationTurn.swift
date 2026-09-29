import Foundation

struct ConversationTurn: Identifiable, Equatable {
    let id: UUID
    var question: String
    var answer: String

    init(id: UUID = UUID(), question: String, answer: String = "") {
        self.id = id
        self.question = question
        self.answer = answer
    }
}
