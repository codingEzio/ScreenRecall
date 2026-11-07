import RecallCore
import SwiftUI

struct ReviewControls: View {
  @Bindable var model: RecallModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 8) {
        Picker(model.text("速度"), selection: $model.playbackRate) {
          ForEach(PlaybackRate.allCases) { rate in
            Text(model.text(rate.rawValue)).tag(rate)
          }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        .help(model.text("回看速度"))
        .accessibilityLabel(model.text("回看速度"))
        .accessibilityIdentifier("playback.speed")
        .disabled(model.current == nil)
        Toggle(isOn: $model.playbackLoop) {
          Label(model.text("循環"), systemImage: "repeat")
        }
        .labelsHidden().toggleStyle(.button)
        .help(model.text("循環回看"))
        .accessibilityLabel(model.text("循環回看"))
        .accessibilityIdentifier("playback.loop")
        .disabled(model.current == nil)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 14) {
        Button {
          model.navigateBySwipe(-1)
        } label: {
          Image(systemName: "backward.frame.fill").frame(width: 24, height: 28)
        }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .disabled(!model.canNavigate(-1))
        .accessibilityLabel(model.text("上一張"))
        .help(model.text("上一張"))
        .accessibilityIdentifier("frame.previous")

        Button(action: model.togglePlayback) {
          Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 24, height: 28)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .help(model.text(model.isPlaying ? "暫停回看" : "播放回看"))
        .accessibilityLabel(model.text(model.isPlaying ? "暫停回看" : "播放回看"))
        .accessibilityIdentifier("playback.toggle")
        .disabled(model.captures.count < 2)

        Button {
          model.navigateBySwipe(1)
        } label: {
          Image(systemName: "forward.frame.fill").frame(width: 24, height: 28)
        }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .disabled(!model.canNavigate(1))
        .accessibilityLabel(model.text("下一張"))
        .help(model.text("下一張"))
        .accessibilityIdentifier("frame.next")

        Text(
          Date(timeIntervalSince1970: model.playheadTime).formatted(model.clockStyle(seconds: true))
        )
        .recallFont(.callout, weight: .medium, technical: true)
        .monospacedDigit().frame(minWidth: 88, alignment: .leading)
        .accessibilityIdentifier("frame.time")
      }

      HStack(spacing: 12) {
        Button(action: model.toggleMark) {
          Image(systemName: model.annotationMarked ? "bookmark.fill" : "bookmark")
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(model.annotationMarked ? Color.accentColor : .primary)
        }
        .help(model.text(model.annotationMarked ? "取消標記" : "標記此畫面"))
        .accessibilityLabel(model.text(model.annotationMarked ? "取消標記" : "標記"))
        .accessibilityIdentifier("annotation.mark")
        .disabled(model.current == nil || model.annotationBusy)

        Button(action: model.openAnnotationEditor) {
          Image(systemName: model.annotationDraft.isEmpty ? "note" : "note.text")
        }
        .help(model.text("編輯筆記"))
        .accessibilityLabel(model.text("筆記"))
        .accessibilityIdentifier("annotation.edit")
        .popover(isPresented: $model.showAnnotationEditor, arrowEdge: .bottom) {
          AnnotationEditor(model: model)
        }
        .disabled(model.current == nil || model.annotationBusy)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .buttonStyle(.borderless)
    .controlSize(.regular)
    .symbolEffectsRemoved(reduceMotion)
  }
}

private struct AnnotationEditor: View {
  @Bindable var model: RecallModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.text("標記與筆記")).recallFont(.headline)
      Toggle(model.text("保留這一格"), isOn: $model.annotationMarked)
        .accessibilityIdentifier("annotation.mark.toggle")
      TextEditor(text: $model.annotationDraft)
        .recallFont(.body)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .frame(height: 110)
        .accessibilityIdentifier("annotation.note")
      HStack {
        Spacer()
        Button(model.text("取消"), action: model.cancelAnnotationEdit)
        Button(model.text("儲存"), action: model.saveAnnotation)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("annotation.save")
      }
    }
    .padding(16)
    .frame(width: 340)
  }
}
