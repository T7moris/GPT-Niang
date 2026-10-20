import Foundation

/// The small thought dot stays attached to the character as either size changes.
/// Equal scales reproduce the original 378 × 378 layout, including its padding.
public struct CompanionLayout {
    public let characterScale: Double
    public let bubbleScale: Double
    public let character: CGRect
    public let bubble: CGRect
    public let size: CGSize
    public let padding: Double
    public let musicAccessories: Bool

    public static func preferenceScale(_ value: Double) -> Double {
        value.isFinite ? min(2.5, max(0.6, value)) : 1
    }

    public init(characterScale: Double, bubbleScale: Double, musicAccessories: Bool = false) {
        self.characterScale = characterScale
        self.bubbleScale = bubbleScale
        self.musicAccessories = musicAccessories
        let c = characterScale, b = bubbleScale
        let girl = CGRect(x: 0, y: 0, width: 208 * c, height: 208 * c)
        let cloud = CGRect(x: 8.5 * c - 150.5 * b, y: 78 * c - 220 * b,
                           width: 350 * b, height: 239 * b)
        let accessories = CGRect(x: -80*c,y: 0,width: 368*c,height: 224*c)
        let union = girl.union(cloud).union(musicAccessories ? accessories : girl)
        padding = 14 * max(c, b)
        character = girl.offsetBy(dx: -union.minX, dy: -union.minY)
        bubble = cloud.offsetBy(dx: -union.minX, dy: -union.minY)
        size = CGSize(width: union.width + 2 * padding, height: union.height + 2 * padding)
    }

    public func fitted(in area: CGSize) -> CompanionLayout {
        let factor = max(0.001, min(1, area.width / size.width, area.height / size.height))
        return CompanionLayout(characterScale: characterScale * factor, bubbleScale: bubbleScale * factor, musicAccessories: musicAccessories)
    }
}
