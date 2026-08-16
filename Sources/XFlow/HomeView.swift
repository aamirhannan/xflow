import AppKit
import SwiftUI
import XFlowCore

/// Everything the app has ever heard, with the three numbers that summarise it.
struct HomeView: View {
    let store: HistoryStore

    @State private var records: [DictationRecord] = []
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var showingOriginal = false

    private var filtered: [DictationRecord] { HistoryQuery.matching(query, in: records) }
    private var groups: [DayGroup] { HistoryQuery.groupedByDay(filtered, today: Date()) }
    private var selected: DictationRecord? { records.first { $0.id == selectedID } }

    var body: some View {
        HSplitView {
            listColumn.frame(minWidth: 340)
            detailColumn.frame(minWidth: 320)
        }
        .onAppear(perform: reload)
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            statsRow.padding(20)
            Divider()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()

            if records.isEmpty {
                message("Hold fn anywhere to dictate.\nYour history appears here.")
            } else if filtered.isEmpty {
                message("No dictations match that search.")
            } else {
                List(selection: $selectedID) {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.records) { record in
                                row(record).tag(record.id)
                            }
                        }
                    }
                }
            }

            if !Settings.historyEnabled { pausedNotice }
        }
    }

    private var statsRow: some View {
        HStack(alignment: .top, spacing: 32) {
            stat(Statistics.totalWords(records).formatted(), "words")
            stat(
                Statistics.formattedSpeechTime(seconds: Statistics.totalSpeechSeconds(records)),
                "spoken"
            )
            stat("\(Statistics.streak(records, today: Date()))", "day streak")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(record.timestamp, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(record.cleanedText).lineLimit(1)
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pausedNotice: some View {
        HStack {
            Text("New dictations are not being saved. Turn Save history back on in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
    }

    // MARK: - Detail

    @ViewBuilder private var detailColumn: some View {
        if let record = selected {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    record.timestamp,
                    format: .dateTime.weekday().day().month().hour().minute()
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ScrollView {
                    Text(showingOriginal ? record.rawText : record.cleanedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The reason both transcripts are stored: when cleanup romanizes
                // something wrongly or drops a phrase, this is the only route back
                // to what was actually said.
                Toggle("Show original", isOn: $showingOriginal)

                HStack {
                    Button("Copy") { copy(record) }
                    Button("Delete", role: .destructive) { delete(record) }
                    Spacer()
                    Text("\(record.wordCount) words · \(Int(record.durationSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        } else {
            message("Select a dictation to read it.")
        }
    }

    private func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            showingOriginal ? record.rawText : record.cleanedText, forType: .string
        )
    }

    private func delete(_ record: DictationRecord) {
        store.delete(id: record.id)
        selectedID = nil
        reload()
    }

    /// ponytail: reads the whole file on appear and after a delete, with no
    /// change notifications — a dictation made while this window is open will not
    /// appear until it is reopened. Add an observer when that matters.
    private func reload() {
        records = store.all()
    }
}
