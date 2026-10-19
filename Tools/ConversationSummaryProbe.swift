import Foundation
import AppKit

/// Synthetic text only. No user transcript, audio or preferences. The production
/// service may append process metadata to the shared diagnostic log.
@main enum ConversationSummaryProbe {
    @MainActor static func main() async throws {
        let options = CommandLine.arguments
        let override = options.firstIndex(of: "--model").flatMap { index -> LocalModelAssets? in
            guard options.indices.contains(index + 1), let base = LocalSummaryService.assets else { return nil }
            return LocalModelAssets(executable: base.executable, model: URL(fileURLWithPath: options[index + 1]))
        }
        let service: any ConversationSummaryProviding
        if options.contains("--cloud") {
            guard let configuration = SummaryCloudConfiguration.load() else { throw SummaryError.modelUnavailable }
            service = CloudSummaryService(configuration: configuration)
            print("SUMMARY CLOUD MODEL \(configuration.model)")
        } else { service = LocalSummaryService(assets: override) }
        defer { service.cancel() }
        let start = Date()
        try await service.prepare()
        print("SUMMARY MODEL READY seconds=\(Date().timeIntervalSince(start))")
        if let service = service as? LocalSummaryService {
        let budgetText = "[1] " + String(String(repeating: "记忆形成与城市住房政策涉及不同主体。", count: 70).prefix(899)) + "\n"
        let budgetIndex = String(String(repeating: "T10|discussion|节目中的不同主题与历史观点\n", count: 80).prefix(1_200))
        let tokens = try await service.promptTokenCount(budgetText, previous: budgetIndex)
        print("TOKEN_BUDGET prompt=\(tokens) output=1024 context=4096 source_chars=900 index_chars=1200")
        fflush(nil)
        guard tokens + 1_024 <= 4_096 else { throw SummaryError.invalidResult }
        }
        if options.contains("--mindmap") {
            try await verifyMindMap(service: service, start: start)
            return
        }
        let stages = [
            "本期节目由云声耳机赞助。前往购买页面输入优惠码，可以享受九折。广告到这里结束。",
            "欢迎回到节目。今天神经科学家讨论记忆如何形成，与刚才的赞助无关。海马体参与新的情景记忆形成，睡眠有助于巩固记忆。",
            "接下来换一个事件：市议会正在讨论住房政策，拟限制租金涨幅。支持者认为有利于租客，反对者担心出租房供应下降。方案还没表决。",
            "回到刚才记忆形成的话题。嘉宾补充说主动回想比反复重读更有助于保持记忆，练习可以间隔几天进行。"
        ]
        var map = ConversationMindMap()
        var retained: [ConversationMindMap.Topic] = []
        if options.contains("--dense-only") {
            let seed = [
                #"{"topic":"new:1","kind":"advertisement","title":"云声耳机赞助信息","branch":"产品促销","text":"购买云声耳机可使用优惠码享受九折。","sources":[1]}"#,
                #"{"topic":"new:1","kind":"discussion","title":"记忆形成","branch":"记忆机制","text":"海马体参与新的情景记忆形成。","sources":[1]}"#,
                #"{"topic":"new:1","kind":"discussion","title":"住房政策讨论","branch":"租金调控影响","text":"市议会拟限制租金涨幅，支持者认为有利于租客，反对者担忧出租房供应下降。","sources":[1]}"#,
                #"{"topic":"T2","kind":"discussion","title":"主动回想促进记忆保持","branch":"记忆机制","text":"主动回想比反复重读更有助于保持记忆，建议间隔几天进行练习。","sources":[1]}"#
            ]
            for index in stages.indices {
                let entry = CaptionEntry(timestamp: .now, englishText: stages[index], chineseText: "")
                map = try map.adding(seed[index], batch: SummaryTranscript.batches([entry])[0])
            }
        } else {
        for (index, input) in stages.enumerated() {
            let entry = CaptionEntry(timestamp: .now, englishText: input, chineseText: "")
            let batch = SummaryTranscript.batches([entry])[0]
            let before = map
            var updates = 0, firstPoint = false
            var lastPartial = ""
            let output: String
            do { output = try await service.summarize(batch.input, previous: map.context(for: batch.input), validating: { _ = try before.adding($0, batch: batch) }) { partial in
                lastPartial = partial
                updates += 1
                if !firstPoint, let preview = try? before.adding(partial, batch: batch, isDraft: true), preview.outline != before.outline {
                    firstPoint = true
                    print("STAGE=\(index + 1) FIRST_NODE seconds=\(Date().timeIntervalSince(start))")
                    fflush(nil)
                }
            } } catch {
                print("STAGE=\(index + 1) SERVICE_FAILED last_partial=\(lastPartial)")
                fflush(nil)
                throw error
            }
            print("STAGE=\(index + 1) RAW_PATCH\n" + output)
            fflush(nil)
            map = try before.adding(output, batch: batch)
            print("STAGE=\(index + 1) COMPLETE seconds=\(Date().timeIntervalSince(start)) updates=\(updates)")
            print("PATCH\n" + output + "\nFOREST\n" + map.outline)
            fflush(nil)
            if index == 0 {
                guard map.topics.count == 1, map.topics[0].kind == .advertisement else { throw SummaryError.invalidResult }
            } else {
                guard map.topics[0] == retained[0] else { throw SummaryError.invalidResult }
                for topic in retained {
                    guard let next = map.topics.first(where: { $0.id == topic.id }),
                          next.title == topic.title, next.kind == topic.kind else { throw SummaryError.invalidResult }
                    for branch in topic.branches {
                        guard let nextBranch = next.branches.first(where: { $0.id == branch.id }),
                              Array(nextBranch.points.prefix(branch.points.count)) == branch.points else { throw SummaryError.invalidResult }
                    }
                }
            }
            if index == 1 {
                guard map.topics.count == 2, map.topics[1].kind == .discussion else { throw SummaryError.invalidResult }
            }
            if index == 2 {
                guard map.topics.count == 3 else { throw SummaryError.invalidResult }
            }
            if index == 3 {
                guard map.topics.count == 3,
                      map.topics[1].branches.flatMap(\.points).count > retained[1].branches.flatMap(\.points).count,
                      map.topics[2] == retained[2] else { throw SummaryError.invalidResult }
            }
            retained = map.topics
        }
        print("PASS independent_advertisement_and_two_subjects_stable_ids_return_to_topic")
        fflush(nil)
        }
        let denseFacts = [
            "关于记忆形成，情绪唤醒有时会增强记忆，但不保证所有细节准确。",
            "关于记忆形成，提取记忆受情境影响，环境线索可能帮助回忆。",
            "关于记忆形成，工作记忆容量有限，多任务可能增加负担。",
            "关于记忆形成，新旧知识之间建立联系可能帮助理解和保持。",
            "关于记忆形成，目击者的回忆可能受到事后信息影响。",
            "关于记忆形成，熟悉感不等于能准确解释所学知识。",
            "关于记忆形成，练习后获得反馈可以发现理解错误。",
            "关于记忆形成，运动可能有益于认知，但不能保证治疗记忆障碍。"
        ]
        let denseBatch = SummaryTranscript.batches(denseFacts.map { CaptionEntry(timestamp: .now, englishText: $0, chineseText: "") })[0]
        let old = map
        var densePartial = ""
        let additions: String
        do {
            additions = try await service.summarize(denseBatch.input, previous: map.context(for: denseBatch.input), validating: { _ = try old.adding($0, batch: denseBatch) }) { densePartial = $0 }
        } catch {
            print("DENSE SERVICE_FAILED last_partial=\(densePartial)"); fflush(nil)
            throw error
        }
        print("DENSE RAW_PATCH\n" + additions); fflush(nil)
        map = try map.adding(additions, batch: denseBatch)
        print("DENSE PATCH\n" + additions + "\nDENSE FOREST\n" + map.outline)
        let added = map.topics.flatMap(\.branches).flatMap(\.points).count - old.topics.flatMap(\.branches).flatMap(\.points).count
        print("DENSE COMPLETE seconds=\(Date().timeIntervalSince(start)) added=\(added)")
        fflush(nil)
        let newSources = Set(denseBatch.records.map(\.sourceID))
        let newPoints = map.topics.flatMap(\.branches).flatMap(\.points).filter { !$0.sources.isDisjoint(with: newSources) }
        let combinesSources = newPoints.contains { $0.sources.intersection(newSources).count >= 2 }
        let concise = newPoints.allSatisfy { $0.text.count <= 40 && $0.text.filter { $0 == "；" || $0 == ";" }.count <= 1 }
            && newPoints.reduce(0) { $0 + $1.text.count } <= 180
        guard (1...3).contains(added), combinesSources, concise, map.topics.count == 3, map.topics[0] == old.topics[0], map.topics[2] == old.topics[2] else {
            throw SummaryError.invalidResult
        }
        print("PASS dense_fact_batch_consolidated_into_1_to_3_updates_with_combined_sources")
    }
    /// Repeated paraphrases, named branches, stable identity, and genuinely new
    /// qualifiers exercise the production incremental path, not a static mock.
    @MainActor private static func verifyMindMap(service: any ConversationSummaryProviding, start: Date) async throws {
        let stages = [
            "This episode is sponsored by CloudTone headphones. Use the promo code for ten percent off. The advertisement ends here.",
            "Now our main conversation: what makes coding AI successful. To train an effective coding AI, you need enough coding training data. Very few organizations have enough: Anthropic, OpenAI, and Cursor. Perhaps Google also has enough, but that is only a possibility.",
            "You really have to have the data to train a useful coding AI. The organizations with enough coding data are Anthropic, OpenAI and Cursor, and arguably perhaps Google. Without sufficient code data, that training cannot work.",
            "Continuing with coding AI success: without coding ability, AI usefulness is limited. Success also needs talented people and compute. A good enterprise sales team and relationships with thousands of companies are commercial conditions. Cursor has many talented people.",
            "So, basically, if your AI cannot do coding, it will not be very useful. It takes talented people and compute, and also a good enterprise sales team with relationships across thousands of companies. Cursor has a lot of talented people.",
            "Now a separate event: the city council is debating rent controls. Supporters expect benefits for renters; opponents fear reduced rental supply. No vote has been held yet.",
            "Returning to coding AI: the speaker corrects the earlier possibility about Google. Google does not have enough coding training data. The earlier suggestion that Google might have enough is withdrawn."
        ]
        var map = ConversationMindMap()
        var primaryID = ""
        for (index, text) in stages.enumerated() {
            let batch = SummaryTranscript.batches([CaptionEntry(timestamp: .now, englishText: text, chineseText: "")])[0]
            let baseline = map
            let context = baseline.context(for: batch.input)
            var partial = ""
            let output: String
            do {
                output = try await service.summarize(batch.input, previous: context, validating: { _ = try baseline.adding($0, batch: batch) }) { partial = $0 }
            } catch {
                print("MINDMAP FAILED STAGE=\(index + 1) CONTEXT\n" + context + "\nLAST_PATCH\n" + partial)
                fflush(nil)
                throw error
            }
            print("MINDMAP STAGE=\(index + 1) PATCH\n" + output)
            map = try baseline.adding(output, batch: batch)
            print("FOREST\n" + map.outline); fflush(nil)
            if index == 0 {
                guard map.topics.count == 1, map.topics[0].kind == .advertisement else { throw SummaryError.invalidResult }
            } else {
                guard map.topics[0] == baseline.topics[0] else { throw SummaryError.invalidResult }
            }
            if index == 1 {
                guard map.topics.count == 2, map.topics[1].kind == .discussion else { throw SummaryError.invalidResult }
                primaryID = map.topics[1].id
            }
            if index == 2 || index == 4 {
                let old = baseline.topics.flatMap(\.branches).flatMap(\.points)
                let new = map.topics.flatMap(\.branches).flatMap(\.points)
                guard new.map(\.id) == old.map(\.id), map.topics.count == baseline.topics.count else { throw SummaryError.invalidResult }
                print("PASS repeated_paraphrase_adds_no_nodes stage=\(index + 1)")
            }
            if index == 3 {
                guard let topic = map.topics.first(where: { $0.id == primaryID }), topic.branches.count >= 3,
                      topic.branches.allSatisfy({ !["要点", "总结"].contains($0.title) && $0.points.allSatisfy { $0.text.count <= 40 } }) else { throw SummaryError.invalidResult }
                print("PASS meaningful_branches_and_short_nodes")
            }
            if index == 5 {
                guard map.topics.count == 3, map.topics[1] == baseline.topics[1] else { throw SummaryError.invalidResult }
            }
            if index == 6 {
                guard map.topics.count == 3, map.topics[2] == baseline.topics[2],
                      let before = baseline.topics.first(where: { $0.id == primaryID }),
                      let after = map.topics.first(where: { $0.id == primaryID }),
                      after.branches.flatMap(\.points).count > before.branches.flatMap(\.points).count else { throw SummaryError.invalidResult }
                print("PASS correction_is_new_node_without_rewriting_other_topics")
            }
        }
        print("MINDMAP COMPLETE seconds=\(Date().timeIntervalSince(start)) topics=\(map.topics.count)")
    }

}
