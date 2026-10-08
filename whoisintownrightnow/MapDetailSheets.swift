import SwiftUI

private struct MapDetailHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.title.bold())
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(width: 44, height: 44)
                    .background(Theme.secondaryLabel.opacity(0.09), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
            .accessibilityIdentifier("close-signal-detail")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
}

struct FriendDetailSheet: View {
    let friend: Friend
    let onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(friend.locationName ?? friend.hood)
                        .font(.title3)
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if friend.locationName != nil {
                        Text(friend.hood).foregroundStyle(Theme.secondaryLabel)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        locationStatus(at: context.date)
                    }
                }

                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 24))
                layout {
                    Label(friend.distanceLabel + " away", systemImage: "location")
                    Label(friend.isFree ? "Free to hang" : "Not available",
                          systemImage: friend.isFree ? "circle.fill" : "moon.fill")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryLabel)

                Text(friend.note)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sample location")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MapDetailHeader(title: friend.name, onClose: onClose)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friend-detail")
    }

    private func locationStatus(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if friend.locationFreshness.isUpdating {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                        .accessibilityHidden(true)
                } else if friend.locationFreshness.isLive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(friend.locationFreshness.label(at: now))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(friend.locationFreshness.isLive ? Color.green : Theme.accent)
            if let detail = friend.locationFreshness.detail(at: now) {
                Text(detail).font(.caption).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("location-freshness")
    }
}

struct SignalDetailSheet: View {
    let signal: Signal
    let onJoin: () -> Void
    let onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var iconColumn = 28.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    PersonAvatar(initials: signal.hostInitials, color: signal.hostColor, size: 40)
                    Text(signal.isMine ? "Your invitation" : "\(signal.hostFirstName) wants to hang")
                        .foregroundStyle(Theme.secondaryLabel)
                }
                if let video = signal.video {
                    HangVideoPoster(video: video, title: signal.isMine ? "your invitation" : "\(signal.hostFirstName)’s invitation")
                }
                VStack(alignment: .leading, spacing: 16) {
                    detailRow(symbol: "clock") { Text(signal.window) }
                    detailRow(symbol: "mappin.and.ellipse") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(signal.place)
                            if let detail = signal.placeDetail, !detail.isEmpty {
                                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                            } else if signal.destinationIsAtAnchor {
                                Text("Near \(signal.hostFirstName)")
                                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                            }
                        }
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    attendance
                    previewNotice
                }
            }
            .foregroundStyle(Theme.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MapDetailHeader(title: signal.title, onClose: onClose)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 14) {
                if !dynamicTypeSize.isAccessibilitySize {
                    attendance.padding(.horizontal, 4)
                }
                Button(action: onJoin) {
                    Label(joinTitle, systemImage: signal.isJoined ? "checkmark.circle.fill" : "person.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .font(.headline)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                .tint(Theme.orchid).foregroundStyle(signal.canJoin ? Theme.ink : Theme.label)
                .disabled(!signal.canJoin)
                .accessibilityIdentifier("join-signal")
                if !dynamicTypeSize.isAccessibilitySize { previewNotice }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signal-detail")
    }

    private func detailRow<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title3)
                .frame(width: iconColumn, alignment: .center).accessibilityHidden(true)
            content().fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var joinTitle: String {
        signal.isMine ? "Your hang" : signal.isJoined ? "You’re in" : signal.isFull ? "Hang is full" : "Join \(signal.hostFirstName)"
    }

    private var previewNotice: some View {
        Text("Preview only · No notifications sent")
            .font(.caption2).foregroundStyle(Theme.secondaryLabel)
    }

    private var attendance: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                HStack(spacing: -10) {
                    ForEach(Array(signal.going.prefix(3).enumerated()), id: \.offset) { index, initials in
                        PersonAvatar(initials: initials, color: avatarColor(for: initials), size: 36)
                            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                            .zIndex(Double(3 - index))
                    }
                }
                Text("\(signal.going.count) going").font(.subheadline)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(spotsLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
        .foregroundStyle(Theme.label)
        .accessibilityElement(children: .combine)
    }

    private var spotsLabel: String {
        guard let remaining = signal.remainingSpots else { return "No limit" }
        if remaining == 0 { return "Full" }
        return remaining == 1 ? "1 spot left" : "\(remaining) spots left"
    }

    private func avatarColor(for initials: String) -> Color {
        if initials == signal.hostInitials { return signal.hostColor }
        return Friend.mock.first { $0.initials == initials }?.color ?? Theme.cocoa
    }
}

#Preview("Hosting") {
    SignalDetailSheet(signal: Signal.mock[0], onJoin: {}, onClose: {})
        .frame(height: 420).background(.regularMaterial)
}

#Preview("Friend · Updating") {
    FriendDetailSheet(friend: Friend.mock[4], onClose: {})
        .frame(height: 420).background(.regularMaterial)
}
