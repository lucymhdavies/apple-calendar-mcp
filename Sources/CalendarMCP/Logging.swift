import Foundation

enum Log {
    static func message(_ text: String) {
        FileHandle.standardError.write(Data("[calendar-api] \(text)\n".utf8))
    }
}