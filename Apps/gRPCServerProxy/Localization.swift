import Foundation

enum Loc {
  static var german = false

  static func t(_ english: String, _ german: String) -> String {
    self.german ? german : english
  }

  static func stepLine(_ step: Int, _ steps: Int, _ percent: Int) -> String {
    german ? "Schritt \(step)/\(steps) (\(percent) %)" : "Step \(step)/\(steps) (\(percent)%)"
  }

  static func left(_ total: Int) -> String {
    if german {
      return total < 60 ? "noch ~\(total) s" : String(format: "noch ~%d min %02d s", total / 60, total % 60)
    }
    return total < 60 ? "~\(total)s left" : String(format: "~%dm %02ds left", total / 60, total % 60)
  }
}
