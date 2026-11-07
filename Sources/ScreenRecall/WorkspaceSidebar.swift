import RecallCore
import SwiftUI

struct WorkspaceSidebar: View {
  @Bindable var model: RecallModel
  @Environment(\.recallVisualTheme) private var visualTheme
  @Environment(\.colorScheme) private var colorScheme
  private var palette: RecallPalette {
    RecallPalette(theme: visualTheme, dark: colorScheme == .dark)
  }
  @State private var selectedDayID: String?

  private var hasQuery: Bool {
    !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    List(selection: $selectedDayID) {
      if hasQuery {
        searchSection
      } else {
        if !model.annotations.isEmpty || model.annotationsBusy || model.annotationFilter != .all {
          reviewSection
        }
        daySection
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("workspace.sidebar")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        Divider()
        if model.recordedDisplayIDs.count > 1 {
          displayPicker
            .padding(.horizontal, 12).padding(.top, 10)
        }
        Label(model.menuBarStatusText, systemImage: model.menuBarSymbol)
          .recallFont(.caption)
          .foregroundStyle(model.isRecording ? palette.accent : palette.secondary)
          .lineLimit(2)
          .padding(.horizontal, 16).padding(.vertical, 12)
          .accessibilityIdentifier("sidebar.recording.status")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        visualTheme == .monochrome ? palette.canvas : Color(nsColor: .windowBackgroundColor))
    }
    .onAppear { selectedDayID = model.selectedDay?.id }
    .onChange(of: model.selectedDay?.id) { _, id in
      guard selectedDayID != id else { return }
      selectedDayID = id
    }
    .onChange(of: model.annotationFilter) { model.refreshAnnotations() }
    .onChange(of: selectedDayID) { _, id in
      guard let id, id != model.selectedDay?.id,
        let day = model.days.first(where: { $0.id == id })
      else { return }
      model.selectDay(day)
    }
  }

  @ViewBuilder private var reviewSection: some View {
    Section {
      if model.annotationsBusy {
        ProgressView(model.text("載入收藏清單…"))
      } else if model.annotations.isEmpty {
        Text(model.text("還沒有標記或筆記")).foregroundStyle(.secondary)
      } else {
        ForEach(model.annotations) { result in
          Button {
            model.chooseAnnotation(result)
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(
                  result.capture.date,
                  format: .dateTime.year().month().day().hour().minute())
                Text(
                  result.note.isEmpty
                    ? model.displayName(result.capture.displayID ?? "legacy") : result.note
                )
                .recallFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              }
            } icon: {
              if result.marked {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
              } else {
                Image(systemName: "note.text").foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sidebar.annotation.\(result.id)")
        }
      }
    } header: {
      HStack(spacing: 4) {
        Text(model.text("收藏"))
        Spacer()
        Picker(model.text("標記篩選"), selection: $model.annotationFilter) {
          ForEach(AnnotationFilter.allCases) { filter in
            Text(model.text(filter.localizationKey)).tag(filter)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel(model.text("標記篩選"))
        .accessibilityIdentifier("sidebar.annotation.filter")
      }
    }
  }

  private struct MonthSection: Identifiable {
    let id: String
    let date: Date
    var days: [CaptureDay]
  }

  private var months: [MonthSection] {
    var groups: [MonthSection] = []
    for day in model.days.reversed() {
      let id = "month:" + String(day.id.prefix(7))
      if groups.last?.id == id {
        groups[groups.count - 1].days.append(day)
      } else {
        groups.append(MonthSection(id: id, date: day.date, days: [day]))
      }
    }
    return groups
  }

  @ViewBuilder private var daySection: some View {
    if model.days.isEmpty {
      Section(model.text("日期")) {
        Text(model.text("沒有可顯示的日期")).foregroundStyle(.secondary)
      }
    } else {
      ForEach(months) { month in
        Section {
          ForEach(month.days) { day in
            let selected = day.id == selectedDayID
            HStack(spacing: 10) {
              Image(systemName: "calendar")
                .foregroundStyle(selected ? Color.white : palette.secondary)
                .imageScale(.medium)
              Text(day.date, format: .dateTime.month(.abbreviated).day())
                .foregroundStyle(selected ? Color.white : palette.primary)
              Spacer(minLength: 8)
              Text(day.date, format: .dateTime.weekday(.abbreviated))
                .recallFont(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : palette.secondary)
            }
            .padding(.vertical, 3)
            .tag(day.id)
            .accessibilityIdentifier(
              "sidebar.day.\(day.id.replacingOccurrences(of: "/", with: "-"))")
          }
        } header: {
          Text(month.date, format: .dateTime.year().month(.wide))
        }
      }
    }
  }

  @ViewBuilder private var searchSection: some View {
    Section(model.text("搜尋結果")) {
      if model.searchBusy {
        ProgressView(model.text("搜尋中…"))
      } else if model.catalogBusy && model.searchResults.isEmpty {
        ProgressView(model.text("正在建立本機索引…"))
      } else if model.searchResults.isEmpty {
        Text(model.text("沒有符合的截圖")).foregroundStyle(.secondary)
      } else {
        ForEach(model.searchResults) { result in
          Button {
            model.chooseSearchResult(result)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(
                result.capture.date,
                format: .dateTime.year().month().day().hour().minute().second())
              Text(model.displayName(result.capture.displayID ?? "legacy"))
                .recallFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sidebar.search.\(result.id)")
        }
      }
    }
  }

  private var displayPicker: some View {
    HStack(spacing: 8) {
      Image(systemName: "rectangle.on.rectangle")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Picker(
        model.text("螢幕"),
        selection: Binding(get: { model.monitorFilter }, set: model.filterDisplay)
      ) {
        Text(model.text("全部螢幕")).tag(String?.none)
        ForEach(model.recordedDisplayIDs, id: \.self) { id in
          Text(model.displayName(id)).tag(Optional(id))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityLabel(model.text("螢幕"))
      .accessibilityIdentifier("sidebar.screen.filter")
    }
  }
}
