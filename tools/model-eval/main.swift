import Foundation
try WordCoachSystemPrompt.text.write(toFile: "fixtures/system-word.txt", atomically: true, encoding: .utf8)
try QuizCoachSystemPrompt.text.write(toFile: "fixtures/system-quiz.txt", atomically: true, encoding: .utf8)
print("word:", WordCoachSystemPrompt.text.count, "quiz:", QuizCoachSystemPrompt.text.count)
