import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, body: String)] = [
        (
            "What we collect",
            "Account data — username, display name, and a hashed password. We never store passwords in plain text.\n\nMessages & calls — content is encrypted in transit. We do not read your conversations.\n\nDevice & usage data — anonymous crash reports and usage statistics to improve the app."
        ),
        (
            "How we use it",
            "Your data is used exclusively to operate and improve Klic. We do not sell or share personal information with advertisers or third parties."
        ),
        (
            "Data retention",
            "You can delete your account at any time. All associated data is permanently removed within 30 days of deletion."
        ),
        (
            "Security",
            "We use industry-standard encryption to protect your data in transit and at rest."
        ),
        (
            "Contact",
            "Questions? Reach us at privacy@klic.app"
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(KlicFont.headline())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text(section.body)
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("Effective date: June 28, 2026")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                        .padding(.top, 4)
                }
                .padding(24)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Privacy Policy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(KlicColor.primary)
                }
            }
        }
    }
}
