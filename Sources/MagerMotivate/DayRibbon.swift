import MotivateCore
import SwiftUI

/// The working day as one strip: an hour per segment, lunch tinted, a "now" marker,
/// and overtime hatched in red past the scheduled end.
struct DayRibbon: View {
  let today: DaySnapshot.Today
  /// Overtime beyond this many hours is not drawn wider, only labelled.
  private let maxOvertimeHours = 3.0
  private let barHeight: CGFloat = 16
  @State private var hovered: Int?

  var body: some View {
    let hours = today.hours
    let overtimeUnits = min(today.overtimeHours, maxOvertimeHours)
    VStack(alignment: .leading, spacing: 4) {
      GeometryReader { geo in
        let unit = geo.size.width / (Double(hours.count) + overtimeUnits)
        let dayWidth = unit * Double(hours.count)
        ZStack(alignment: .topLeading) {
          ForEach(hours.indices, id: \.self) { i in
            segment(hours[i], index: i)
              .frame(width: max(unit - 2, 1), height: barHeight)
              .offset(x: unit * Double(i))
          }
          if overtimeUnits > 0 {
            OvertimeHatch()
              .frame(width: max(unit * overtimeUnits - 2, 1), height: barHeight)
              .offset(x: dayWidth)
          }
          if let now = today.nowFraction {
            Image(systemName: "arrowtriangle.up.fill")
              .font(.system(size: 7))
              .foregroundStyle(.primary)
              .position(x: dayWidth * now, y: barHeight + 5)
          }
          ForEach(hours.indices, id: \.self) { i in
            axisLabel(hours[i].startLabel).position(x: max(unit * Double(i), 6), y: barHeight + 15)
          }
          axisLabel(today.endLabel).position(x: dayWidth - 8, y: barHeight + 15)
        }
      }
      .frame(height: barHeight + 22)

      // The line keeps its height when empty, so hovering a segment doesn't shift the menu.
      ZStack(alignment: .leading) {
        Text(" ").hidden()
        if let hovered, today.hours.indices.contains(hovered) {
          let hour = today.hours[hovered]
          Text("\(hour.label) · \(hour.state == .upcoming ? "впереди" : hour.amount)\(hour.isLunch ? " · обед" : "")")
        } else if today.overtimeHours >= 1 / 60 {
          Text("После \(today.endTime) — бесплатно").foregroundStyle(.red)
        } else if let remaining = today.remaining {
          Text("До конца дня: \(remaining)")
        }
      }
      .font(.caption)
      .monospacedDigit()
      .foregroundStyle(.secondary)
    }
  }

  private func segment(_ hour: DaySnapshot.Hour, index: Int) -> some View {
    let tint: Color = hour.isLunch ? .orange : .accentColor
    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3).fill(.quaternary)
        RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: geo.size.width * hour.fraction)
        if hour.isLunch {
          Text("🍜").font(.system(size: 9)).frame(maxWidth: .infinity)
        }
      }
    }
    .opacity(hovered == nil || hovered == index ? 1 : 0.6)
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { hovered = index } else if hovered == index { hovered = nil }
    }
  }

  private func axisLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
  }
}

private struct OvertimeHatch: View {
  var body: some View {
    Canvas { context, size in
      let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
      context.fill(shape, with: .color(.red.opacity(0.18)))
      context.clip(to: shape)
      var lines = Path()
      var x = -size.height
      while x < size.width {
        lines.move(to: CGPoint(x: x, y: size.height))
        lines.addLine(to: CGPoint(x: x + size.height, y: 0))
        x += 5
      }
      context.stroke(lines, with: .color(.red.opacity(0.75)), lineWidth: 1.5)
    }
  }
}
