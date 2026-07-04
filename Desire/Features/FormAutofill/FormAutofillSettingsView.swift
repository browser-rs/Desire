import SwiftUI

struct FormAutofillSettingsView: View {
    @ObservedObject var store: FormAutofillStore

    var body: some View {
        Form {
            Section("姓名") {
                TextField("名", text: $store.profile.givenName)
                TextField("姓", text: $store.profile.familyName)
            }
            Section("联系方式") {
                TextField("邮箱", text: $store.profile.email)
                TextField("电话", text: $store.profile.phone)
            }
            Section("公司") {
                TextField("公司/组织", text: $store.profile.organization)
            }
            Section("地址") {
                TextField("街道地址", text: $store.profile.streetAddress)
                TextField("城市", text: $store.profile.city)
                TextField("省/州", text: $store.profile.state)
                TextField("邮编", text: $store.profile.zipCode)
                TextField("国家", text: $store.profile.country)
            }
        }
        .padding()
    }
}
