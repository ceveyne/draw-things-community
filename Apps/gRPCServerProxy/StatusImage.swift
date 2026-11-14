import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import Diffusion
import Foundation
import NNC

struct StatusModel {
  enum BatchState {
    case pending, running, done, delivered, failed, cancelled

    var word: String {
      switch self {
      case .pending: return Loc.t("Pending", "Wartet")
      case .running: return Loc.t("Running", "Läuft")
      case .done: return Loc.t("Generated", "Generiert")
      case .delivered: return Loc.t("Delivered", "Ausgeliefert")
      case .failed: return Loc.t("Failed", "Fehlgeschlagen")
      case .cancelled: return Loc.t("Cancelled", "Abgebrochen")
      }
    }

    var countWord: String {
      switch self {
      case .pending: return Loc.t("pending", "wartend")
      case .running: return Loc.t("running", "laufend")
      case .done: return Loc.t("generated", "generiert")
      case .delivered: return Loc.t("delivered", "ausgeliefert")
      case .failed: return Loc.t("failed", "fehlgeschlagen")
      case .cancelled: return Loc.t("cancelled", "abgebrochen")
      }
    }

    var glyph: String {
      switch self {
      case .pending: return "\u{25CB}"
      case .running: return "\u{25CF}"
      case .done, .delivered: return "\u{2713}"
      case .failed, .cancelled: return "\u{2715}"
      }
    }
  }

  enum Phase {
    case processing, sampling, finishing
  }

  struct Batch {
    var state: BatchState
    var step: Int?

    var eta: TimeInterval?
    var phase: Phase? = nil
  }

  struct GroupBlock {
    var code: String
    var batchSize: Int
    var steps: Int
    var isCurrent: Bool
    var batches: [Batch]

    var project: String?
  }

  struct Detail {
    var code: String

    var fields: [(label: String, value: String)]
  }

  var info: String?
  var detail: Detail?

  struct Table {
    var project: String
    var groups: [GroupBlock]
  }

  var note: String?
  var tables: [Table]

  var progress: Double

  var barLabel: String

  var barTime: String

  var compact = false
}

enum StatusImage {

  private static let background = rgb(0x10, 0x11, 0x13)
  private static let panel = rgb(0x1A, 0x1C, 0x1E)
  private static let raised = rgb(0x26, 0x28, 0x32)
  private static let strong = rgb(0xAA, 0xB4, 0xBA)
  private static let text = rgb(0xAA, 0xB4, 0xBA)
  private static let muted = rgb(0x8A, 0x93, 0x9F)
  private static let line = rgb(0x34, 0x38, 0x46)
  private static let badge = rgb(0x42, 0x46, 0x54)

  private static let headerRule = rgb(0x41, 0x47, 0x57)
  private static let outline = rgb(0x50, 0x56, 0x62)
  private static let failure = rgb(0xE2, 0x4A, 0x3A)

  private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
  }

  static func render(
    model: StatusModel, preview: CGImage?, width: Int, height: Int
  ) -> Tensor<FloatType>? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace, bitmapInfo: bitmapInfo)
    else { return nil }
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var hasPreview = false
    if model.detail == nil, let image = preview {

      let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
      let softened = smoothUpscale(image, scale: scale) ?? image
      let drawWidth = CGFloat(image.width) * scale
      let drawHeight = CGFloat(image.height) * scale
      ctx.interpolationQuality = .high
      ctx.draw(
        softened,
        in: CGRect(
          x: (CGFloat(width) - drawWidth) / 2, y: (CGFloat(height) - drawHeight) / 2,
          width: drawWidth, height: drawHeight))
      hasPreview = true
    }
    draw(
      model: model, hasPreview: hasPreview, detailPreview: model.detail == nil ? nil : preview,
      in: ctx, width: CGFloat(width), height: CGFloat(height))
    return tensor(from: ctx, width: width, height: height)
  }

  private static func draw(
    model: StatusModel, hasPreview: Bool, detailPreview: CGImage?, in ctx: CGContext,
    width: CGFloat, height: CGFloat
  ) {

    let u = max(width, 320) / 560
    let margin = 20 * u
    let pad = 12 * u
    let frameX = margin
    let frameWidth = width - 2 * margin
    let inner = frameWidth - 2 * pad
    let barHeight = 23 * u
    let barTop = height - margin - barHeight
    var top = margin

    let fontScale: CGFloat = model.compact ? 2.34 : 1
    let barScale: CGFloat = model.compact ? 1.25 : 1

    func font(_ size: CGFloat, bold: Bool = false, mono: Bool = false, scale: CGFloat? = nil) -> CTFont {
      let size = size * u * (scale ?? fontScale)
      if mono { return CTFontCreateWithName("Menlo" as CFString, size, nil) }
      return CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    func attributed(_ runs: [(String, CTFont, CGColor)]) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (string, font, color) in runs {
        result.append(
          NSAttributedString(
            string: string,
            attributes: [
              NSAttributedString.Key(kCTFontAttributeName as String): font,
              NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
      }
      return result
    }

    func metrics(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, height: CGFloat) {
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
      return (width, ascent, ascent + descent + leading)
    }

    func lineHeight(_ string: NSAttributedString) -> CGFloat {
      metrics(CTLineCreateWithAttributedString(string)).height
    }

    func lineWidth(_ string: NSAttributedString) -> CGFloat {
      metrics(CTLineCreateWithAttributedString(string)).width
    }

    func drawLine(
      _ string: NSAttributedString, x: CGFloat, y: CGFloat, maxWidth: CGFloat? = nil,
      alignRight: Bool = false
    ) {
      var ctLine = CTLineCreateWithAttributedString(string)
      if let maxWidth = maxWidth, metrics(ctLine).width > maxWidth, string.length > 0 {
        let token = CTLineCreateWithAttributedString(
          NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))
        ctLine = CTLineCreateTruncatedLine(ctLine, Double(maxWidth), .end, token) ?? ctLine
      }
      let measured = metrics(ctLine)
      ctx.textPosition = CGPoint(
        x: alignRight ? x - measured.width : x, y: height - y - measured.ascent)
      CTLineDraw(ctLine, ctx)
    }

    func paragraphHeight(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
      let setter = CTFramesetterCreateWithAttributedString(string)
      return CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRange(location: 0, length: 0), nil,
        CGSize(width: width, height: .greatestFiniteMagnitude), nil
      ).height
    }

    func drawParagraph(
      _ string: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat, blockHeight: CGFloat
    ) {
      let setter = CTFramesetterCreateWithAttributedString(string)
      let path = CGPath(
        rect: CGRect(x: x, y: height - y - blockHeight, width: width, height: blockHeight),
        transform: nil)
      CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
    }

    func clock(_ seconds: TimeInterval) -> String {
      let total = max(Int(seconds.rounded()), 0)
      if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
      return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func rule(at y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: CGColor? = nil) {
      ctx.setFillColor(color ?? line)
      ctx.fill(CGRect(x: x0, y: height - y - max(u, 1), width: x1 - x0, height: max(u, 1)))
    }

    func roundedFill(_ rect: CGRect, radius: CGFloat, color: CGColor) {
      ctx.setFillColor(color)
      ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      ctx.fillPath()
    }

    func drawBar() {

      let track = CGRect(x: frameX, y: height - barTop - barHeight, width: frameWidth, height: barHeight)
      roundedFill(track, radius: 8 * u, color: rgb(0x1D, 0x1F, 0x26, hasPreview ? 0.9 : 1))
      let dark = rgb(0x10, 0x11, 0x13)
      let light = text
      let labelWidth = lineWidth(attributed([(model.barLabel, font(11, scale: barScale), dark)]))
      let mark = watermarkGeometry(width: Int(width), height: Int(height))
      let markWidth = CGFloat(watermarkBits.count * mark.cell)
      let fillWidth = max(
        track.width * CGFloat(min(max(model.progress, 0), 1)), labelWidth + 2 * 14 * u,
        8 * u + markWidth + 8 * u)
      let fillRect = CGRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: track, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil))
      ctx.clip()
      ctx.setFillColor(rgb(255, 255, 255))
      ctx.fill(fillRect)
      ctx.restoreGState()

      ctx.saveGState()
      ctx.setShouldAntialias(false)
      for (index, bit) in watermarkBits.enumerated() {
        let level = CGFloat(bit ? watermarkHigh : watermarkLow) / 255
        ctx.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        ctx.fill(
          CGRect(
            x: mark.x0 + index * mark.cell, y: Int(height) - mark.y0 - mark.rows, width: mark.cell,
            height: mark.rows))
      }
      ctx.restoreGState()

      let barTextTop = barTop + (barHeight - lineHeight(attributed([(model.barLabel, font(11, scale: barScale), dark)]))) / 2
      func drawBarTexts(color label: CGColor, time: CGColor) {
        drawLine(attributed([(model.barLabel, font(11, scale: barScale), label)]), x: track.minX + 14 * u, y: barTextTop)
        drawLine(
          attributed([(model.barTime, font(11, scale: barScale), time)]), x: track.maxX - 14 * u, y: barTextTop,
          alignRight: true)
      }
      ctx.saveGState()
      ctx.clip(to: fillRect)
      drawBarTexts(color: dark, time: dark)
      ctx.restoreGState()
      ctx.saveGState()
      ctx.clip(to: CGRect(x: fillRect.maxX, y: track.minY, width: track.maxX - fillRect.maxX, height: track.height))
      drawBarTexts(color: light, time: light)
      ctx.restoreGState()
    }

    func drawDetail(_ detail: StatusModel.Detail) {
      let labelFont = font(11, bold: true)
      let valueFont = font(11)

      let codeFont = font(11, mono: true)
      var runs: [(String, CTFont, CGColor)] = [("\u{00A0}\(detail.code)\u{00A0}", codeFont, strong)]
      for field in detail.fields {
        runs.append((" \u{2022} ", valueFont, muted))
        runs.append((field.label + ": ", labelFont, strong))
        runs.append((field.value, valueFont, text))
      }

      var lineSpacing = 1.5 * 11 * u * fontScale
      let styled = NSMutableAttributedString(attributedString: attributed(runs))
      withUnsafeMutablePointer(to: &lineSpacing) { pointer in
        let settings = [
          CTParagraphStyleSetting(
            spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pointer),
          CTParagraphStyleSetting(
            spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: pointer),
        ]
        let style = CTParagraphStyleCreate(settings, settings.count)
        styled.addAttribute(
          NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style,
          range: NSRange(location: 0, length: styled.length))
      }
      let string = styled
      let gap = 10 * u
      let textHeight = min(paragraphHeight(string, width: frameWidth), (barTop - margin) * 0.5)
      let textTop = barTop - gap - textHeight
      let setter = CTFramesetterCreateWithAttributedString(string)
      let path = CGPath(
        rect: CGRect(x: frameX, y: height - textTop - textHeight, width: frameWidth, height: textHeight),
        transform: nil)
      let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)

      let codeRun = attributed([("\u{00A0}\(detail.code)\u{00A0}", codeFont, strong)])
      if let first = (CTFrameGetLines(frame) as? [CTLine])?.first {
        var origin = CGPoint.zero
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &origin)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(first, &ascent, &descent, &leading)
        let codeAscent = CTFontGetAscent(codeFont)
        let codeDescent = CTFontGetDescent(codeFont)
        roundedFill(
          CGRect(
            x: frameX + origin.x, y: height - textTop - textHeight + origin.y - codeDescent - 2 * u,
            width: lineWidth(codeRun),
            height: codeAscent + codeDescent + 4 * u), radius: 4 * u, color: badge)
      }
      CTFrameDraw(frame, ctx)

      let room = CGRect(
        x: frameX, y: top, width: frameWidth, height: max(textTop - gap - top, 0))
      if let image = detailPreview, room.height > 20 * u {
        let scale = min(room.width / CGFloat(image.width), room.height / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let softened = smoothUpscale(image, scale: scale) ?? image
        let rect = CGRect(
          x: frameX + (room.width - drawWidth) / 2, y: height - top - drawHeight,
          width: drawWidth, height: drawHeight)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(softened, in: rect)
        ctx.restoreGState()
      }
    }

    if model.info != nil || model.detail != nil {
      if let info = model.info {
        let string = attributed([(info, font(11), strong)])
        drawLine(string, x: frameX, y: top, maxWidth: frameWidth)
        top += lineHeight(string) + 8 * u
      }
    }
    if let detail = model.detail {
      drawDetail(detail)
      drawBar()
      return
    }

    let cellPad = 7 * u
    let rowFont = font(11)
    let rowHeight = lineHeight(attributed([("Ag", rowFont, text)])) + 2 * cellPad

    let commandHint = attributed([
      ("Prompt ", font(10), text), ("cancel <Request-ID>", font(9, mono: true), text),
      (Loc.t(" to abort or ", " zum Abbrechen oder "), font(10), text), ("status <Request-ID>", font(9, mono: true), text),
      (Loc.t(" for details.", " für Details."), font(10), text),
    ])
    let projectHint = attributed([
      (Loc.t("Results arrive in the project of their request. Switch to that project to receive them.", "Ergebnisse kommen im Projekt ihrer jeweiligen Anfrage an. Wechsle in dieses Projekt, um sie zu erhalten."), font(10), text)
    ])
    let showHints = model.tables.contains { !$0.groups.isEmpty }
    let tableLimit = hasPreview ? height * 0.74 : barTop - margin

    if let note = model.note {
      let string = attributed([(note, font(11), failure)])
      drawLine(string, x: frameX, y: top + (rowHeight - lineHeight(string)) / 2, maxWidth: frameWidth)
      top += rowHeight + 6 * u
    }
    func drawTable(_ table: StatusModel.Table, maxBodyRows: Int, hints: [NSAttributedString]) {
      let tableTop = top

      struct TableRow {
        var group: Int
        var isCurrent: Bool
        var showID: Bool
        var code: String
        var first: Int
        var last: Int
        var total: Int
        var batchSize: Int
        var steps: Int
        var state: StatusModel.BatchState?
        var step: Int?
        var eta: TimeInterval?
        var summary: String?
        var isBand = false
        var label = ""
      }
      func rows(of block: StatusModel.GroupBlock, index: Int) -> [TableRow] {
        block.batches.enumerated().map {
          TableRow(
            group: index, isCurrent: block.isCurrent, showID: $0.offset == 0, code: block.code,
            first: $0.offset + 1, last: $0.offset + 1, total: block.batches.count,
            batchSize: block.batchSize, steps: block.steps, state: $0.element.state,
            step: $0.element.step, eta: $0.element.eta, summary: nil)
        }
      }
      func merged(_ list: [TableRow]) -> [TableRow] {
        var result = [TableRow]()
        for row in list {
          if let last = result.last, last.group == row.group, last.state == row.state,
            row.state != .running, row.summary == nil, last.summary == nil
          {
            result[result.count - 1].last = row.last
            result[result.count - 1].eta = row.eta
          } else {
            result.append(row)
          }
        }
        return result
      }
      func countsSummary(_ block: StatusModel.GroupBlock) -> String {
        var parts = [String]()
        for state in [StatusModel.BatchState.running, .pending, .done, .delivered, .failed, .cancelled] {
          let n = block.batches.filter { $0.state == state }.count
          if n > 0 { parts.append("\(n) \(state.countWord)") }
        }
        return parts.joined(separator: " \u{00B7} ")
      }

      let maxRows = maxBodyRows
      var order = Array(table.groups.enumerated())
      var tableRows = order.flatMap { rows(of: $0.element, index: $0.offset) }
      if tableRows.count > maxRows { tableRows = order.flatMap { merged(rows(of: $0.element, index: $0.offset)) } }
      if tableRows.count > maxRows {
        tableRows = order.flatMap { entry -> [TableRow] in
          if entry.element.isCurrent { return merged(rows(of: entry.element, index: entry.offset)) }
          let batches = entry.element.batches
          let last = batches.last?.eta
          return [
            TableRow(
              group: entry.offset, isCurrent: false, showID: true, code: entry.element.code, first: 1,
              last: batches.count, total: batches.count, batchSize: entry.element.batchSize,
              steps: entry.element.steps, state: nil, step: nil, eta: last,
              summary: countsSummary(entry.element))
          ]
        }
      }
      var hidden = 0
      while tableRows.count + (hidden > 0 ? 1 : 0) > maxRows, order.count > 1,
        let drop = order.firstIndex(where: { !$0.element.isCurrent })
      {
        let index = order[drop].offset
        order.remove(at: drop)
        tableRows.removeAll { $0.group == index }
        hidden += 1
      }

      let shares: [CGFloat] = [0.15, 0.12, 0.15, 0.22, 0.24, 0.12]
      var edges = [frameX]
      for share in shares { edges.append(edges.last! + frameWidth * share) }
      edges[edges.count - 1] = frameX + frameWidth

      let bodyRows = tableRows.count + (hidden > 0 ? 1 : 0) + (table.groups.isEmpty ? 1 : 0) + hints.count

      let tableHeight = CGFloat(2 + bodyRows) * rowHeight
      let tableRect = CGRect(x: frameX, y: height - tableTop - tableHeight, width: frameWidth, height: tableHeight)
      let ground: CGFloat = hasPreview ? 0.84 : 1
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: tableRect, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil))
      ctx.clip()

      let bodyTop = tableTop + 2 * rowHeight
      let highlighted = tableRows.enumerated().filter { $0.element.group % 2 == 1 }.map {
        CGRect(x: frameX, y: height - bodyTop - CGFloat($0.offset + 1) * rowHeight, width: frameWidth, height: rowHeight)
      }
      ctx.setFillColor(rgb(0x10, 0x11, 0x13, ground))
      ctx.addRect(tableRect)
      for rect in highlighted { ctx.addRect(rect) }
      ctx.fillPath(using: .evenOdd)

      ctx.setFillColor(rgb(0x33, 0x37, 0x42, hasPreview ? 0.94 : 1))
      ctx.fill(CGRect(x: frameX, y: height - tableTop - rowHeight, width: frameWidth, height: rowHeight))
      let titleString = attributed([(table.project, font(11, bold: true), strong)])
      drawLine(
        titleString, x: edges[0] + cellPad, y: tableTop + (rowHeight - lineHeight(titleString)) / 2,
        maxWidth: frameWidth - 2 * cellPad)

      ctx.setFillColor(rgb(0x33, 0x37, 0x42, hasPreview ? 0.94 : 1))
      ctx.fill(CGRect(x: frameX, y: height - tableTop - 2 * rowHeight, width: frameWidth, height: rowHeight))
      rule(at: tableTop + rowHeight, from: frameX, to: frameX + frameWidth, color: headerRule)
      let heads = Loc.german ? ["Request-ID", "Batch", "Batchgröße", "Status", "Schritt", "ETA"] : ["Request-ID", "Batch", "Batch Size", "Status", "Step", "ETA"]
      for (index, title) in heads.enumerated() {
        let string = attributed([(title, font(10, bold: true), strong)])
        drawLine(string, x: edges[index] + cellPad, y: tableTop + rowHeight + (rowHeight - lineHeight(string)) / 2)
      }

      top = tableTop + 2 * rowHeight
      let running = strong

      let faint = rgb(0x1D, 0x1F, 0x26, ground)
      var previousGroup = -1
      for row in tableRows {
        let startsGroup = row.group != previousGroup
        if row.group % 2 == 1 {
          ctx.setFillColor(faint)
          ctx.fill(CGRect(x: frameX, y: height - top - rowHeight, width: frameWidth, height: rowHeight))
        }
        rule(at: top, from: frameX, to: frameX + frameWidth, color: startsGroup ? line : rgb(0x26, 0x28, 0x32))
        previousGroup = row.group
        let textTop = top + cellPad

        let cell = row.state == .pending || row.state == .cancelled ? muted : text

        if row.showID {
          drawLine(attributed([(row.code, font(11, mono: true), text)]), x: edges[0] + cellPad, y: textTop)
        }
        let label = row.first == row.last ? "\(row.first) / \(row.total)" : "\(row.first)\u{2013}\(row.last) / \(row.total)"
        drawLine(attributed([(label, rowFont, cell)]), x: edges[1] + cellPad, y: textTop)
        let images = row.first == row.last ? "\(row.batchSize)" : "\(row.batchSize) \(Loc.t("each", "je"))"
        drawLine(attributed([(images, rowFont, cell)]), x: edges[2] + cellPad, y: textTop)

        if let summary = row.summary {
          drawLine(
            attributed([(summary, font(10), cell)]), x: edges[3] + cellPad, y: textTop,
            maxWidth: edges[5] - edges[3] - 2 * cellPad)
        } else if let state = row.state {
          let color: CGColor
          switch state {
          case .running, .done, .delivered: color = text
          case .pending, .cancelled: color = muted
          case .failed: color = failure
          }
          drawLine(attributed([("\(state.glyph) \(state.word)", rowFont, color)]), x: edges[3] + cellPad, y: textTop)

          var stepText = "\u{2013}"
          switch state {
          case .running: stepText = row.step.map { "\($0) / \(row.steps)" } ?? "\u{2026}"
          case .done, .delivered: stepText = "\(row.steps) / \(row.steps)"
          default: break
          }
          let stepString = attributed([(stepText, rowFont, cell)])
          drawLine(stepString, x: edges[4] + cellPad, y: textTop)
          if state == .running, let step = row.step, row.steps > 0 {
            let barX = edges[4] + cellPad + lineWidth(stepString) + 8 * u
            let barWidth = edges[5] - cellPad - barX
            if barWidth > 20 * u {
              let barH = 4 * u
              let y = height - top - rowHeight / 2 - barH / 2
              roundedFill(CGRect(x: barX, y: y, width: barWidth, height: barH), radius: barH / 2, color: line)
              roundedFill(
                CGRect(
                  x: barX, y: y,
                  width: max(barH, barWidth * CGFloat(min(Double(step) / Double(row.steps), 1))),
                  height: barH), radius: barH / 2, color: running)
            }
          }
        }
        var etaText = "\u{2013}"
        if row.state == .running || row.state == .pending || row.summary != nil {
          etaText = row.eta.map { clock($0) } ?? "--:--"
        }
        drawLine(attributed([(etaText, rowFont, cell)]), x: edges[5] + cellPad, y: textTop)
        top += rowHeight
      }
      if hidden > 0 {
        rule(at: top, from: frameX, to: frameX + frameWidth, color: line)
        drawLine(attributed([("+ \(hidden) \(Loc.t("more", "weitere"))", font(10), muted)]), x: edges[0] + cellPad, y: top + cellPad)
        top += rowHeight
      }
      if table.groups.isEmpty {
        rule(at: top, from: frameX, to: frameX + frameWidth, color: line)
        drawLine(attributed([(Loc.t("No running jobs", "Keine laufenden Jobs"), rowFont, muted)]), x: edges[0] + cellPad, y: top + cellPad)
        top += rowHeight
      }
      for hint in hints {
        ctx.setFillColor(rgb(0x33, 0x37, 0x42, hasPreview ? 0.94 : 1))
        ctx.fill(CGRect(x: frameX, y: height - top - rowHeight, width: frameWidth, height: rowHeight))
        rule(at: top, from: frameX, to: frameX + frameWidth, color: headerRule)
        drawLine(
          hint, x: edges[0] + cellPad, y: top + (rowHeight - lineHeight(hint)) / 2,
          maxWidth: frameWidth - 2 * cellPad)
        top += rowHeight
      }
      ctx.restoreGState()
      ctx.setStrokeColor(line)
      ctx.setLineWidth(max(u, 1))
      ctx.addPath(
        CGPath(
          roundedRect: tableRect.insetBy(dx: 0.5 * u, dy: 0.5 * u), cornerWidth: 8 * u,
          cornerHeight: 8 * u, transform: nil))
      ctx.strokePath()
      top = tableTop + tableHeight + 12 * u
    }

    func compactTexts(_ block: StatusModel.GroupBlock) -> (first: String, second: String?, color: CGColor) {
      let batches = block.batches
      let count = batches.count
      func left(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 1)
        return Loc.left(total)
      }
      let counts = [StatusModel.BatchState.running, .pending, .done, .delivered, .failed, .cancelled].compactMap {
        state -> String? in
        let n = batches.filter { $0.state == state }.count
        return n > 0 ? "\(n) \(state.countWord)" : nil
      }
      if let index = batches.firstIndex(where: { $0.state == .running }) {
        let running = batches[index]
        var first = Loc.t("Processing...", "Verarbeitung…")
        switch running.phase {
        case .finishing: first = Loc.t("Finishing...", "Abschluss…")
        case .sampling where (running.step ?? 0) >= 1 && block.steps > 0:
          let step = running.step ?? 0
          first = Loc.stepLine(step, block.steps, Int((Double(step) / Double(block.steps + 1) * 100).rounded()))
        default: break
        }
        var parts = [String]()
        if count > 1 { parts.append("Batch \(index + 1)/\(count)") }
        if let eta = running.eta { parts.append(left(eta)) }
        return (first, parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} "), text)
      }
      let states = Set(batches.map { $0.state })
      if states.count == 1, let state = states.first {
        var second: String? = nil
        if count > 1 { second = Loc.t("\(count) batches", "\(count) Batches") }
        if state == .pending, let eta = batches.compactMap({ $0.eta }).max() { second = left(eta) }
        let color: CGColor = state == .failed ? failure : (state == .pending || state == .cancelled ? muted : text)
        return (state.word, second, color)
      }
      let waiting = batches.contains { $0.state == .pending }
      return (counts.first ?? "", counts.dropFirst().joined(separator: " \u{00B7} "), waiting ? muted : text)
    }

    func drawCompactTables() {
      let cp = 5 * u * fontScale
      let rowFont = font(11)
      let smallFont = font(10)
      let idFont = font(11, mono: true)
      let lh = lineHeight(attributed([("Ag", rowFont, text)]))
      let oneRow = lh + 2 * cp
      let twoRows = 2 * lh + 2 * cp
      let ground: CGFloat = hasPreview ? 0.84 : 1
      let headFill = rgb(0x33, 0x37, 0x42, hasPreview ? 0.94 : 1)
      let faint = rgb(0x1D, 0x1F, 0x26, ground)
      let idWidth = lineWidth(attributed([(String(repeating: "m", count: model.tables.flatMap { $0.groups }.contains { $0.code.count > 2 } ? 3 : 2), idFont, text)])) + 2 * cp
      let hints = [
        attributed([("cancel <ID> \u{00B7} status <ID>", font(10), text)]),
        attributed([(Loc.t("Results arrive in their own project.", "Ergebnisse kommen im zugehörigen Projekt an."), font(10), text)]),
      ]
      let showHints = model.tables.contains { !$0.groups.isEmpty }
      let limit = hasPreview ? height * 0.74 : barTop - margin
      let gap = 12 * u
      var overhead = showHints ? CGFloat(hints.count) * oneRow : 0
      overhead += CGFloat(model.tables.count) * (oneRow + gap)
      var available = max(limit - top - overhead, twoRows)
      for (tableIndex, table) in model.tables.enumerated() {
        var groups = Array(table.groups.enumerated())
        var hidden = 0

        let later = model.tables.dropFirst(tableIndex + 1).reduce(CGFloat(0)) {
          $0 + CGFloat(max($1.groups.count, 1)) * twoRows
        }
        let budget = max(available - later, twoRows)
        func rowHeight(_ block: StatusModel.GroupBlock) -> CGFloat {
          compactTexts(block).second == nil ? oneRow : twoRows
        }
        func needed() -> CGFloat {
          groups.reduce(CGFloat(0)) { $0 + rowHeight($1.element) } + (hidden > 0 ? oneRow : 0)
            + (groups.isEmpty ? oneRow : 0)
        }
        while needed() > budget, groups.count > 1,
          let drop = groups.firstIndex(where: { !$0.element.isCurrent })
        {
          groups.remove(at: drop)
          hidden += 1
        }
        let isLast = tableIndex == model.tables.count - 1
        let hintRows = isLast && showHints ? hints : []
        let tableTop = top
        let tableHeight = oneRow + needed() + CGFloat(hintRows.count) * oneRow
        available = max(available - needed(), 0)
        let tableRect = CGRect(x: frameX, y: height - tableTop - tableHeight, width: frameWidth, height: tableHeight)
        let bodyTop = tableTop + oneRow
        var highlighted = [CGRect]()
        var rowTop = bodyTop
        for entry in groups.enumerated() {
          let rowH = rowHeight(entry.element.element)
          if entry.element.offset % 2 == 1 {
            highlighted.append(CGRect(x: frameX, y: height - rowTop - rowH, width: frameWidth, height: rowH))
          }
          rowTop += rowH
        }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: tableRect, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil))
        ctx.clip()
        ctx.setFillColor(rgb(0x10, 0x11, 0x13, ground))
        ctx.addRect(tableRect)
        for rect in highlighted { ctx.addRect(rect) }
        ctx.fillPath(using: .evenOdd)
        for rect in highlighted {
          ctx.setFillColor(faint)
          ctx.fill(rect)
        }

        ctx.setFillColor(headFill)
        ctx.fill(CGRect(x: frameX, y: height - tableTop - oneRow, width: frameWidth, height: oneRow))
        let title = attributed([(table.project, font(11, bold: true), strong)])
        drawLine(title, x: frameX + cp, y: tableTop + cp, maxWidth: frameWidth - 2 * cp)
        var y = bodyTop
        for (position, entry) in groups.enumerated() {
          rule(at: y, from: frameX, to: frameX + frameWidth, color: position == 0 ? headerRule : line)
          let texts = compactTexts(entry.element)
          drawLine(attributed([(entry.element.code, idFont, strong)]), x: frameX + cp, y: y + cp)
          let textX = frameX + idWidth
          let textWidth = frameWidth - idWidth - cp
          drawLine(attributed([(texts.first, rowFont, texts.color)]), x: textX, y: y + cp, maxWidth: textWidth)
          if let second = texts.second {
            drawLine(attributed([(second, smallFont, texts.color)]), x: textX, y: y + cp + lh, maxWidth: textWidth)
          }
          y += rowHeight(entry.element)
        }
        if hidden > 0 {
          rule(at: y, from: frameX, to: frameX + frameWidth, color: line)
          drawLine(attributed([("+ \(hidden) \(Loc.t("more", "weitere"))", smallFont, muted)]), x: frameX + cp, y: y + cp)
          y += oneRow
        }
        if table.groups.isEmpty {
          rule(at: y, from: frameX, to: frameX + frameWidth, color: line)
          drawLine(attributed([(Loc.t("No running jobs", "Keine laufenden Jobs"), rowFont, muted)]), x: frameX + cp, y: y + cp)
          y += oneRow
        }
        for hint in hintRows {
          ctx.setFillColor(headFill)
          ctx.fill(CGRect(x: frameX, y: height - y - oneRow, width: frameWidth, height: oneRow))
          rule(at: y, from: frameX, to: frameX + frameWidth, color: headerRule)
          drawLine(hint, x: frameX + cp, y: y + (oneRow - lineHeight(hint)) / 2, maxWidth: frameWidth - 2 * cp)
          y += oneRow
        }
        ctx.restoreGState()
        ctx.setStrokeColor(line)
        ctx.setLineWidth(max(u, 1))
        ctx.addPath(
          CGPath(
            roundedRect: tableRect.insetBy(dx: 0.5 * u, dy: 0.5 * u), cornerWidth: 8 * u,
            cornerHeight: 8 * u, transform: nil))
        ctx.strokePath()
        top = tableTop + tableHeight + gap
      }
    }

    if model.compact {
      drawCompactTables()
      drawBar()
      return
    }

    let tableGap = 12 * u
    let hintRows = showHints ? [commandHint, projectHint] : []
    var overhead = CGFloat(hintRows.count) * rowHeight
    var demands = [Int]()
    for table in model.tables {
      overhead += 2 * rowHeight + tableGap
      demands.append(max(table.groups.reduce(0) { $0 + $1.batches.count }, 1))
    }
    let budget = max(Int((tableLimit - top - overhead) / rowHeight), model.tables.count)
    let totalDemand = max(demands.reduce(0, +), 1)
    for (index, table) in model.tables.enumerated() {
      let share = demands.reduce(0, +) <= budget ? demands[index] : max(budget * demands[index] / totalDemand, 1)
      let isLast = index == model.tables.count - 1
      drawTable(table, maxBodyRows: share, hints: isLast ? hintRows : [])
    }
    drawBar()
  }

  private static let watermarkBits: [Bool] = (0..<20).map { (0xB2E4D >> (19 - $0)) & 1 == 1 }
  private static let watermarkHigh = 255
  private static let watermarkLow = 248

  private static func watermarkGeometry(width: Int, height: Int) -> (x0: Int, y0: Int, cell: Int, rows: Int) {
    let u = CGFloat(max(width, 320)) / 560
    let margin = 20 * u
    let barTop = CGFloat(height) - margin - 23 * u
    return (
      Int((margin + 8 * u).rounded()), Int((barTop + 3 * u).rounded()),
      max(Int((3 * u).rounded()), 2), max(Int((2 * u).rounded()), 2)
    )
  }

  static func hasWatermarkInPNG(_ png: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let ctx = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let tensor = tensor(from: ctx, width: image.width, height: image.height) else { return false }
    return hasWatermark(tensor)
  }

  static func hasWatermark(_ tensor: Tensor<FloatType>) -> Bool {
    let shape = tensor.shape
    guard shape.count >= 3 else { return false }
    let h = shape[shape.count - 3]
    let w = shape[shape.count - 2]
    let c = shape[shape.count - 1]
    guard c >= 3, w >= 64, h >= 64 else { return false }
    let g = watermarkGeometry(width: w, height: h)
    guard g.x0 + watermarkBits.count * g.cell <= w, g.y0 + g.rows <= h else { return false }
    var matches = true
    tensor.withUnsafeBytes { raw in
      guard let p = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else {
        matches = false
        return
      }
      for (index, bit) in watermarkBits.enumerated() {
        var sum = 0.0
        for y in g.y0..<(g.y0 + g.rows) {
          for x in (g.x0 + index * g.cell)..<(g.x0 + (index + 1) * g.cell) {
            for k in 0..<3 { sum += (Double(Float(p[(y * w + x) * c + k])) + 1) * 127.5 }
          }
        }
        let mean = sum / Double(g.rows * g.cell * 3)
        let expected = Double(bit ? watermarkHigh : watermarkLow)
        if abs(mean - expected) > 2.5 {
          matches = false
          return
        }
      }
    }
    return matches
  }

  private static let imageContext = CIContext()

  private static func smoothUpscale(_ image: CGImage, scale: CGFloat) -> CGImage? {
    guard scale > 1 else { return nil }
    let source = CIImage(cgImage: image).clampedToExtent()
    guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
    lanczos.setValue(source, forKey: kCIInputImageKey)
    lanczos.setValue(scale, forKey: kCIInputScaleKey)
    lanczos.setValue(1, forKey: kCIInputAspectRatioKey)
    guard let scaled = lanczos.outputImage else { return nil }
    let blurred = scaled.applyingGaussianBlur(sigma: Double(scale) * 0.7)
    let extent = CGRect(
      x: 0, y: 0, width: (CGFloat(image.width) * scale).rounded(),
      height: (CGFloat(image.height) * scale).rounded())
    return imageContext.createCGImage(blurred.cropped(to: extent), from: extent)
  }

  static func pngData(from tensor: Tensor<FloatType>) -> Data? {
    guard let image = cgImage(from: tensor) else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  static func cgImage(from tensor: Tensor<FloatType>) -> CGImage? {
    let shape = tensor.shape
    guard shape.count >= 3 else { return nil }
    let h = shape[shape.count - 3]
    let w = shape[shape.count - 2]
    let c = shape[shape.count - 1]
    guard h > 0, w > 0, c >= 3 else { return nil }
    var pixels = [UInt8](repeating: 255, count: w * h * 4)

    let first = c == 4 ? 1 : 0
    tensor.withUnsafeBytes { raw in
      guard let p = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for i in 0..<(w * h) {
        for k in 0..<3 {
          let value = (Float(p[i * c + first + k]) + 1) * 127.5
          pixels[i * 4 + k] = UInt8(max(0, min(255, value.rounded())))
        }
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  private static func tensor(from ctx: CGContext, width: Int, height: Int) -> Tensor<FloatType>? {
    guard let data = ctx.data else { return nil }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = ctx.bytesPerRow
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, height, width, 3))
    tensor.withUnsafeMutableBytes { raw in
      guard let fp = raw.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for y in 0..<height {
        for x in 0..<width {
          let base = y * width * 3 + x * 3
          fp[base + 0] = FloatType(bytes[y * bytesPerRow + x * 4 + 0]) * 2 / 255 - 1
          fp[base + 1] = FloatType(bytes[y * bytesPerRow + x * 4 + 1]) * 2 / 255 - 1
          fp[base + 2] = FloatType(bytes[y * bytesPerRow + x * 4 + 2]) * 2 / 255 - 1
        }
      }
    }
    return tensor
  }
}
