import Foundation

enum Log {
    static func message(_ text: String) {
        FileHandle.standardError.write(Data("[outlook-calendar] \(text)\n".utf8))
    }
}