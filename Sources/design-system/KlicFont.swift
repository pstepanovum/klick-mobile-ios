import SwiftUI

/// TikTok Sans type scale. Files registered via UIAppFonts in Info.plist.
enum KlicFont {
    static func display(_ size: CGFloat = 32) -> Font { .custom("TikTokSans-Black", size: size) }
    static func title(_ size: CGFloat = 22) -> Font { .custom("TikTokSans-Bold", size: size) }
    static func headline(_ size: CGFloat = 17) -> Font { .custom("TikTokSans-SemiBold", size: size) }
    static func body(_ size: CGFloat = 16) -> Font { .custom("TikTokSans-Regular", size: size) }
    static func medium(_ size: CGFloat = 16) -> Font { .custom("TikTokSans-Medium", size: size) }
    static func caption(_ size: CGFloat = 13) -> Font { .custom("TikTokSans-Light", size: size) }
    /// Bangers — a bold display face used for the brand tagline.
    static func banger(_ size: CGFloat = 34) -> Font { .custom("Bangers-Regular", size: size) }
}
