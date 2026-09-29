import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var question: String
    var answer: String
    var providerName: String
    var model: String
    var profileID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        question: String,
        answer: String,
        providerName: String,
        model: String,
        profileID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.answer = answer
        self.providerName = providerName
        self.model = model
        self.profileID = profileID
    }
}
