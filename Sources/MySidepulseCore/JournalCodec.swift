import Foundation

public enum JournalCodec {
    static let isoMs: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func date(from string: String) -> Date? {
        isoMs.date(from: string) ?? iso.date(from: string)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoMs.string(from: date))
        }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = JournalCodec.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath,
                    debugDescription: "unparseable date: \(s)"))
            }
            return date
        }
        return d
    }()

    public static func encodeLine(_ e: JournalEvent) throws -> Data {
        try encoder.encode(e)
    }
    public static func decodeLine(_ data: Data) -> JournalEvent? {
        try? decoder.decode(JournalEvent.self, from: data)
    }
}
