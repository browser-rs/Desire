import Foundation

/// 房贷计算（等额本息 / 等额本金）——纯逻辑，进 harness。
nonisolated enum MortgageCore {
    enum Method: String, CaseIterable, Sendable {
        case equalPayment
        case equalPrincipal
    }

    struct Row: Equatable, Sendable {
        var month: Int
        var payment: Double
        var principal: Double
        var interest: Double
        var balance: Double
    }

    struct Result: Equatable, Sendable {
        var months: Int
        /// 等额本息：每月固定还款。
        var monthlyPayment: Double?
        /// 等额本金：首月 / 末月还款。
        var firstPayment: Double?
        var lastPayment: Double?
        var totalPayment: Double
        var totalInterest: Double
        var schedule: [Row]
    }

    /// principal 单位元；annualRate 为百分数（4.9 = 4.9%）。
    static func calculate(principal: Double, annualRate: Double, years: Int,
                          method: Method) -> Result? {
        guard principal > 0, years > 0, years <= 50,
              annualRate >= 0, annualRate <= 100 else { return nil }
        let months = years * 12
        let monthlyRate = annualRate / 100 / 12
        var balance = principal
        var rows: [Row] = []
        var totalPayment = 0.0
        var totalInterest = 0.0

        switch method {
        case .equalPayment:
            let payment: Double
            if monthlyRate == 0 {
                payment = principal / Double(months)
            } else {
                let growth = pow(1 + monthlyRate, Double(months))
                payment = principal * monthlyRate * growth / (growth - 1)
            }
            for month in 1...months {
                let interest = balance * monthlyRate
                var principalPart = payment - interest
                var actualPayment = payment
                if month == months {
                    principalPart = balance
                    actualPayment = principalPart + interest
                }
                balance = max(0, balance - principalPart)
                rows.append(Row(month: month, payment: actualPayment,
                                principal: principalPart, interest: interest, balance: balance))
                totalPayment += actualPayment
                totalInterest += interest
            }
            return Result(months: months, monthlyPayment: payment,
                          firstPayment: nil, lastPayment: nil,
                          totalPayment: totalPayment, totalInterest: totalInterest,
                          schedule: rows)
        case .equalPrincipal:
            let principalPart = principal / Double(months)
            for month in 1...months {
                let interest = balance * monthlyRate
                let actualPrincipal = month == months ? balance : principalPart
                let payment = actualPrincipal + interest
                balance = max(0, balance - actualPrincipal)
                rows.append(Row(month: month, payment: payment,
                                principal: actualPrincipal, interest: interest, balance: balance))
                totalPayment += payment
                totalInterest += interest
            }
            return Result(months: months, monthlyPayment: nil,
                          firstPayment: rows.first?.payment,
                          lastPayment: rows.last?.payment,
                          totalPayment: totalPayment, totalInterest: totalInterest,
                          schedule: rows)
        }
    }
}

/// 存款 / 复利计算——纯逻辑。
nonisolated enum SavingsCore {
    enum Compounding: String, CaseIterable, Sendable {
        case annually
        case quarterly
        case monthly
        case daily
        case simple

        var periodsPerYear: Int? {
            switch self {
            case .annually: return 1
            case .quarterly: return 4
            case .monthly: return 12
            case .daily: return 365
            case .simple: return nil
            }
        }
    }

    struct Result: Equatable, Sendable {
        var finalAmount: Double
        var interest: Double
        var effectiveAnnualRate: Double
        var months: Int
    }

    /// principal 元；annualRate 百分数；years 可小数（按月换算）。
    static func calculate(principal: Double, annualRate: Double, years: Double,
                          compounding: Compounding,
                          monthlyContribution: Double = 0) -> Result? {
        guard principal >= 0, annualRate >= 0, annualRate <= 100, years > 0, years <= 100,
              monthlyContribution >= 0 else { return nil }
        let months = max(1, Int((years * 12).rounded()))
        let rate = annualRate / 100
        var balance = principal
        var principalBase = principal
        var simpleInterest = 0.0

        if compounding == .simple {
            for _ in 0..<months {
                principalBase += monthlyContribution
                simpleInterest += principalBase * rate / 12
            }
            let finalAmount = principalBase + simpleInterest
            return Result(finalAmount: finalAmount,
                          interest: finalAmount - principal - monthlyContribution * Double(months),
                          effectiveAnnualRate: rate,
                          months: months)
        }

        let periods = Double(compounding.periodsPerYear ?? 1)
        let monthlyFactor = pow(1 + rate / periods, periods / 12) - 1
        for _ in 0..<months {
            balance *= (1 + monthlyFactor)
            balance += monthlyContribution
        }
        let contributed = monthlyContribution * Double(months)
        return Result(finalAmount: balance,
                      interest: balance - principal - contributed,
                      effectiveAnnualRate: pow(1 + rate / periods, periods) - 1,
                      months: months)
    }
}

/// 百分比三问——纯逻辑。
nonisolated enum PercentCore {
    static func percentOf(value: Double, percent: Double) -> Double {
        value * percent / 100
    }

    /// part 占 total 的百分比。
    static func ratio(part: Double, of total: Double) -> Double? {
        guard total != 0 else { return nil }
        return part / total * 100
    }

    /// 从 from 到 to 的变化百分比。
    static func change(from: Double, to: Double) -> Double? {
        guard from != 0 else { return nil }
        return (to - from) / abs(from) * 100
    }
}

/// 折扣 / AA 分账——纯逻辑。
nonisolated enum ShoppingCalcCore {
    /// 原价 price 打 percent% 折（percent=88 表示 8.8 折）→ 应付。
    static func discounted(price: Double, percent: Double) -> Double? {
        guard price >= 0, percent >= 0, percent <= 100 else { return nil }
        return price * percent / 100
    }

    /// AA 分账：总额 + 人数 + 小费百分比 → 每人应付。
    static func splitBill(total: Double, people: Int, tipPercent: Double) -> Double? {
        guard total >= 0, people > 0, tipPercent >= 0, tipPercent <= 100 else { return nil }
        return (total * (1 + tipPercent / 100)) / Double(people)
    }
}

/// BMI（中国成人标准：<18.5 偏瘦，18.5–24 正常，24–28 超重，≥28 肥胖）。
nonisolated enum BMICore {
    enum Category: String, Sendable {
        case underweight
        case normal
        case overweight
        case obese
    }

    static func bmi(heightCM: Double, weightKG: Double) -> Double? {
        guard heightCM > 0, weightKG > 0 else { return nil }
        let meters = heightCM / 100
        return weightKG / (meters * meters)
    }

    static func category(for bmi: Double) -> Category {
        switch bmi {
        case ..<18.5: return .underweight
        case ..<24: return .normal
        case ..<28: return .overweight
        default: return .obese
        }
    }
}
