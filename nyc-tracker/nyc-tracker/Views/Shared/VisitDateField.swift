import Foundation
import SwiftUI

/// "When did you go?" — the optional date on an entry.
///
/// Optional in the sense that matters: it always has a value, and that value is
/// already right for the common case (you log a place the day you went). Nobody
/// has to touch it. It exists for the other case — logging last weekend's dinner
/// on a Tuesday, or backfilling a year of places — where the upload date is not
/// the date anyone means.
///
/// ## Only the day is editable, and that is load-bearing
///
/// `displayedComponents: .date` preserves the time-of-day of the bound value.
/// That is what keeps ordering sane: three entries backfilled to the same
/// Saturday keep the clock times of the three capture sessions, so they sort
/// among themselves in the order they were written rather than colliding on
/// midnight and falling back to whatever tiebreak each surface happens to use.
/// Asking for a time as well would be precision nobody has and would break that.
struct VisitDateField: View {
    @Binding var date: Date

    /// No future visits. A date ahead of now is either a typo or a want-to-try,
    /// and want-to-try is a different kind of entry with its own flow.
    private var range: PartialRangeThrough<Date> { ...Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            DatePicker(
                "Date",
                selection: $date,
                in: range,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Date of visit")
    }
}
