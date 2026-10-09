import Foundation
import XCTest
@testable import HomeostatShared

/// Daily_loop_contract.md "State and interaction rules", one case per state.
final class DailySummaryTests: XCTestCase {
    func facts(sleep: String = "typical", recovery: String = "typical", movement: String = "typical",
               days: [String: Int] = ["sleep": 20, "hrv": 20, "rhr": 20, "movement": 20],
               measures: [DisplayFacts.Measure] = []) -> DisplayFacts {
        DisplayFacts(sleep: .init(state: sleep, confidence: 1), recovery: .init(state: recovery, confidence: 1),
                     movement: .init(state: movement, confidence: 1), workout: .init(state: "none_recent", confidence: 1),
                     measures: measures, learningDays: days, requiredDays: 14)
    }

    func measure(_ domain: String, _ value: Double, usual: Double) -> DisplayFacts.Measure {
        .init(id: domain, domain: domain, value: value, baseline: usual, unit: nil, observedAt: NOW, confidence: 1)
    }

    func cache(trait: String, headline: String, detail: String? = nil, explainable: Bool = true,
               facts: DisplayFacts?) -> WidgetCache {
        let state = WidgetState(effectiveAt: NOW, presentation: .init(icon: "•", headline: headline, detail: detail),
                                primaryTrait: .init(id: trait, explainable: explainable),
                                freshness: .init(lastUpdatedAt: NOW))
        return WidgetCache(scope: "a", day: CHICAGO.day(of: NOW), inputRevision: 1, runID: 1, widgetState: state,
                           facts: facts)
    }

    func testNoDataAndUnreadable() {
        let empty = DailySummary.make(.empty)
        XCTAssertEqual(empty.kind, .waiting)
        XCTAssertEqual(empty.action, .openDataAccess)
        XCTAssertEqual(DailySummary.make(.unreadable(.unavailable)).kind, .unavailable)
    }

    func testAnEarlierDayDropsTodaysInterpretationAndReport() {
        let report = ReportedEnergy(level: .low, at: NOW, status: .saved)
        let summary = DailySummary.make(.earlierDay(cache(trait: "sleep", headline: "Shorter sleep", facts: facts())),
                                        report: report)
        XCTAssertEqual(summary.kind, .earlierDay)
        XCTAssertEqual(summary.headline, "Last result is from an earlier day")
        XCTAssertNil(summary.report)
        XCTAssertEqual(summary.updatedAt, NOW)
    }

    func testASleepChangeComparesWithTheUsualAndOpensItsEvidence() {
        let summary = DailySummary.make(.fresh(cache(
            trait: "sleep", headline: "Shorter sleep", detail: "5h 30m",
            facts: facts(sleep: "below_baseline", measures: [measure("sleep", 5.5, usual: 7.5)]))))
        XCTAssertEqual(summary.kind, .change)
        XCTAssertEqual(summary.headline, "Shorter sleep")
        XCTAssertEqual(summary.comparison, "5h 30m · usually 7h 30m")
        XCTAssertEqual(summary.evidence, "sleep")
        XCTAssertEqual(summary.action, .openEvidence)
    }

    func testStepsAreDescribedAsStepsNotActivity() {
        let summary = DailySummary.make(.fresh(cache(
            trait: "movement", headline: "Less active than usual",
            facts: facts(movement: "behind_usual", measures: [measure("movement", 4200, usual: 6000)]))))
        XCTAssertEqual(summary.headline, "Fewer steps than usual by this time")
        XCTAssertEqual(summary.comparison, "4,200 steps · usually 6,000 by now")
    }

    /// The real-data audit: global calibration hid a ready, typical movement domain.
    func testAReadyDomainIsNotHiddenByAnotherThatIsStillLearning() {
        let summary = DailySummary.make(.fresh(cache(
            trait: "calibration", headline: "Learning your baseline", explainable: false,
            facts: facts(days: ["sleep": 3, "hrv": 2, "rhr": 2, "movement": 20]))))
        XCTAssertEqual(summary.kind, .quiet)
        XCTAssertEqual(summary.headline, "Within your usual range")
        XCTAssertEqual(summary.comparison, "Steps as usual")  // only the ready domain is named
        XCTAssertEqual(summary.domains.map(\.readiness), [.learning(usable: 3, required: 14),
                                                          .learning(usable: 2, required: 14), .ready])
        XCTAssertEqual(summary.action, .openApp)
    }

    func testEverythingLearningShowsProgressWithoutAComparison() {
        let summary = DailySummary.make(.fresh(cache(
            trait: "calibration", headline: "Learning your baseline", explainable: false,
            facts: facts(days: ["sleep": 5, "hrv": 4, "rhr": 6, "movement": 5]))))
        XCTAssertEqual(summary.kind, .learning)
        XCTAssertEqual(summary.headline, "Getting to know your usual")
        XCTAssertNil(summary.comparison)
        XCTAssertEqual(summary.domains[1].readiness, .learning(usable: 6, required: 14))  // best of HRV / resting HR
    }

    func testNoEvidenceAtAllIsWaitingNotQuiet() {
        let summary = DailySummary.make(.fresh(cache(
            trait: "no_data", headline: "Waiting for new data", explainable: false,
            facts: facts(sleep: "calibrating", recovery: "calibrating", movement: "calibrating",
                         days: ["sleep": 0, "hrv": 0, "rhr": 0, "movement": 0]))))
        XCTAssertEqual(summary.kind, .waiting)
    }

    func testAReadyDomainWithNoValueTodayIsMissingNotTypical() {
        let summary = DailySummary.make(.fresh(cache(trait: "typical", headline: "Typical day",
                                                     facts: facts(sleep: "missing"))))
        XCTAssertEqual(summary.domains.first?.readiness, .missing)
        XCTAssertEqual(summary.comparison, "Recovery and steps as usual")  // sleep isn't claimed
    }

    func testStaleKeepsTheResultAndSaysSo() {
        let summary = DailySummary.make(.stale(cache(trait: "sleep", headline: "Shorter sleep",
                                                     facts: facts(sleep: "below_baseline"))))
        XCTAssertTrue(summary.isStale)
        XCTAssertEqual(summary.kind, .change)
        XCTAssertEqual(summary.updatedAt, NOW)
    }

    func testAReportSitsBesideTheMeasurementNeverInsteadOfIt() {
        let report = ReportedEnergy(level: .high, at: NOW, status: .saving)
        let summary = DailySummary.make(.fresh(cache(trait: "sleep", headline: "Shorter sleep",
                                                     facts: facts(sleep: "below_baseline"))), report: report)
        XCTAssertEqual(summary.headline, "Shorter sleep")
        XCTAssertEqual(summary.report, report)
    }

    func testACacheFromBeforeFactsShowsTheMappersWords() {
        let summary = DailySummary.make(.fresh(cache(trait: "calibration", headline: "Learning your baseline",
                                                     detail: "3 / 14 usable days", explainable: false, facts: nil)))
        XCTAssertEqual(summary.kind, .learning)
        XCTAssertEqual(summary.headline, "Learning your baseline")
        XCTAssertEqual(summary.comparison, "3 / 14 usable days")
    }
}
