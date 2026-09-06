import Testing
@testable import StreamTranslate

@Test func ellipsisResolutionUsesOnlyClearSameSubjectUsedToConstruction() {
    #expect(TranslationIntegrityPolicy.resolvedEllipsis("I no longer do.", context: "She said we had not verified it yet.\nI used to think the update was safe.", language: .english)
        == "I no longer think the update was safe.")
    #expect(TranslationIntegrityPolicy.resolvedEllipsis("We no longer do.", context: "We used to work here.", language: .english) == "We no longer work here.")
    #expect(TranslationIntegrityPolicy.resolvedEllipsis("You no longer do.", context: "You used to work here.", language: .english) == "You no longer work here.")
    #expect(TranslationIntegrityPolicy.resolvedEllipsis("I no longer do.", context: "They used to work here.", language: .english) == nil)
    #expect(TranslationIntegrityPolicy.resolvedEllipsis("I no longer do.", context: "I thought the update was safe.", language: .english) == nil)
    #expect(TranslationIntegrityPolicy.resolvedEllipsis("I no longer do.", context: "I used to not work here.", language: .english) == nil)
}

@Test func numericPrecisionPromptSeparatesChangesFromFinalValues() {
    #expect(!TranslationIntegrityPolicy.precisionInstruction(for: "Latency fell by a third, not to a third.", language: .english).isEmpty)
    #expect(!TranslationIntegrityPolicy.precisionInstruction(for: "延迟降低了三分之一，不是降低到三分之一。", language: .chinese).isEmpty)
    #expect(TranslationIntegrityPolicy.precisionInstruction(for: "We travelled by train to the third station.", language: .english).isEmpty)
    #expect(TranslationIntegrityPolicy.precisionInstruction(for: "The model weights stay the same size.", language: .english).isEmpty)
}

@Test func explicitPercentUnitsArePreservedWithoutChangingValuesOrActualPoints() {
    let source = "The failure rate decreased to two percent, not by two percent."
    #expect(TranslationIntegrityPolicy.normalizedPercentUnits("故障率降到了2%，而非下降了2个百分点。", source: source)
        == "故障率降到了2%，而非下降了2%。")
    #expect(TranslationIntegrityPolicy.normalizedPercentUnits("故障率下降了2个百分点。", source: "The failure rate fell by two percentage points.")
        == "故障率下降了2个百分点。")
    #expect(!TranslationIntegrityPolicy.accepts("故障率下降了2%。", for: "The failure rate fell by two percentage points."))
    #expect(TranslationIntegrityPolicy.normalizedPercentUnits("It fell by two percentage points.", source: "它下降了百分之二。") == "It fell by two percent.")
    #expect(TranslationIntegrityPolicy.normalizedPercentUnits("It fell by two percentage points.", source: "它下降了两个百分点。") == "It fell by two percentage points.")
}

@Test func translationIntegrityRejectsLeakedPromptLabels() {
    #expect(!TranslationIntegrityPolicy.accepts("[源文本]\n我不再这么做了。", for: "I no longer do."))
    #expect(!TranslationIntegrityPolicy.accepts("[Source Text] I no longer do.", for: "我不再这样想。"))
    #expect(TranslationIntegrityPolicy.accepts("[源文本]", for: "[Source Text]"))
}

@Test func translationIntegrityRejectsCompleteLossOfExplicitNegation() {
    #expect(!TranslationIntegrityPolicy.accepts("This patch reduces the delay by one-third. The success rate has increased from 95% to 98%.",
        for: "这个补丁把延迟降低了三分之一，不是降低到三分之一，成功率从95%提高到98%。"))
    #expect(TranslationIntegrityPolicy.accepts("This patch reduces latency by one-third, not to one-third.",
        for: "这个补丁把延迟降低了三分之一，不是降低到三分之一。"))
    #expect(!TranslationIntegrityPolicy.accepts("我们批准了发布。", for: "We have not approved the release."))
    #expect(TranslationIntegrityPolicy.accepts("我们还没有批准发布。", for: "We have not approved the release."))
    #expect(TranslationIntegrityPolicy.accepts("The model weights remain unchanged.", for: "模型权重没有变化。"))
}

@Test func translationIntegrityRejectsChangedFractionsAndPercentages() {
    #expect(!TranslationIntegrityPolicy.accepts("减少了三分之一，而非三分之二。", for: "By a third, not to a third."))
    #expect(TranslationIntegrityPolicy.accepts("减少了三分之一，而非降至三分之一。", for: "By a third, not to a third."))
    #expect(!TranslationIntegrityPolicy.accepts("收入下降了百分之五十。", for: "Revenue fell by 15%."))
    #expect(TranslationIntegrityPolicy.accepts("收入下降了百分之十五。", for: "Revenue fell by 15%."))
    #expect(TranslationIntegrityPolicy.accepts("收入下降了百分之五十。", for: "Revenue fell by 50%."))
    #expect(!TranslationIntegrityPolicy.accepts("收入下降了百分之五。", for: "Revenue fell by 15%."))
}

@Test func translationIntegrityAllowsNumericFormattingButRejectsInventedValues() {
    #expect(TranslationIntegrityPolicy.accepts("预算为15,000元。", for: "The budget is 15000 yuan."))
    #expect(!TranslationIntegrityPolicy.accepts("预算为50,000元。", for: "The budget is 15000 yuan."))
    #expect(TranslationIntegrityPolicy.accepts("The budget is 35000 yuan.", for: "预算是3.5万元。"))
    #expect(TranslationIntegrityPolicy.accepts("第三方软件", for: "a third party application"))
}

@Test func translationContextIsLimitedToShortNonNumericReferences() {
    #expect(TranslationIntegrityPolicy.shouldUseContext("I no longer do.", language: .english))
    #expect(TranslationIntegrityPolicy.shouldUseContext("They were all empty.", language: .english))
    #expect(!TranslationIntegrityPolicy.shouldUseContext("It was a cash eviction problem.", language: .english))
    #expect(!TranslationIntegrityPolicy.shouldUseContext("They approved the update.", language: .english))
    #expect(!TranslationIntegrityPolicy.shouldUseContext("By a third, not to a third.", language: .english))
    #expect(!TranslationIntegrityPolicy.shouldUseContext("It fell by 15%.", language: .english))
    #expect(!TranslationIntegrityPolicy.shouldUseContext("The server is available and all database connections are ready for the next request.", language: .english))
}
