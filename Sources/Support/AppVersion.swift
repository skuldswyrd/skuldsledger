import Foundation

/// Ledger edition — bump on every shipped upgrade round so the header always
/// says which build is on screen (and buddies can report "I'm on v1.2").
enum AppVersion {
    static let string = "1.5.2"
}
