//
//  NoticeBanner.swift
//  Recaptr
//
//  A glass banner under the top controls for `Notice`s: what happened in
//  one sentence, what to do next, and a fix button when there is one.
//  Stays until closed or the next recording starts.
//

import SwiftUI

struct NoticeBanner: View {
    let notice: Notice
    var onFix: (Notice.Fix) -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notice.endedTake || notice.fix != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(notice.endedTake || notice.fix != nil ? Color.orange : Color.signal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.message)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let next = notice.next {
                    Text(next)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let fix = notice.fix {
                Button(fix.label) { onFix(fix) }
                    .accessibilityIdentifier("noticeFix")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("noticeClose")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .recaptrGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noticeBanner")
    }
}
