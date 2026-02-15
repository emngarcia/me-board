import SwiftUI
import SwiftData
import Combine

// MARK: - Data Model

struct Prediction: Codable, Identifiable {
    let eventId: UUID
    let createdAt: Date
    let label: String
    let score: Double
    let modelVersion: String

    var id: UUID { eventId }

    var isWorrisome: Bool { label == "worrisome" }
    var confidencePercent: Double { score * 100 }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case createdAt = "created_at"
        case label
        case score
        case modelVersion = "model_version"
    }
}

// MARK: - Supabase REST Client

class SupabaseRESTClient {
    private let baseURL = "https://upkozoxjukgofgkidbyq.supabase.co/rest/v1"
    private let apiKey  = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVwa296b3hqdWtnb2Zna2lkYnlxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEwOTk4NzMsImV4cCI6MjA4NjY3NTg3M30.xmzK9_5SIp8xoRDCxeOnqSS7bWNJus3Ofp2C0GynQoY"

    private lazy var decoder: JSONDecoder = {
        let d = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(string)"
            )
        }
        return d
    }()

    func fetchPredictions() async throws -> [Prediction] {
        var components = URLComponents(string: "\(baseURL)/predictions")!
        components.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "created_at.desc")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(statusCode): \(body)"
            ])
        }

        return try decoder.decode([Prediction].self, from: data)
    }
}

// MARK: - View Model

@MainActor
class MentalHealthViewModel: ObservableObject {
    @Published var predictions: [Prediction] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Personalized message from Claude based on today's keyboard events
    @Published var personalizedTitle: String? = nil
    @Published var personalizedBody: String? = nil
    @Published var personalizedSuggestion: String? = nil
    @Published var isPersonalized = false
    @Published var isLoadingPersonalized = false

    /// How long before we re-fetch the personalized message (15 minutes)
    private let personalizedCacheDuration: TimeInterval = 15 * 60
    private var lastPersonalizedFetch: Date? = nil

    private let client = SupabaseRESTClient()

    /// Fetch everything — personalized message only if stale or never fetched
    func fetchAll() async {
        isLoading = true
        errorMessage = nil

        // Always fetch predictions
        async let predictionsTask: () = fetchPredictionsOnly()

        // Only fetch personalized if cache is stale
        let needsPersonalized = lastPersonalizedFetch == nil ||
            Date().timeIntervalSince(lastPersonalizedFetch!) > personalizedCacheDuration

        if needsPersonalized {
            isLoadingPersonalized = true
            async let personalizedTask: () = fetchPersonalizedOnly()
            await predictionsTask
            await personalizedTask
        } else {
            await predictionsTask
        }
    }

    /// Force refresh everything (pull-to-refresh)
    func forceRefreshAll() async {
        lastPersonalizedFetch = nil
        await fetchAll()
    }

    func fetchPredictions() async {
        isLoading = true
        errorMessage = nil

        do {
            predictions = try await client.fetchPredictions()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func fetchPredictionsOnly() async {
        do {
            predictions = try await client.fetchPredictions()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func fetchPersonalizedOnly() async {
        do {
            let response = try await ChatAPI.shared.fetchPersonalizedMessage()
            if response.ok {
                personalizedTitle = response.title
                personalizedBody = response.body
                personalizedSuggestion = response.suggestion
                isPersonalized = response.personalized ?? false
                lastPersonalizedFetch = Date()
            }
        } catch {
            // Silently fail — fall back to static message
        }
        isLoadingPersonalized = false
    }

    func fetchPersonalizedMessage() async {
        isLoadingPersonalized = true
        await fetchPersonalizedOnly()
    }

    // MARK: - Analytics

    var worrisomePercentage: Double {
        guard !predictions.isEmpty else { return 0 }
        return Double(predictions.filter(\.isWorrisome).count) / Double(predictions.count) * 100
    }

    var averageConfidence: Double {
        guard !predictions.isEmpty else { return 0 }
        return predictions.map(\.score).reduce(0, +) / Double(predictions.count) * 100
    }

    var trendDirection: TrendResult {
        guard predictions.count >= 4 else { return .insufficientData }

        let sorted = predictions.sorted { $0.createdAt < $1.createdAt }
        let midpoint = sorted.count / 2
        let olderHalf = Array(sorted[..<midpoint])
        let newerHalf = Array(sorted[midpoint...])

        let olderRate = Double(olderHalf.filter(\.isWorrisome).count) / Double(olderHalf.count)
        let newerRate = Double(newerHalf.filter(\.isWorrisome).count) / Double(newerHalf.count)

        let delta = newerRate - olderRate
        if delta < -0.1 { return .improving }
        else if delta > 0.1 { return .worsening }
        else { return .stable }
    }

    var latestPrediction: Prediction? { predictions.first }

    // MARK: - Daily Summaries

    var dailySummaries: [DailySummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: predictions) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.map { date, preds in
            let worrisomeCount = preds.filter(\.isWorrisome).count
            let benignCount = preds.count - worrisomeCount
            return DailySummary(
                date: date,
                totalEvents: preds.count,
                worrisomeCount: worrisomeCount,
                benignCount: benignCount,
                worrisomeRate: Double(worrisomeCount) / Double(preds.count),
                averageConfidence: preds.map(\.score).reduce(0, +) / Double(preds.count)
            )
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: - Weekly Summaries (group by ISO week)

    var weeklySummaries: [WeekSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: predictions) { pred -> Date in
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: pred.createdAt)
            return calendar.date(from: comps) ?? pred.createdAt
        }
        return grouped.map { weekStart, preds in
            let worrisomeCount = preds.filter(\.isWorrisome).count
            let benignCount = preds.count - worrisomeCount
            let daysActive = Set(preds.map { calendar.startOfDay(for: $0.createdAt) }).count
            let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            return WeekSummary(
                weekStart: weekStart,
                weekEnd: weekEnd,
                totalEvents: preds.count,
                worrisomeCount: worrisomeCount,
                benignCount: benignCount,
                worrisomeRate: Double(worrisomeCount) / Double(preds.count),
                daysActive: daysActive
            )
        }
        .sorted { $0.weekStart < $1.weekStart }
    }

    // MARK: - Monthly Summaries

    var monthlySummaries: [MonthSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: predictions) { pred -> Date in
            let comps = calendar.dateComponents([.year, .month], from: pred.createdAt)
            return calendar.date(from: comps) ?? pred.createdAt
        }
        return grouped.map { monthStart, preds in
            let worrisomeCount = preds.filter(\.isWorrisome).count
            let benignCount = preds.count - worrisomeCount
            let daysActive = Set(preds.map { calendar.startOfDay(for: $0.createdAt) }).count
            let totalDaysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
            return MonthSummary(
                monthStart: monthStart,
                totalEvents: preds.count,
                worrisomeCount: worrisomeCount,
                benignCount: benignCount,
                worrisomeRate: Double(worrisomeCount) / Double(preds.count),
                daysActive: daysActive,
                totalDaysInMonth: totalDaysInMonth
            )
        }
        .sorted { $0.monthStart < $1.monthStart }
    }

    // MARK: - Today's Analysis

    var todayWorrisomeRate: Double {
        let todayPreds = predictions.filter { Calendar.current.isDateInToday($0.createdAt) }
        guard !todayPreds.isEmpty else { return 0 }
        return Double(todayPreds.filter(\.isWorrisome).count) / Double(todayPreds.count)
    }

    var todayEventCount: Int {
        predictions.filter { Calendar.current.isDateInToday($0.createdAt) }.count
    }

    var isStrugglingToday: Bool {
        todayEventCount >= 1 && todayWorrisomeRate > 0.5
    }

    // MARK: - This Week Summary (for recap card)

    var thisWeekSummary: WeekSummary {
        let calendar = Calendar.current
        let oneWeekAgo = calendar.date(byAdding: .day, value: -7, to: Date())!
        let weekPreds = predictions.filter { $0.createdAt >= oneWeekAgo }
        let total = weekPreds.count
        let worrisome = weekPreds.filter(\.isWorrisome).count
        let benign = total - worrisome
        let daysActive = Set(weekPreds.map { calendar.startOfDay(for: $0.createdAt) }).count

        return WeekSummary(
            weekStart: oneWeekAgo,
            weekEnd: Date(),
            totalEvents: total,
            worrisomeCount: worrisome,
            benignCount: benign,
            worrisomeRate: total > 0 ? Double(worrisome) / Double(total) : 0,
            daysActive: daysActive
        )
    }

    // MARK: - Empathetic Message

    var empatheticMessage: EmpatheticMessage {
        // Use personalized message from Claude if available
        if isPersonalized,
           let title = personalizedTitle,
           let body = personalizedBody {
            return EmpatheticMessage(
                icon: isStrugglingToday ? "heart" : "sparkles",
                title: title,
                body: body,
                suggestion: personalizedSuggestion,
                tone: isStrugglingToday || todayWorrisomeRate > 0.35 ? .supportive : .encouraging
            )
        }

        // Fallback to static messages
        if todayEventCount == 0 {
            return EmpatheticMessage(
                icon: "sun.max",
                title: "Welcome back",
                body: "No events recorded today yet. How are you feeling?",
                suggestion: nil,
                tone: .neutral
            )
        }

        if isStrugglingToday {
            let percentage = Int(todayWorrisomeRate * 100)
            return EmpatheticMessage(
                icon: "heart",
                title: "It's okay to have tough days",
                body: "About \(percentage)% of today's signals suggest you might be going through something. That's completely normal — you're not alone in this.",
                suggestion: "Writing down your thoughts can help process what you're feeling. Would you like to journal?",
                tone: .supportive
            )
        }

        switch trendDirection {
        case .worsening:
            return EmpatheticMessage(
                icon: "leaf",
                title: "Be gentle with yourself",
                body: "Things have been a bit heavier lately. Remember that reaching out — even to a journal — is a sign of strength.",
                suggestion: "Try writing about one small thing that brought you comfort today.",
                tone: .supportive
            )
        case .improving:
            return EmpatheticMessage(
                icon: "sparkles",
                title: "You're doing great",
                body: "Your recent trend is looking brighter. Whatever you've been doing, keep it up — it's working.",
                suggestion: nil,
                tone: .encouraging
            )
        case .stable:
            return EmpatheticMessage(
                icon: "hand.thumbsup",
                title: "Steady and strong",
                body: "Things have been fairly consistent. Staying aware of your mental health is already a powerful step.",
                suggestion: nil,
                tone: .encouraging
            )
        case .insufficientData:
            return EmpatheticMessage(
                icon: "chart.line.uptrend.xyaxis",
                title: "Building your picture",
                body: "A few more entries and we'll be able to show you meaningful trends. Keep going!",
                suggestion: nil,
                tone: .neutral
            )
        }
    }
}

// MARK: - Supporting Types

enum TrendResult {
    case improving, stable, worsening, insufficientData

    var label: String {
        switch self {
        case .improving: return "Improving"
        case .stable: return "Stable"
        case .worsening: return "Needs Attention"
        case .insufficientData: return "Not Enough Data"
        }
    }

    var icon: String {
        switch self {
        case .improving: return "arrow.down.right"
        case .stable: return "arrow.right"
        case .worsening: return "arrow.up.right"
        case .insufficientData: return "questionmark"
        }
    }

    var color: Color {
        switch self {
        case .improving: return .earthAccent
        case .stable: return .earthSage
        case .worsening: return .orange
        case .insufficientData: return .earthStone
        }
    }
}

// MARK: - Period Feeling (shared across daily/weekly/monthly)

enum PeriodFeeling {
    case good, mixed, tough, hard

    var icon: String {
        switch self {
        case .good: return "sun.max.fill"
        case .mixed: return "cloud.sun.fill"
        case .tough: return "cloud.fill"
        case .hard: return "cloud.rain.fill"
        }
    }

    var color: Color {
        switch self {
        case .good: return .earthAccent
        case .mixed: return .earthSage
        case .tough: return .orange
        case .hard: return .orange.opacity(0.8)
        }
    }

    static func from(worrisomeRate: Double) -> PeriodFeeling {
        if worrisomeRate < 0.25 { return .good }
        else if worrisomeRate < 0.5 { return .mixed }
        else if worrisomeRate < 0.75 { return .tough }
        else { return .hard }
    }
}

// MARK: - Daily Summary

struct DailySummary: Identifiable {
    let date: Date
    let totalEvents: Int
    let worrisomeCount: Int
    let benignCount: Int
    let worrisomeRate: Double
    let averageConfidence: Double
    var id: Date { date }

    var feeling: PeriodFeeling { .from(worrisomeRate: worrisomeRate) }

    var label: String {
        switch feeling {
        case .good: return "Good day"
        case .mixed: return "Mixed day"
        case .tough: return "Tough day"
        case .hard: return "Hard day"
        }
    }

    var message: String {
        switch feeling {
        case .good:
            return "This was a bright day. Whatever you did, it was working for you."
        case .mixed:
            return "A bit of both — and that's perfectly normal. Not every moment needs to be easy."
        case .tough:
            return "This day was heavier than most. Be proud that you showed up anyway."
        case .hard:
            return "This was a really hard day. You got through it — that takes more strength than you know."
        }
    }
}

// MARK: - Week Summary

struct WeekSummary: Identifiable {
    let weekStart: Date
    let weekEnd: Date
    let totalEvents: Int
    let worrisomeCount: Int
    let benignCount: Int
    let worrisomeRate: Double
    let daysActive: Int
    var id: Date { weekStart }

    var feeling: PeriodFeeling { .from(worrisomeRate: worrisomeRate) }

    var label: String {
        switch feeling {
        case .good: return "Good week"
        case .mixed: return "Mixed week"
        case .tough: return "Tough week"
        case .hard: return "Hard week"
        }
    }

    var message: String {
        switch feeling {
        case .good:
            return "This was a strong week. You were in a good place — hold onto what helped you get there."
        case .mixed:
            return "Some days were lighter, some heavier. That balance is part of the journey and you handled it."
        case .tough:
            return "This week asked a lot of you. The fact that you kept going says everything about your resilience."
        case .hard:
            return "This was a really heavy week. Please be extra kind to yourself — you deserve that grace right now."
        }
    }

    var dateRangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: weekStart)
        let end = formatter.string(from: weekEnd)
        return "\(start) – \(end)"
    }

    var isCurrentWeek: Bool {
        let calendar = Calendar.current
        return calendar.isDate(Date(), equalTo: weekStart, toGranularity: .weekOfYear)
    }
}

// MARK: - Month Summary

struct MonthSummary: Identifiable {
    let monthStart: Date
    let totalEvents: Int
    let worrisomeCount: Int
    let benignCount: Int
    let worrisomeRate: Double
    let daysActive: Int
    let totalDaysInMonth: Int
    var id: Date { monthStart }

    var feeling: PeriodFeeling { .from(worrisomeRate: worrisomeRate) }

    var label: String {
        switch feeling {
        case .good: return "Good month"
        case .mixed: return "Mixed month"
        case .tough: return "Tough month"
        case .hard: return "Hard month"
        }
    }

    var message: String {
        switch feeling {
        case .good:
            return "A month of mostly good days. You've built real momentum — trust that it's carrying you forward."
        case .mixed:
            return "This month had its share of both light and shadow. Growth doesn't always feel good, but you're growing."
        case .tough:
            return "This month was harder than most. You made it through every single day of it — don't underestimate what that took."
        case .hard:
            return "This was a truly difficult month. You've been carrying a lot, and it's okay to set some of it down. You don't have to do this alone."
        }
    }

    var monthLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: monthStart)
    }

    var isCurrentMonth: Bool {
        let calendar = Calendar.current
        return calendar.isDate(Date(), equalTo: monthStart, toGranularity: .month)
    }

    var consistencyMessage: String {
        let pct = totalDaysInMonth > 0 ? Int(Double(daysActive) / Double(totalDaysInMonth) * 100) : 0
        if pct >= 80 {
            return "You were active \(daysActive) of \(totalDaysInMonth) days — incredible consistency."
        } else if pct >= 50 {
            return "Active \(daysActive) of \(totalDaysInMonth) days — you're showing up more often than not."
        } else {
            return "Active \(daysActive) of \(totalDaysInMonth) days — every day you check in counts."
        }
    }
}

struct EmpatheticMessage {
    let icon: String
    let title: String
    let body: String
    let suggestion: String?
    let tone: Tone

    enum Tone {
        case supportive, encouraging, neutral
    }
}

// MARK: - Mood Check-in

enum MoodLevel: Int, CaseIterable {
    case struggling = 1
    case rough = 2
    case okay = 3
    case good = 4
    case great = 5

    var emoji: String {
        switch self {
        case .struggling: return "😔"
        case .rough: return "😕"
        case .okay: return "😐"
        case .good: return "🙂"
        case .great: return "😊"
        }
    }

    var label: String {
        switch self {
        case .struggling: return "Struggling"
        case .rough: return "Rough"
        case .okay: return "Okay"
        case .good: return "Good"
        case .great: return "Great"
        }
    }

    var needsSupport: Bool {
        self == .struggling || self == .rough
    }
}

// MARK: - Reflection Time Range

enum ReflectionRange: String, CaseIterable {
    case daily = "Days"
    case weekly = "Weeks"
    case monthly = "Months"
}

// MARK: - Main Dashboard View

struct MentalHealthDashboardView: View {
    @StateObject private var viewModel = MentalHealthViewModel()
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var journalEntries: [JournalEntry]

    @State private var showingNewEntry = false
    @State private var showingBreathingExercise = false
    @State private var todayMood: MoodLevel? = nil
    @State private var reflectionRange: ReflectionRange = .daily

    /// True when the top empathetic card is already showing journal/breathe buttons
    private var topCardShowsActions: Bool {
        viewModel.empatheticMessage.tone == .supportive
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.isLoading && viewModel.predictions.isEmpty {
                    ProgressView("Loading…")
                        .tint(.earthAccent)
                        .padding(.top, 60)
                } else if let error = viewModel.errorMessage, viewModel.predictions.isEmpty {
                    errorView(error)
                } else {
                    dashboardContent
                }
            }
            .background(Color.earthSand)
            .navigationTitle("The MeBoard")
            .foregroundStyle(Color.earthBark)
            .refreshable {
                await viewModel.forceRefreshAll()
            }
            .task {
                await viewModel.fetchAll()
            }
            .sheet(isPresented: $showingNewEntry) {
                NavigationStack {
                    JournalEditorView(mode: .create)
                }
            }
            .sheet(isPresented: $showingBreathingExercise) {
                BreathingExerciseView()
            }
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        VStack(spacing: 16) {
            empatheticCard
            moodCheckInCard
            journalStreakCard
            weeklyRecapCard
            yourDaysCard
        }
        .padding()
    }

    // MARK: - Empathetic Message Card

    private var empatheticCard: some View {
        Group {
            if viewModel.isLoadingPersonalized && !viewModel.isPersonalized {
                // Placeholder only on first load before any content exists
                empatheticCardPlaceholder
            } else {
                empatheticCardContent
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isLoadingPersonalized)
    }

    private var empatheticCardPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.earthSage.opacity(0.2))
                    .frame(width: 24, height: 24)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.earthSage.opacity(0.2))
                    .frame(width: 160, height: 20)
            }

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.earthSage.opacity(0.15))
                .frame(height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.earthSage.opacity(0.15))
                .frame(width: 220, height: 14)
        }
        .padding()
        .background(Color.earthCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var empatheticCardContent: some View {
        let msg = viewModel.empatheticMessage
        let bgColor: Color = {
            switch msg.tone {
            case .supportive: return Color.orange.opacity(0.08)
            case .encouraging: return Color.earthAccent.opacity(0.1)
            case .neutral: return Color.earthCard
            }
        }()
        let accentColor: Color = {
            switch msg.tone {
            case .supportive: return .orange
            case .encouraging: return .earthAccent
            case .neutral: return .earthSage
            }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: msg.icon)
                    .font(.title2)
                    .foregroundStyle(accentColor)
                Text(msg.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.earthBark)
            }

            Text(msg.body)
                .font(.subheadline)
                .foregroundStyle(Color.earthStone)
                .fixedSize(horizontal: false, vertical: true)

            if let suggestion = msg.suggestion {
                Text(suggestion)
                    .font(.subheadline.italic())
                    .foregroundStyle(Color.earthSage)
                    .padding(.top, 2)
            }

            HStack(spacing: 12) {
                if msg.tone == .supportive {
                    Button {
                        showingNewEntry = true
                    } label: {
                        Label("Write in Journal", systemImage: "pencil.line")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.earthAccent)
                            .clipShape(Capsule())
                    }

                    Button {
                        showingBreathingExercise = true
                    } label: {
                        Label("Breathe", systemImage: "wind")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.earthAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.earthAccent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding()
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Mood Check-In

    private var moodCheckInCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("How are you feeling?")
                    .font(.headline)
                    .foregroundStyle(Color.earthBark)
                Spacer()
                if todayMood != nil {
                    Button("Reset") { withAnimation { todayMood = nil } }
                        .font(.caption)
                        .foregroundStyle(Color.earthSage)
                }
            }

            if let mood = todayMood {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(mood.emoji)
                            .font(.system(size: 36))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You're feeling \(mood.label.lowercased())")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.earthBark)
                            Text(moodResponse(for: mood))
                                .font(.caption)
                                .foregroundStyle(Color.earthStone)
                        }
                        Spacer()
                    }

                    if mood.needsSupport && !topCardShowsActions {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sometimes putting feelings into words — even messy, unfinished ones — can take some of the weight off.")
                                .font(.caption)
                                .foregroundStyle(Color.earthSage)

                            HStack(spacing: 10) {
                                Button {
                                    showingNewEntry = true
                                } label: {
                                    Label("Journal about it", systemImage: "pencil.line")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.earthAccent)
                                        .clipShape(Capsule())
                                }

                                Button {
                                    showingBreathingExercise = true
                                } label: {
                                    Label("Take a breath", systemImage: "wind")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.earthAccent)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.earthAccent.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                HStack(spacing: 0) {
                    ForEach(MoodLevel.allCases, id: \.rawValue) { level in
                        Button {
                            withAnimation(.spring(response: 0.35)) {
                                todayMood = level
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(level.emoji)
                                    .font(.system(size: 28))
                                Text(level.label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.earthStone)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .background(Color.earthCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func moodResponse(for mood: MoodLevel) -> String {
        switch mood {
        case .struggling:
            return "Thank you for being honest with yourself. That alone takes courage."
        case .rough:
            return "Not every day is easy — and that's okay. You don't have to have it all together."
        case .okay:
            return "Somewhere in the middle is a perfectly valid place to be."
        case .good:
            return "That's great to hear. Savor the good moments."
        case .great:
            return "Love that for you! Keep riding that wave."
        }
    }

    // MARK: - Journal Streak

    private var journalStreakCard: some View {
        let streak = computeJournalStreak()

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(streak >= 3 ? Color.earthAccent.opacity(0.15) : Color.earthCard)
                    .frame(width: 52, height: 52)
                VStack(spacing: 0) {
                    Image(systemName: streak >= 3 ? "flame.fill" : "flame")
                        .font(.title3)
                        .foregroundStyle(streak >= 3 ? Color.earthAccent : Color.earthStone)
                    if streak > 0 {
                        Text("\(streak)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(streak >= 3 ? Color.earthAccent : Color.earthStone)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(streakTitle(for: streak))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.earthBark)
                Text(streakMessage(for: streak))
                    .font(.caption)
                    .foregroundStyle(Color.earthStone)
            }

            Spacer()

            if !hasJournaledToday {
                Button {
                    showingNewEntry = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.earthAccent)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.earthAccent)
            }
        }
        .padding()
        .background(Color.earthCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var hasJournaledToday: Bool {
        journalEntries.contains { Calendar.current.isDateInToday($0.createdAt) }
    }

    private func computeJournalStreak() -> Int {
        let calendar = Calendar.current
        let uniqueDays = Set(journalEntries.map { calendar.startOfDay(for: $0.createdAt) })
            .sorted(by: >)

        guard !uniqueDays.isEmpty else { return 0 }

        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        if !uniqueDays.contains(checkDate) {
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            if !uniqueDays.contains(checkDate) { return 0 }
        }

        for day in uniqueDays {
            if day == checkDate {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            } else if day < checkDate {
                break
            }
        }

        return streak
    }

    private func streakTitle(for streak: Int) -> String {
        if streak == 0 {
            return "Start your streak"
        } else {
            return "Streak: \(streak) day\(streak == 1 ? "" : "s")"
        }
    }

    private func streakMessage(for streak: Int) -> String {
        if streak == 0 {
            return "Write your first entry today to get started."
        } else if streak < 3 {
            return "Nice start — keep the momentum going!"
        } else if streak < 7 {
            return "You're building a real habit. This is where it starts to stick."
        } else if streak < 14 {
            return "Over a week strong. This is powerful stuff."
        } else if streak < 30 {
            return "Two weeks and counting. You're showing up for yourself every day."
        } else {
            return "A whole month of showing up. You should be incredibly proud."
        }
    }

    // MARK: - Weekly Recap (current week)

    private var weeklyRecapCard: some View {
        let summary = viewModel.thisWeekSummary
        let journalCount = journalEntriesThisWeek

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(Color.earthSage)
                Text("This Week")
                    .font(.headline)
                    .foregroundStyle(Color.earthBark)
            }

            if summary.totalEvents == 0 {
                Text("No events recorded this week yet. Check back soon!")
                    .font(.subheadline)
                    .foregroundStyle(Color.earthStone)
            } else {
                let benignPct = summary.totalEvents > 0
                    ? Int(Double(summary.benignCount) / Double(summary.totalEvents) * 100)
                    : 0

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.2))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.earthAccent)
                            .frame(width: geo.size.width * CGFloat(benignPct) / 100, height: 10)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("\(benignPct)% ups")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.earthAccent)
                    Spacer()
                    Text("\(100 - benignPct)% downs")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 20) {
                    weeklyStatPill(value: "\(summary.totalEvents)", label: "events")
                    weeklyStatPill(value: "\(summary.daysActive)", label: "active days")
                    weeklyStatPill(value: "\(journalCount)", label: "entries written")
                }
                .padding(.top, 4)

                Text(weeklyMessage(for: summary.worrisomeRate))
                    .font(.caption)
                    .foregroundStyle(Color.earthStone)
                    .padding(.top, 2)
            }
        }
        .padding()
        .background(Color.earthCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func weeklyMessage(for worrisomeRate: Double) -> String {
        if worrisomeRate > 0.6 {
            return "This has been a heavier week — and that's okay. You're still here, still paying attention to yourself. That matters more than you think."
        } else if worrisomeRate > 0.35 {
            return "A mixed week with ups and downs. That's life being life. You're navigating it well."
        } else {
            return "A solid week. You're in a good rhythm — keep taking care of yourself."
        }
    }

    private func weeklyStatPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(Color.earthBark)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.earthStone)
        }
        .frame(maxWidth: .infinity)
    }

    private var journalEntriesThisWeek: Int {
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return journalEntries.filter { $0.createdAt >= oneWeekAgo }.count
    }

    // MARK: - Your Days (Tabbed: Daily / Weekly / Monthly)

    private var yourDaysCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your Days")
                    .font(.headline)
                    .foregroundStyle(Color.earthBark)
                Spacer()
            }

            // Segmented picker
            Picker("Range", selection: $reflectionRange) {
                ForEach(ReflectionRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            switch reflectionRange {
            case .daily:
                dailyReflectionList
            case .weekly:
                weeklyReflectionList
            case .monthly:
                monthlyReflectionList
            }
        }
        .padding()
        .background(Color.earthCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.2), value: reflectionRange)
    }

    // MARK: Daily Reflection

    private var dailyReflectionList: some View {
        Group {
            if viewModel.dailySummaries.isEmpty {
                emptyReflectionMessage
            } else {
                let recentDays = Array(viewModel.dailySummaries.suffix(7).reversed())
                ForEach(Array(recentDays.enumerated()), id: \.element.id) { index, day in
                    dailyRow(day)
                    if index < recentDays.count - 1 {
                        Divider().overlay(Color.earthSage.opacity(0.2))
                    }
                }
            }
        }
    }

    private func dailyRow(_ day: DailySummary) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        let isYesterday = Calendar.current.isDateInYesterday(day.date)

        let dateLabel: String = {
            if isToday { return "Today" }
            if isYesterday { return "Yesterday" }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: day.date)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: day.feeling.icon)
                    .font(.title3)
                    .foregroundStyle(day.feeling.color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(dateLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.earthBark)
                        if isToday {
                            Text("now")
                                .font(.system(size: 9).weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.earthAccent)
                                .clipShape(Capsule())
                        }
                    }
                    Text(day.label)
                        .font(.caption)
                        .foregroundStyle(day.feeling.color)
                }

                Spacer()

                miniRatioBar(benign: day.benignCount, worrisome: day.worrisomeCount, total: day.totalEvents)

                Text("\(day.totalEvents)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.earthStone)
            }

            Text(day.message)
                .font(.caption)
                .foregroundStyle(Color.earthStone)
                .padding(.leading, 38)

            if isToday && !topCardShowsActions && (day.feeling == .tough || day.feeling == .hard) {
                actionButtons
                    .padding(.leading, 38)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Weekly Reflection

    private var weeklyReflectionList: some View {
        Group {
            if viewModel.weeklySummaries.isEmpty {
                emptyReflectionMessage
            } else {
                let recentWeeks = Array(viewModel.weeklySummaries.suffix(6).reversed())
                ForEach(Array(recentWeeks.enumerated()), id: \.element.id) { index, week in
                    weeklyRow(week)
                    if index < recentWeeks.count - 1 {
                        Divider().overlay(Color.earthSage.opacity(0.2))
                    }
                }
            }
        }
    }

    private func weeklyRow(_ week: WeekSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: week.feeling.icon)
                    .font(.title3)
                    .foregroundStyle(week.feeling.color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(week.dateRangeLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.earthBark)
                        if week.isCurrentWeek {
                            Text("this week")
                                .font(.system(size: 9).weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.earthAccent)
                                .clipShape(Capsule())
                        }
                    }
                    Text(week.label)
                        .font(.caption)
                        .foregroundStyle(week.feeling.color)
                }

                Spacer()

                miniRatioBar(benign: week.benignCount, worrisome: week.worrisomeCount, total: week.totalEvents)

                Text("\(week.totalEvents)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.earthStone)
            }

            Text(week.message)
                .font(.caption)
                .foregroundStyle(Color.earthStone)
                .padding(.leading, 38)

            // Stats row for weeks
            HStack(spacing: 16) {
                miniStat(value: "\(week.daysActive)", label: "days active")
                miniStat(value: "\(week.benignCount)", label: "ups")
                miniStat(value: "\(week.worrisomeCount)", label: "downs")
            }
            .padding(.leading, 38)
            .padding(.top, 2)

            if week.isCurrentWeek && !topCardShowsActions && (week.feeling == .tough || week.feeling == .hard) {
                actionButtons
                    .padding(.leading, 38)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Monthly Reflection

    private var monthlyReflectionList: some View {
        Group {
            if viewModel.monthlySummaries.isEmpty {
                emptyReflectionMessage
            } else {
                let recentMonths = Array(viewModel.monthlySummaries.suffix(4).reversed())
                ForEach(Array(recentMonths.enumerated()), id: \.element.id) { index, month in
                    monthlyRow(month)
                    if index < recentMonths.count - 1 {
                        Divider().overlay(Color.earthSage.opacity(0.2))
                    }
                }
            }
        }
    }

    private func monthlyRow(_ month: MonthSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: month.feeling.icon)
                    .font(.title3)
                    .foregroundStyle(month.feeling.color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(month.monthLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.earthBark)
                        if month.isCurrentMonth {
                            Text("this month")
                                .font(.system(size: 9).weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.earthAccent)
                                .clipShape(Capsule())
                        }
                    }
                    Text(month.label)
                        .font(.caption)
                        .foregroundStyle(month.feeling.color)
                }

                Spacer()

                miniRatioBar(benign: month.benignCount, worrisome: month.worrisomeCount, total: month.totalEvents)

                Text("\(month.totalEvents)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.earthStone)
            }

            Text(month.message)
                .font(.caption)
                .foregroundStyle(Color.earthStone)
                .padding(.leading, 38)

            // Consistency + stats
            Text(month.consistencyMessage)
                .font(.caption)
                .foregroundStyle(Color.earthSage)
                .padding(.leading, 38)
                .padding(.top, 1)

            HStack(spacing: 16) {
                miniStat(value: "\(month.daysActive)", label: "days active")
                miniStat(value: "\(month.benignCount)", label: "ups")
                miniStat(value: "\(month.worrisomeCount)", label: "downs")
            }
            .padding(.leading, 38)
            .padding(.top, 2)

            if month.isCurrentMonth && !topCardShowsActions && (month.feeling == .tough || month.feeling == .hard) {
                actionButtons
                    .padding(.leading, 38)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared Reflection Helpers

    private var emptyReflectionMessage: some View {
        Text("Once you have some data, your reflections will appear here with their own story.")
            .font(.subheadline)
            .foregroundStyle(Color.earthStone)
            .padding(.vertical, 8)
    }

    private func miniRatioBar(benign: Int, worrisome: Int, total: Int) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.earthAccent)
                .frame(width: max(2, CGFloat(benign) / CGFloat(max(total, 1)) * 40), height: 8)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange.opacity(0.6))
                .frame(width: max(2, CGFloat(worrisome) / CGFloat(max(total, 1)) * 40), height: 8)
        }
    }

    private func miniStat(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(Color.earthBark)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(Color.earthStone)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                showingNewEntry = true
            } label: {
                Text("Write about it")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.earthAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.earthAccent.opacity(0.1))
                    .clipShape(Capsule())
            }

            Button {
                showingBreathingExercise = true
            } label: {
                Text("Breathe")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.earthAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.earthAccent.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Unable to load data")
                .font(.headline)
                .foregroundStyle(Color.earthBark)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.earthStone)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.fetchPredictions() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.earthAccent)
        }
        .padding(40)
    }
}

// MARK: - Breathing Exercise View

struct BreathingExerciseView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: BreathPhase = .ready
    @State private var circleScale: CGFloat = 0.4
    @State private var cycleCount = 0

    private let totalCycles = 4

    enum BreathPhase: String {
        case ready = "Tap to begin"
        case inhale = "Breathe in…"
        case hold = "Hold…"
        case exhale = "Breathe out…"
        case done = "Well done"
    }

    var body: some View {
        VStack(spacing: 32) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.earthStone)
                }
            }
            .padding(.horizontal)

            Spacer()

            ZStack {
                Circle()
                    .fill(Color.earthAccent.opacity(0.08))
                    .frame(width: 240, height: 240)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.earthAccent.opacity(0.6), Color.earthAccent.opacity(0.15)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)
                    .scaleEffect(circleScale)

                VStack(spacing: 6) {
                    Text(phase.rawValue)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.earthBark)

                    if phase != .ready && phase != .done {
                        Text("Cycle \(cycleCount + 1) of \(totalCycles)")
                            .font(.caption)
                            .foregroundStyle(Color.earthStone)
                    }
                }
            }
            .onTapGesture {
                if phase == .ready || phase == .done {
                    startExercise()
                }
            }

            if phase == .done {
                Text("Take a moment to notice how you feel.")
                    .font(.subheadline)
                    .foregroundStyle(Color.earthSage)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .background(Color.earthSand)
    }

    private func startExercise() {
        cycleCount = 0
        runCycle()
    }

    private func runCycle() {
        guard cycleCount < totalCycles else {
            withAnimation(.easeInOut(duration: 0.5)) {
                phase = .done
                circleScale = 0.5
            }
            return
        }

        phase = .inhale
        withAnimation(.easeInOut(duration: 4)) {
            circleScale = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            phase = .hold
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                phase = .exhale
                withAnimation(.easeInOut(duration: 4)) {
                    circleScale = 0.4
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    cycleCount += 1
                    runCycle()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MentalHealthDashboardView()
        .modelContainer(for: [JournalEntry.self])
}
