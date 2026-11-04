import AVFoundation
import AppKit

// Extracts embedded album art for Now Playing (MPMediaItemPropertyArtwork).
// Works for local files and for remote tracks via the loopback HTTP proxy
// URL (Track.url), since AVURLAsset reads ID3 headers over ranged HTTP.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private var cache: [URL: NSImage?] = [:]
    private var inFlight: Set<URL> = []
    private var order: [URL] = []          // LRU eviction, cap ~64 images

    func image(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[url] { completion(cached); return }
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task { [weak self] in
            let img = await Self.loadArtwork(url)
            Task { @MainActor in
                guard let self else { return }
                self.cache[url] = img
                self.inFlight.remove(url)
                self.order.append(url)
                if self.order.count > 64 {
                    let evict = self.order.removeFirst()
                    self.cache.removeValue(forKey: evict)
                }
                completion(img)
            }
        }
    }

    private static func loadArtwork(_ url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let raw = try? await item.load(.value), let data = raw as? Data,
               let img = NSImage(data: data), img.size.width >= 64 {
                return img
            }
        }
        return nil
    }
}