import CodePulseIntegration
import SwiftUI

struct DeveloperToolContextList: View {
    let contexts: [DeveloperToolSessionContext]
    let showsEventCounts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(contexts) { context in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: context.tool.systemImage)
                        .foregroundStyle(.secondary)
                    Text(context.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)

                if showsEventCounts {
                    Text(eventCountDescription(for: context))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private func eventCountDescription(for context: DeveloperToolSessionContext) -> String {
        let noun = context.eventCount == 1 ? "activity event" : "activity events"
        return "\(context.eventCount) \(noun)"
    }
}
