import SwiftUI

struct GitHubContextView: View {
    let context: GitHubSessionContext
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text("GitHub")
                .font(compact ? .subheadline.weight(.semibold) : .headline)

            repositoryLink

            if let pullRequest = context.pullRequest {
                pullRequestLink(pullRequest)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var repositoryLink: some View {
        if let url = context.repositoryWebURL {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text(context.repositoryNameWithOwner)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("GitHub repository \(context.repositoryNameWithOwner)")
            .accessibilityHint("Opens the GitHub repository in the default browser")
        } else {
            Label(context.repositoryNameWithOwner, systemImage: "chevron.left.forwardslash.chevron.right")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func pullRequestLink(_ pullRequest: GitHubPullRequestSnapshot) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                Text("#\(pullRequest.number) \(pullRequest.title)")
                    .lineLimit(compact ? 2 : 3)
                    .truncationMode(.tail)
                if pullRequest.webURL != nil {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2)
                }
            }

            HStack(spacing: 5) {
                Text(pullRequest.statusDisplay)
                if let branchDisplay = pullRequest.branchDisplay {
                    Text("·")
                    Text(branchDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let url = pullRequest.webURL {
            Link(destination: url) {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pull request \(pullRequest.number), \(pullRequest.title)")
            .accessibilityHint("Opens the pull request in the default browser")
        } else {
            label
        }
    }
}
