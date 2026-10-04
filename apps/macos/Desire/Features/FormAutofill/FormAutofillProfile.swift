import Foundation

struct FormAutofillProfile: Codable {
    var givenName: String
    var familyName: String
    var email: String
    var phone: String
    var organization: String
    var streetAddress: String
    var city: String
    var state: String
    var zipCode: String
    var country: String
}
