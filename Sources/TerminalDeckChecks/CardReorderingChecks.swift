import CoreGraphics
import Foundation
import TerminalDeckKit

private func reorderCards() -> [PresetCard] {
    [
        PresetCard(id: "a", title: "A", command: "echo a", tagId: "pi"),
        PresetCard(id: "b", title: "B", command: "echo b", tagId: "pi"),
        PresetCard(id: "c", title: "C", command: "echo c", tagId: "script"),
        PresetCard(id: "d", title: "D", command: "echo d"),
    ]
}

func registerCardReorderingChecks() {
    register("reordering.same-group-inserts-without-changing-fields") {
        let original = reorderCards()
        let moved = try expectUnwrap(PresetCardReordering.moving(original, id: "b",
            to: CardDropDestination(tagId: "pi", beforeCardID: "a")), "move B before A")
        try expectEqual(moved.map(\.id), ["b", "a", "c", "d"], "inserts rather than swaps")
        try expectEqual(moved.first, original[1], "all card fields stay intact")
        try expectEqual(original.map(\.id), ["a", "b", "c", "d"], "preview does not mutate the source")
        let end = try expectUnwrap(PresetCardReordering.moving(moved, id: "b",
            to: CardDropDestination(tagId: "pi")), "append within Pi")
        try expectEqual(end.filter { $0.tagId == "pi" }.map(\.id), ["a", "b"], "can move to group end")
    }

    register("reordering.cross-group-replaces-tag-and-hides-empty-block") {
        let original = reorderCards()
        let moved = try expectUnwrap(PresetCardReordering.moving(original, id: "c",
            to: CardDropDestination(tagId: "pi", beforeCardID: "b")), "move Script card to Pi")
        var expected = original[2]
        expected.tagId = "pi"
        try expectEqual(moved.first { $0.id == "c" }, expected, "only tag changes; title/config/timestamps survive")
        let tags = [CardTag(id: "pi", name: "Pi"), CardTag(id: "script", name: "Script", sortOrder: 1)]
        let sections = CardGrouping.sections(items: moved, tags: tags, tagId: \.tagId)
        try expectEqual(sections.map(\.id), ["pi", ""], "last card leaves no empty Script header")
        try expectEqual(sections.first?.items.map(\.id), ["a", "c", "b"], "target insertion position is respected")
        try expectEqual(tags.count, 2, "hiding an empty block does not delete its tag")
    }

    register("reordering.untagged-clears-tag-and-stays-last") {
        let original = reorderCards()
        let moved = try expectUnwrap(PresetCardReordering.moving(original, id: "c",
            to: CardDropDestination(tagId: nil, beforeCardID: "d")), "move into untagged")
        try expectEqual(moved.first { $0.id == "c" }?.tagId, nil, "untagged removes the reference")
        let sections = CardGrouping.sections(items: moved,
            tags: [CardTag(id: "pi", name: "Pi"), CardTag(id: "script", name: "Script")], tagId: \.tagId)
        try expectEqual(sections.last?.items.map(\.id), ["c", "d"], "untagged is ordered and remains last")
    }

    register("reordering.invalid-destinations-do-not-move-cards") {
        let cards = reorderCards()
        for (id, destination) in [
            ("missing", CardDropDestination(tagId: "pi")),
            ("a", CardDropDestination(tagId: "pi", beforeCardID: "a")),
            ("a", CardDropDestination(tagId: "pi", beforeCardID: "missing")),
            ("a", CardDropDestination(tagId: "pi", beforeCardID: "c")),
        ] {
            try expectEqual(PresetCardReordering.moving(cards, id: id, to: destination), nil,
                            "stale/self/wrong-group anchor is rejected")
        }
    }

    register("reordering.saved-order-tolerates-stale-duplicate-and-new-ids") {
        let cards = reorderCards()
        let stored = PresetCardReordering.storageValue(ids: ["c", "gone", "b", "c"])
        try expectEqual(PresetCardReordering.ordered(cards, stored: stored).map(\.id), ["c", "b", "a", "d"],
                        "deleted ids are ignored, duplicates removed, new cards appended")
        for invalid in [nil, "", "not-json", "{}", "[1]"] as [String?] {
            try expectEqual(PresetCardReordering.ordered(cards, stored: invalid), cards,
                            "missing/corrupt order preserves existing order")
        }
    }

    register("reordering.hit-test-distinguishes-header-row-halves-and-placeholder") {
        let first = CardDropDestination(tagId: "pi", beforeCardID: "a")
        let second = CardDropDestination(tagId: "pi", beforeCardID: "b")
        let end = CardDropDestination(tagId: "pi")
        let regions = [
            CardDropRegion(frame: CGRect(x: 10, y: 0, width: 220, height: 28), before: first, after: first),
            CardDropRegion(frame: CGRect(x: 10, y: 28, width: 220, height: 44), before: first, after: second),
            CardDropRegion(frame: CGRect(x: 10, y: 72, width: 220, height: 44), before: second, after: end),
        ]
        try expectEqual(CardDropRegion.destination(at: CGPoint(x: 50, y: 14), in: regions), first, "header inserts first")
        try expectEqual(CardDropRegion.destination(at: CGPoint(x: 50, y: 30), in: regions), first, "upper half inserts before")
        try expectEqual(CardDropRegion.destination(at: CGPoint(x: 50, y: 60), in: regions), second, "lower half inserts after")
        try expectEqual(CardDropRegion.destination(at: CGPoint(x: 50, y: 110), in: regions), end, "last row can append")
        try expectEqual(CardDropRegion.destination(at: CGPoint(x: 400, y: 60), in: regions), nil, "outside sidebar cancels")
        try expectEqual(CardDropRegion.destination(at: CGPoint(x: 50, y: 200), in: regions), nil, "other menus are not targets")
        try expectEqual(CardDropRegion.destination(at: .zero, in: []), nil, "no layout means no target")
    }

    register("reordering.store-persists-tag-and-order-together") {
        let (store, root) = try makeStore("card-move")
        defer { TempSpace.clean(root) }
        try store.save(CardTag(id: "pi", name: "Pi"))
        try store.save(CardTag(id: "script", name: "Script", sortOrder: 1))
        for card in reorderCards() { try store.save(card) }
        try store.save(SessionRecord(id: "session", kind: .preset, ownerId: "c", title: "C", shell: "/bin/zsh"))
        let moved = try store.movePresetCard(id: "c", to: CardDropDestination(tagId: "pi", beforeCardID: "a"))
        let reopened = try TerminalDeckStore(directory: root)
        try expectEqual(try reopened.cards().map(\.id), moved.map(\.id), "order survives reopening")
        try expectEqual(try reopened.cards().first?.tagId, "pi", "tag survives reopening")
        try expectEqual(try reopened.tags().map(\.id), ["pi", "script"], "empty tag is retained")
        try expectEqual(try reopened.session(id: "session")?.ownerId, "c", "session is untouched")
        try expectEqual(try storeSchemaVersion(reopened), TerminalDeckStore.schemaVersion, "reordering does not change the current schema version")
        _ = try store.movePresetCard(id: "c", to: CardDropDestination(tagId: nil))
        try expectEqual(try store.cards().first { $0.id == "c" }?.tagId, nil, "untagged also persists")
    }

    register("reordering.store-rolls-back-tag-when-order-write-fails") {
        let (store, root) = try makeStore("card-move-rollback")
        defer { TempSpace.clean(root) }
        try store.save(CardTag(id: "pi", name: "Pi"))
        try store.save(CardTag(id: "script", name: "Script"))
        for card in reorderCards() { try store.save(card) }
        let before = try store.cards()
        try store.database.execute("""
        CREATE TRIGGER reject_card_order BEFORE INSERT ON settings
        WHEN NEW.key = 'preset_card_order'
        BEGIN SELECT RAISE(ABORT, 'simulated order write failure'); END;
        """)
        _ = try expectThrows("failed ordering write") {
            try store.movePresetCard(id: "c", to: CardDropDestination(tagId: "pi"))
        }
        try expectEqual(try store.cards(), before, "neither tag nor order is partially saved")
        try expectEqual(try store.string(forKey: PresetCardReordering.storageKey), nil, "no order setting leaked")
    }

    register("reordering.store-rejects-stale-card-tag-and-anchor") {
        let (store, root) = try makeStore("card-move-stale")
        defer { TempSpace.clean(root) }
        try store.save(CardTag(id: "pi", name: "Pi"))
        try store.save(CardTag(id: "script", name: "Script"))
        for card in reorderCards() { try store.save(card) }
        let before = try store.cards()
        for (id, destination) in [
            ("gone", CardDropDestination(tagId: "pi")),
            ("a", CardDropDestination(tagId: "gone")),
            ("a", CardDropDestination(tagId: "pi", beforeCardID: "gone")),
        ] {
            _ = try expectThrows("stale drag destination") { try store.movePresetCard(id: id, to: destination) }
        }
        try expectEqual(try store.cards(), before, "stale drag never overwrites newer data")
    }
}
