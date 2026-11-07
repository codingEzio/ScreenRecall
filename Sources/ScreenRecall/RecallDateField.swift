import AppKit
import SwiftUI

/// Native date editing without the oversized toolbar stepper. Day arrows remain separate.
struct RecallDateField: NSViewRepresentable {
  @Binding var selection: Date
  let locale: Locale
  let enabled: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textField
    picker.datePickerElements = [.yearMonthDay]
    picker.controlSize = .small
    picker.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    picker.isBordered = false
    picker.drawsBackground = false
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.changed(_:))
    picker.setAccessibilityIdentifier("day.picker")
    return picker
  }

  func updateNSView(_ picker: NSDatePicker, context: Context) {
    context.coordinator.parent = self
    picker.locale = locale
    picker.dateValue = selection
    picker.isEnabled = enabled
  }

  @MainActor final class Coordinator: NSObject {
    var parent: RecallDateField
    init(_ parent: RecallDateField) { self.parent = parent }
    @objc func changed(_ sender: NSDatePicker) { parent.selection = sender.dateValue }
  }
}
