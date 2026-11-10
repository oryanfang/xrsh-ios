import SwiftUI

struct SectionHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text(tr("{0} 台", count))
                        .font(.caption)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct DeviceRow: View {
    let device: SSHDevice
    /// 这台设备设置过免密登录，点一下就能直接进入，显示黄色五角星
    var hasKey = false

    private var icon: String {
        device.deviceType?.icon ?? (device.hasSSH ? "desktopcomputer" : "wifi")
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(device.hasSSH ? .blue : .gray)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(device.ipAddress)
                    .font(.body.monospaced())
                let detail = [device.displayName, device.deviceType?.name].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let banner = device.banner {
                    Text(tr("未获取到名称 · {0}", banner))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if device.isOffline {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(tr("上次在线 {0}", RelativeTime.text(device.lastSeen, now: context.date)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if device.isNew, Date().timeIntervalSince(device.firstSeen) < 24 * 3600 {
                Text(tr("新"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            }
            if device.hasSSH {
                if hasKey {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .opacity(device.isOffline ? 0.5 : 1)
    }
}

/// "3分钟前" 这样的相对时间，会自己每隔一会儿刷新
struct RelativeTime: View {
    let date: Date
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func text(_ date: Date, now: Date) -> String {
        formatter.locale = AppLanguage.locale
        return now.timeIntervalSince(date) < 10 ? tr("刚刚") : formatter.localizedString(for: date, relativeTo: now)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(Self.text(date, now: context.date))
        }
    }
}
