import Testing
@testable import StreamTranslate

@Test func initialSettleDoesNotTranslateDanglingAuxiliariesOrAmbiguousPhrasalVerbs() {
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("We ruled", language: .english))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("We have", language: .english))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("They looked", language: .english))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("我们已经", language: .chinese))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("会议正在", language: .chinese))
    #expect(TranslationDraftPlanner.canSettleInitialPhrase("Hello everyone", language: .english))
}

@Test func completeShortClausesBypassTheEditableTail() {
    #expect(TranslationDraftPlanner.prefix(in: "Hello everyone.", language: .english) == "Hello everyone.")
    #expect(TranslationDraftPlanner.prefix(in: "大家好，我们", language: .chinese) == "大家好，")
}

@Test func chineseDraftPreservesWholeTimeUnits() {
    #expect(TranslationDraftPlanner.prefix(in: "会议将在5分钟后开始", language: .chinese) == "会议将在5分钟")
    #expect(!TranslationDraftPlanner.prefix(in: "会议将在5分钟后开始", language: .chinese).hasSuffix("5分"))
}

@Test func translationPrefixRetainsPercentageSigns() {
    #expect(TranslationDraftPlanner.prefix(in: "Revenue fell 15%, not 50%", language: .english).contains("15%"))
    #expect(TranslationDraftPlanner.prefix(in: "收入下降了15%，不是50%", language: .chinese).contains("15%"))
}

@Test func translationPrefixDoesNotStopAtAnUnfinishedEnglishConnective() {
    #expect(TranslationDraftPlanner.prefix(in: "We can begin the meeting now", language: .english) == "We can begin")
    #expect(TranslationDraftPlanner.prefix(in: "Do not restart until backup finishes", language: .english) == "Do not restart")
}

@Test func initialPhraseSettlingRequiresUsefulWords() {
    #expect(TranslationDraftPlanner.canSettleInitialPhrase("Hello everyone", language: .english))
    #expect(TranslationDraftPlanner.canSettleInitialPhrase("大家好", language: .chinese))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("Hello", language: .english))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("大", language: .chinese))
    #expect(!TranslationDraftPlanner.canSettleInitialPhrase("大家好我们", language: .chinese))
}

@Test func initialPhraseDoesNotExposeBareNumbersOrNegationTails() {
    for text in ["We should not", "It costs 15", "Please wait five", "We can"] {
        #expect(!TranslationDraftPlanner.canSettleInitialPhrase(text, language: .english))
    }
    for text in ["预算是三", "会议将在5", "这不是", "收入下降了"] {
        #expect(!TranslationDraftPlanner.canSettleInitialPhrase(text, language: .chinese))
    }
}

@Test func decimalNumbersAndClockTimesAreNotClauseBoundaries() {
    #expect(TranslationDraftPlanner.prefix(in: "The rate is 3.5", language: .english) != "The rate is 3.")
    #expect(!TranslationDraftPlanner.prefix(in: "会议在12:30", language: .chinese).hasSuffix("12:"))
}
