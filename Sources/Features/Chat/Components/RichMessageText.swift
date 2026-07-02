import SwiftUI
import UIKit

// Renders message text with system data detection — tappable links, phone
// numbers, addresses, and dates/times (Add to Calendar / Get Directions /
// Call), the same interactions UITextView gives Messages for free.
struct RichMessageText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: UIColor
    /// Render "@all" mentions with an accent tint (group bubbles; CALLS.md §8.4).
    var highlightMentions: Bool = false
    var mentionColor: UIColor = .systemRed
    var onLongPress: () -> Void = {}

    /// Same detection the server's push gate uses: /(^|\s)@all\b/i.
    static let mentionsAllRegex = try? NSRegularExpression(
        pattern: "(^|\\s)(@all)\\b", options: [.caseInsensitive]
    )

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false // avoids UITextView's own selection long-press fighting ours
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        view.delegate = context.coordinator

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.3
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)

        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        if let highlighted = mentionAttributedText() {
            // Don't reassign font/textColor afterwards — that would flatten the
            // attribute runs back to a single style.
            if uiView.attributedText?.string != text {
                uiView.attributedText = highlighted
            }
        } else {
            if uiView.text != text { uiView.text = text }
            uiView.font = font
            uiView.textColor = textColor
        }
        uiView.tintColor = textColor
        uiView.linkTextAttributes = [
            .foregroundColor: textColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    /// Attributed body with "@all" runs tinted + bolded — nil when highlighting is
    /// off or the text has no mention (keeps the cheap plain-text path).
    private func mentionAttributedText() -> NSAttributedString? {
        guard highlightMentions,
              let regex = Self.mentionsAllRegex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        let boldFont = UIFont(
            descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor,
            size: font.pointSize
        )
        for match in matches {
            let mentionRange = match.range(at: 2)
            attributed.addAttributes([
                .foregroundColor: mentionColor,
                .font: boldFont,
            ], range: mentionRange)
        }
        return attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onLongPress: () -> Void = {}

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            onLongPress()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}
