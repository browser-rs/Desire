import SwiftUI

/// 支付卡（v0.8.82）：设置页里的最小保险库 UI。卡号只进 Keychain，
/// CVV 没有输入框——这是设计边界，不是遗漏。
struct PaymentCardsSection: View {
    @ObservedObject private var store = PaymentCardStore.shared
    @State private var showAdd = false
    @State private var editingCard: PaymentCard?

    var body: some View {
        SettingsSection(
            title: "Payment Cards",
            subtitle: "Stored on this Mac only. The card number lives in the keychain; the CVV is never stored or requested.",
            icon: "creditcard"
        ) {
            VStack(spacing: 0) {
                if store.cards.isEmpty {
                    Text("No cards saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(store.cards) { card in
                    SettingsRow(card.displayName,
                                subtitle: card.summary,
                                systemImage: "creditcard.fill") {
                        HStack(spacing: 8) {
                            Button {
                                editingCard = card
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Edit card"))
                            .help("Edit card")
                            Button {
                                store.delete(card)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Delete card"))
                            .help("Delete card")
                        }
                    }
                    SettingsRowDivider()
                }
                HStack {
                    Button("Add Card") { showAdd = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showAdd) {
            PaymentCardEditorSheet()
        }
        .sheet(item: $editingCard) { card in
            PaymentCardEditorSheet(card: card)
        }
    }
}

private struct PaymentCardEditorSheet: View {
    @ObservedObject private var store = PaymentCardStore.shared
    @Environment(\.dismiss) private var dismiss
    var card: PaymentCard?
    @State private var label: String
    @State private var holder: String
    @State private var number = ""
    @State private var month: Int
    @State private var year: Int
    @State private var errorText: String?

    init(card: PaymentCard? = nil) {
        self.card = card
        let now = Calendar.current.component(.year, from: Date())
        _label = State(initialValue: card?.label ?? "")
        _holder = State(initialValue: card?.cardholder ?? "")
        _month = State(initialValue: card?.expiryMonth ?? 12)
        _year = State(initialValue: card?.expiryYear ?? now + 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card == nil ? "Add Payment Card" : "Edit Payment Card")
                .font(.system(size: 14, weight: .semibold))
            Text(card == nil
                 ? "The number is saved in the keychain. CVV is never stored — you will enter it on the site if asked."
                 : "Leave the card number blank to keep the current number. CVV is never stored.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "Label (optional)"))
            TextField("Cardholder name", text: $holder)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "Cardholder name"))
            TextField(card == nil ? "Card number" : "Card number (leave blank to keep)",
                      text: $number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel(String(localized: "Card number"))
            HStack(spacing: 8) {
                Stepper(value: $month, in: 1...12) {
                    Text(String(format: String(localized: "Expiry month: %02d"), month))
                }
                Stepper(value: $year,
                        in: Calendar.current.component(.year, from: Date())...(Calendar.current.component(.year, from: Date()) + 20)) {
                    Text(verbatim: "\(year)")
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    do {
                        if let card {
                            _ = try store.update(card, label: label, cardholder: holder,
                                                 number: number.isEmpty ? nil : number,
                                                 expiryMonth: month, expiryYear: year)
                        } else {
                            _ = try store.add(label: label, cardholder: holder,
                                              number: number, expiryMonth: month,
                                              expiryYear: year)
                        }
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(holder.isEmpty || (card == nil && number.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
