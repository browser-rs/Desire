import AppKit
import SwiftUI

// 计算类工具（v0.8.27）：房贷 / 存款 / 百分比 / 科学计算器 / BMI /
// 日期计算 / 单位换算。计算全部走 FinanceCalcCore、ExpressionParser、
// DateCalcCore、UnitConvertCore（均有 harness 断言）。

// MARK: - 共用输入

private struct CalcField: View {
    let title: String
    @Binding var text: String
    var suffix: String = ""
    var width: CGFloat = 140

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ResultTile: View {
    let label: String
    let value: String
    var accent: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.07)))
    }
}

private struct CalcSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - 房贷

struct MortgageToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var amountText = "1000000"
    @State private var rateText = "4.9"
    @State private var years = 30
    @State private var method: MortgageCore.Method = .equalPayment
    @State private var showAllSchedule = false

    private var result: MortgageCore.Result? {
        guard let amount = Double(amountText), let rate = Double(rateText) else { return nil }
        return MortgageCore.calculate(principal: amount, annualRate: rate,
                                      years: years, method: method)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Loan")) {
                CalcField(title: String(localized: "Amount"), text: $amountText, suffix: "CNY", width: 160)
                CalcField(title: String(localized: "Annual rate"), text: $rateText, suffix: "%", width: 100)
                HStack(spacing: 6) {
                    Text(String(localized: "Term"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    Stepper(String(localized: "\(years) years"), value: $years, in: 1...50)
                        .font(.system(size: 11.5))
                }
                Picker("", selection: $method) {
                    Text(String(localized: "Equal payment")).tag(MortgageCore.Method.equalPayment)
                    Text(String(localized: "Equal principal")).tag(MortgageCore.Method.equalPrincipal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            if let result {
                HStack(spacing: 10) {
                    if let monthly = result.monthlyPayment {
                        ResultTile(label: String(localized: "Monthly payment"),
                                   value: ToolFormat.money(monthly), accent: appAccent)
                    } else {
                        ResultTile(label: String(localized: "First payment"),
                                   value: ToolFormat.money(result.firstPayment ?? 0), accent: appAccent)
                        ResultTile(label: String(localized: "Last payment"),
                                   value: ToolFormat.money(result.lastPayment ?? 0))
                    }
                    ResultTile(label: String(localized: "Total interest"),
                               value: ToolFormat.money(result.totalInterest))
                    ResultTile(label: String(localized: "Total payment"),
                               value: ToolFormat.money(result.totalPayment))
                    ResultTile(label: String(localized: "Months"),
                               value: "\(result.months)")
                }

                CalcSection(title: String(localized: "Amortization")) {
                    scheduleHeader
                    ForEach(result.schedule.prefix(showAllSchedule ? result.schedule.count : 12),
                            id: \.month) { row in
                        scheduleRow(row)
                    }
                    if result.schedule.count > 12 {
                        Button(showAllSchedule
                               ? String(localized: "Show first 12 rows")
                               : String(localized: "Show all \(result.schedule.count) rows")) {
                            showAllSchedule.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(appAccent)
                    }
                }
            } else {
                ToolErrorText(text: String(localized: "Enter a valid amount, rate and term"))
            }
        }
    }

    private var scheduleHeader: some View {
        HStack(spacing: 0) {
            scheduleCell(String(localized: "Month"), width: 52, header: true)
            scheduleCell(String(localized: "Payment"), header: true)
            scheduleCell(String(localized: "Principal"), header: true)
            scheduleCell(String(localized: "Interest"), header: true)
            scheduleCell(String(localized: "Balance"), header: true)
        }
    }

    private func scheduleRow(_ row: MortgageCore.Row) -> some View {
        HStack(spacing: 0) {
            scheduleCell("\(row.month)", width: 52)
            scheduleCell(ToolFormat.money(row.payment))
            scheduleCell(ToolFormat.money(row.principal))
            scheduleCell(ToolFormat.money(row.interest))
            scheduleCell(ToolFormat.money(row.balance))
        }
        .padding(.vertical, 1)
    }

    private func scheduleCell(_ text: String, width: CGFloat? = nil, header: Bool = false) -> some View {
        Text(text)
            .font(.system(size: header ? 9.5 : 10, weight: header ? .semibold : .regular,
                          design: .monospaced))
            .foregroundStyle(header ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: width, alignment: header || width != nil ? .leading : .trailing)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .trailing)
    }
}

// MARK: - 存款

struct SavingsToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var principalText = "100000"
    @State private var rateText = "3.0"
    @State private var yearsText = "3"
    @State private var contributionText = "0"
    @State private var compounding: SavingsCore.Compounding = .annually

    private var result: SavingsCore.Result? {
        guard let principal = Double(principalText), let rate = Double(rateText),
              let years = Double(yearsText), let contribution = Double(contributionText) else {
            return nil
        }
        return SavingsCore.calculate(principal: principal, annualRate: rate, years: years,
                                     compounding: compounding,
                                     monthlyContribution: contribution)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Deposit")) {
                CalcField(title: String(localized: "Principal"), text: $principalText, suffix: "CNY", width: 160)
                CalcField(title: String(localized: "Annual rate"), text: $rateText, suffix: "%", width: 100)
                CalcField(title: String(localized: "Years"), text: $yearsText, suffix: String(localized: "years"), width: 100)
                CalcField(title: String(localized: "Monthly deposit"), text: $contributionText, suffix: "CNY", width: 140)
                HStack(spacing: 6) {
                    Text(String(localized: "Compounding"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    Picker("", selection: $compounding) {
                        Text(String(localized: "Annual")).tag(SavingsCore.Compounding.annually)
                        Text(String(localized: "Quarterly")).tag(SavingsCore.Compounding.quarterly)
                        Text(String(localized: "Monthly")).tag(SavingsCore.Compounding.monthly)
                        Text(String(localized: "Daily")).tag(SavingsCore.Compounding.daily)
                        Text(String(localized: "Simple")).tag(SavingsCore.Compounding.simple)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                }
            }
            if let result {
                HStack(spacing: 10) {
                    ResultTile(label: String(localized: "Final amount"),
                               value: ToolFormat.money(result.finalAmount), accent: appAccent)
                    ResultTile(label: String(localized: "Interest"),
                               value: ToolFormat.money(result.interest))
                    ResultTile(label: String(localized: "Effective annual rate"),
                               value: ToolFormat.percent(result.effectiveAnnualRate * 100))
                }
                Text(String(localized: "Compounded over \(result.months) month(s); contributions are added at month end."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ToolErrorText(text: String(localized: "Enter valid numbers"))
            }
        }
    }
}

// MARK: - 百分比

struct PercentToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var percentText = "20"
    @State private var baseText = "150"
    @State private var partText = "30"
    @State private var totalText = "150"
    @State private var fromText = "100"
    @State private var toText = "120"

    private var percentOfValue: Double? {
        guard let percent = Double(percentText), let base = Double(baseText) else { return nil }
        return PercentCore.percentOf(value: base, percent: percent)
    }

    private var ratioValue: Double? {
        guard let part = Double(partText), let total = Double(totalText) else { return nil }
        return PercentCore.ratio(part: part, of: total)
    }

    private var changeValue: Double? {
        guard let from = Double(fromText), let to = Double(toText) else { return nil }
        return PercentCore.change(from: from, to: to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Percent of a value")) {
                HStack(spacing: 6) {
                    TextField("20", text: $percentText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80)
                    Text("% ×").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("150", text: $baseText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 120)
                    Text("=").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(percentOfValue.map { ToolFormat.compact($0) } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(appAccent)
                }
            }
            CalcSection(title: String(localized: "Ratio")) {
                HStack(spacing: 6) {
                    TextField("30", text: $partText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 100)
                    Text(String(localized: "is what percent of"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("150", text: $totalText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 120)
                    Text(ratioValue.map { ToolFormat.percent($0) } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(appAccent)
                }
            }
            CalcSection(title: String(localized: "Percentage change")) {
                HStack(spacing: 6) {
                    TextField("100", text: $fromText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 110)
                    Text("→").foregroundStyle(.secondary)
                    TextField("120", text: $toText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 110)
                    Text(changeValue.map { ($0 >= 0 ? "+" : "") + ToolFormat.percent($0) } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle((changeValue ?? 0) >= 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
                }
            }
        }
    }
}

// MARK: - 科学计算器

struct ScientificToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var expression = "1 + 2 * 3"
    @State private var result = ""
    @State private var error: String?
    @State private var history: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Expression")) {
                HStack(spacing: 8) {
                    TextField("1 + 2 * 3", text: $expression)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, design: .monospaced))
                        .onSubmit { evaluate() }
                    Button(String(localized: "Calculate")) { evaluate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button {
                        expression = ""
                        result = ""
                        error = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(["π", "e", "sqrt(", "sin(", "cos(", "ln(", "^", "(", ")", "%"], id: \.self) { token in
                        Button(token) {
                            expression += token == "π" ? "pi" : token
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                if let error {
                    ToolErrorText(text: error)
                } else if !result.isEmpty {
                    HStack(spacing: 6) {
                        Text("=")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(result)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(appAccent)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            if !history.isEmpty {
                CalcSection(title: String(localized: "History")) {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                        Button {
                            expression = entry.components(separatedBy: " = ").first ?? entry
                        } label: {
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func evaluate() {
        switch ExpressionParser.evaluate(expression) {
        case .success(let value):
            error = nil
            result = ToolFormat.compact(value, maxFraction: 10)
            let entry = "\(expression) = \(result)"
            history.removeAll { $0 == entry }
            history.insert(entry, at: 0)
            history = Array(history.prefix(8))
        case .failure(let failure):
            result = ""
            error = failure.message
        }
    }
}

// MARK: - BMI

struct BMIToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var heightText = "175"
    @State private var weightText = "70"

    private var bmi: Double? {
        guard let height = Double(heightText), let weight = Double(weightText) else { return nil }
        return BMICore.bmi(heightCM: height, weightKG: weight)
    }

    private var category: BMICore.Category? {
        bmi.map(BMICore.category(for:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Body")) {
                CalcField(title: String(localized: "Height"), text: $heightText, suffix: "cm", width: 100)
                CalcField(title: String(localized: "Body weight"), text: $weightText, suffix: "kg", width: 100)
            }
            if let bmi, let category {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%.1f", bmi))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(categoryColor(category))
                    Text(categoryTitle(category))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(categoryColor(category))
                    Text("kg/m²")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                bmiBar(bmi)
            } else {
                ToolErrorText(text: String(localized: "Enter height and weight"))
            }
        }
    }

    private func bmiBar(_ bmi: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let clamped = min(max(bmi, 15), 35)
                let fraction = (clamped - 15) / 20
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.blue.opacity(0.35))
                        RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.40))
                        RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.45))
                        RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.45))
                    }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                        .offset(x: geo.size.width * fraction - 5)
                }
            }
            .frame(height: 10)
            HStack {
                Text("18.5").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Text("24").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
                Text("28").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 420)
    }

    private func categoryTitle(_ category: BMICore.Category) -> String {
        switch category {
        case .underweight: return String(localized: "Underweight")
        case .normal: return String(localized: "Normal")
        case .overweight: return String(localized: "Overweight")
        case .obese: return String(localized: "Obese")
        }
    }

    private func categoryColor(_ category: BMICore.Category) -> Color {
        switch category {
        case .underweight: return .blue
        case .normal: return .green
        case .overweight: return .orange
        case .obese: return .red
        }
    }
}

// MARK: - 日期

struct DateToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var baseDate = Date()
    @State private var amount = 30
    @State private var unit: DateCalcCore.Component = .days

    private var difference: DateCalcCore.Difference {
        DateCalcCore.difference(from: startDate, to: endDate)
    }

    private var breakdown: (years: Int, months: Int, days: Int) {
        DateCalcCore.breakdown(from: startDate, to: endDate)
    }

    private var addedDate: Date? {
        DateCalcCore.add(amount, unit: unit, to: baseDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Between two dates")) {
                HStack(spacing: 10) {
                    DatePicker("", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                    Text("→").foregroundStyle(.secondary)
                    DatePicker("", selection: $endDate, displayedComponents: .date)
                        .labelsHidden()
                }
                let diff = difference
                HStack(spacing: 10) {
                    ResultTile(label: String(localized: "Days"), value: "\(diff.days)", accent: appAccent)
                    ResultTile(label: String(localized: "Weeks"), value: "\(diff.weeks)")
                    ResultTile(label: String(localized: "Business days"), value: "\(diff.businessDays)")
                    ResultTile(label: String(localized: "Breakdown"),
                               value: "\(breakdown.years)y \(breakdown.months)m \(breakdown.days)d")
                }
            }
            CalcSection(title: String(localized: "Add or subtract")) {
                HStack(spacing: 8) {
                    DatePicker("", selection: $baseDate, displayedComponents: .date)
                        .labelsHidden()
                    TextField("", value: $amount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(size: 12, design: .monospaced))
                    Picker("", selection: $unit) {
                        Text(String(localized: "Days")).tag(DateCalcCore.Component.days)
                        Text(String(localized: "Weeks")).tag(DateCalcCore.Component.weeks)
                        Text(String(localized: "Months")).tag(DateCalcCore.Component.months)
                        Text(String(localized: "Years")).tag(DateCalcCore.Component.years)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    if let addedDate {
                        Text(addedDate.formatted(date: .long, time: .omitted))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(appAccent)
                    }
                }
            }
        }
    }
}

// MARK: - 单位换算

struct UnitsToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var category: UnitConvertCore.Category = .length
    @State private var valueText = "1"
    @State private var fromID = "m"
    @State private var toID = "km"

    private var units: [UnitConvertCore.Unit] { UnitConvertCore.units(for: category) }

    private var converted: Double? {
        guard let value = Double(valueText) else { return nil }
        return UnitConvertCore.convert(value, from: fromID, to: toID, category: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalcSection(title: String(localized: "Category")) {
                Picker("", selection: $category) {
                    Text(String(localized: "Length")).tag(UnitConvertCore.Category.length)
                    Text(String(localized: "Weight")).tag(UnitConvertCore.Category.weight)
                    Text(String(localized: "Temperature")).tag(UnitConvertCore.Category.temperature)
                    Text(String(localized: "Area")).tag(UnitConvertCore.Category.area)
                    Text(String(localized: "Volume")).tag(UnitConvertCore.Category.volume)
                    Text(String(localized: "Speed")).tag(UnitConvertCore.Category.speed)
                    Text(String(localized: "Data")).tag(UnitConvertCore.Category.data)
                    Text(String(localized: "Time")).tag(UnitConvertCore.Category.time)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: category) { _, _ in resetUnits() }
            }
            CalcSection(title: String(localized: "Convert")) {
                HStack(spacing: 8) {
                    TextField("1", text: $valueText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(width: 120)
                    Picker("", selection: $fromID) {
                        ForEach(units) { unit in
                            Text(unit.symbol).tag(unit.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Button {
                        swap(&fromID, &toID)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Picker("", selection: $toID) {
                        ForEach(units) { unit in
                            Text(unit.symbol).tag(unit.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                HStack(spacing: 6) {
                    Text(converted.map { ToolFormat.compact($0, maxFraction: 8) } ?? "—")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(appAccent)
                        .textSelection(.enabled)
                    Text(unitSymbol(toID))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if category == .data {
                    Text(String(localized: "Uses 1024-based units (1 KB = 1024 B)."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if category == .time {
                    Text(String(localized: "Month = 30 days, year = 365 days."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear(perform: resetUnits)
    }

    private func resetUnits() {
        let available = units
        if !available.contains(where: { $0.id == fromID }) {
            fromID = available.first?.id ?? fromID
        }
        if !available.contains(where: { $0.id == toID }) || toID == fromID {
            toID = available.dropFirst().first?.id ?? toID
        }
    }

    private func unitSymbol(_ id: String) -> String {
        units.first(where: { $0.id == id })?.symbol ?? ""
    }
}
