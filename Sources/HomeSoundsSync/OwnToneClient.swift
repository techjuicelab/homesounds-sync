import Foundation

/// Minimal HTTP client for the local OwnTone server (localhost:3689). Used to
/// list AirPlay outputs (HomePods) and choose which one receives the stream,
/// so the user can pick their HomePod by name from inside the app.
enum OwnToneClient {

    // 127.0.0.1 (not "localhost") to match OwnTone's loopback bind_address and to
    // avoid an IPv6/IPv4 resolution mismatch. OwnTone is configured to listen on
    // loopback only (see setup.sh), so this never leaves the machine.
    static let base = "http://127.0.0.1:3689"

    struct Output {
        let id: String
        let name: String
        let type: String
        let selected: Bool
        let volume: Int        // 0–100
    }

    /// Build `…/api/outputs/{id}` with the id percent-encoded as a path segment,
    /// so an unusual output id can never break or inject into the URL.
    private static func outputURL(id: String) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(base)/api/outputs/\(encoded)")
    }

    /// GET /api/outputs → AirPlay outputs only (HomePods / Apple TVs / etc.).
    static func airplayOutputs(_ completion: @escaping ([Output]) -> Void) {
        guard let url = URL(string: "\(base)/api/outputs") else { completion([]); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var result: [Output] = []
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["outputs"] as? [[String: Any]] {
                for o in arr {
                    guard let id = o["id"] as? String, let name = o["name"] as? String else { continue }
                    let type = o["type"] as? String ?? ""
                    guard type.hasPrefix("AirPlay") else { continue }
                    result.append(Output(id: id, name: name, type: type,
                                         selected: (o["selected"] as? Bool) ?? false,
                                         volume: (o["volume"] as? Int) ?? 50))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Set the HomePod (AirPlay output) volume, 0–100.
    static func setVolume(id: String, volume: Int) {
        guard let url = outputURL(id: id) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{\"volume\": \(max(0, min(100, volume)))}".data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Enable or disable one AirPlay output independently (multi-room: several
    /// outputs can be selected at once; AirPlay 2 keeps them sample-synced).
    static func setSelected(id: String, on: Bool) {
        guard let url = outputURL(id: id) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{\"selected\": \(on)}".data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
}
