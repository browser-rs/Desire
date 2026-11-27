import SwiftUI

struct FormAutofillSettingsView: View {
    @ObservedObject var store: FormAutofillStore

    var body: some View {
        SettingsContainer {
            // 多档案（v0.8.80）：命名当前档案、存入库、从库中载入/删除。
            SettingsSection(
                title: "Profiles",
                subtitle: "Keep more than one address and pick which one to fill from the site controls or the bridge.",
                icon: "person.2"
            ) {
                VStack(spacing: 0) {
                    SettingsRow("Profile Name", subtitle: "Shown in the fill menu (empty = full name).", systemImage: "tag") {
                        SettingsTextField(placeholder: "Home", text: $store.profile.label, width: 160)
                    }
                    SettingsRowDivider()
                    HStack {
                        Button("Save Current Profile") { store.saveCurrentToLibrary() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("New Profile") { store.newProfile() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    ForEach(store.savedProfiles) { saved in
                        SettingsRowDivider()
                        SettingsRow(saved.displayName, subtitle: saved.summary, systemImage: "person.crop.rectangle") {
                            HStack(spacing: 8) {
                                Button("Load") { store.load(saved.id) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                Button {
                                    store.delete(saved.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            SettingsSection(
                title: "Name",
                subtitle: "Used to fill your first and last name into forms.",
                icon: "person.text.rectangle"
            ) {
                VStack(spacing: 0) {
                    SettingsRow("First Name", subtitle: nil, systemImage: "person.crop.circle") {
                        SettingsTextField(placeholder: "First name", text: $store.profile.givenName, width: 220)
                    }
                    SettingsRowDivider()
                    SettingsRow("Last Name", subtitle: nil, systemImage: "person.crop.circle.fill") {
                        SettingsTextField(placeholder: "Last name", text: $store.profile.familyName, width: 220)
                    }
                }
            }

            SettingsSection(
                title: "Contact",
                subtitle: "Auto-fill email and phone number on checkout and sign-up forms.",
                icon: "envelope"
            ) {
                VStack(spacing: 0) {
                    SettingsRow("Email", subtitle: nil, systemImage: "envelope") {
                        SettingsTextField(placeholder: "name@example.com", text: $store.profile.email, width: 260)
                    }
                    SettingsRowDivider()
                    SettingsRow("Phone", subtitle: nil, systemImage: "phone") {
                        SettingsTextField(placeholder: "+1 555 000 0000", text: $store.profile.phone, width: 200)
                    }
                }
            }

            SettingsSection(
                title: "Organization",
                subtitle: "Company or organization name for billing forms.",
                icon: "briefcase"
            ) {
                SettingsRow("Company / Organization", subtitle: nil, systemImage: "briefcase") {
                    SettingsTextField(placeholder: "Acme Co.", text: $store.profile.organization, width: 260)
                }
            }

            SettingsSection(
                title: "Address",
                subtitle: "Used to fill shipping and billing forms.",
                icon: "mappin.and.ellipse"
            ) {
                VStack(spacing: 0) {
                    addressField("Street", placeholder: "1 Apple Park Way", text: $store.profile.streetAddress, icon: "mappin")
                    SettingsRowDivider()
                    twoColumn(
                        left: ("City", "building.2", "Cupertino", $store.profile.city),
                        right: ("State / Region", "map", "California", $store.profile.state)
                    )
                    SettingsRowDivider()
                    twoColumn(
                        left: ("ZIP / Postal", "number", "95014", $store.profile.zipCode),
                        right: ("Country", "flag", "United States", $store.profile.country)
                    )
                }
            }
        }
    }

    // MARK: - Building blocks

    private func addressField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        icon: String
    ) -> some View {
        SettingsRow(title, subtitle: nil, systemImage: icon) {
            SettingsTextField(placeholder: placeholder, text: text, width: 260)
        }
    }

    private func twoColumn(
        left: (String, String, String, Binding<String>),
        right: (String, String, String, Binding<String>)
    ) -> some View {
        HStack(spacing: 0) {
            SettingsRow(left.0, subtitle: nil, systemImage: left.1) {
                SettingsTextField(placeholder: left.2, text: left.3, width: 140)
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 0.5)
            SettingsRow(right.0, subtitle: nil, systemImage: right.1) {
                SettingsTextField(placeholder: right.2, text: right.3, width: 140)
            }
        }
    }
}
