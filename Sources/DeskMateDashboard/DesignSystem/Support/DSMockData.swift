//
//  DSMockData.swift
//  Sample content so every component renders with something believable.
//  Swap these for your real model later — nothing in the design system
//  depends on these types.
//

import Foundation

struct DSMockTask: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var meta: String
    var tags: [String] = []
    var isDone: Bool = false
}

struct DSMockHabit: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var goal: String
    var streak: Int
    /// Seven booleans, Monday first.
    var week: [Bool]
}

enum DSMock {
    static let tasks: [DSMockTask] = [
        DSMockTask(
            title: "Draft the investor update",
            meta: "Due 4:00 PM · 45 min",
            tags: ["Deep work", "Writing"]
        ),
        DSMockTask(
            title: "Review onboarding flow",
            meta: "Completed 11:20 AM",
            isDone: true
        ),
        DSMockTask(
            title: "Weekly review",
            meta: "Recurring · Sundays",
            tags: ["Ritual"]
        ),
        DSMockTask(
            title: "Reply to design feedback",
            meta: "Overdue by 1 day",
            tags: ["Quick"]
        )
    ]

    static let habits: [DSMockHabit] = [
        DSMockHabit(
            title: "Morning pages",
            goal: "Three pages before anything else",
            streak: 12,
            week: [true, true, true, false, true, true, false]
        ),
        DSMockHabit(
            title: "Walk after lunch",
            goal: "Twenty minutes, no podcast",
            streak: 4,
            week: [false, true, true, true, true, false, false]
        )
    ]

    static let tabs: [DSTabItem] = [
        DSTabItem(id: "today", title: "Today", systemImage: "sun.horizon"),
        DSTabItem(id: "tasks", title: "Tasks", systemImage: "checklist", badge: 3),
        DSTabItem(id: "stats", title: "Stats", systemImage: "chart.bar"),
        DSTabItem(id: "you", title: "You", systemImage: "person")
    ]
}
