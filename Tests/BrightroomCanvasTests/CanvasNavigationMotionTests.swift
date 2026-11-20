import CoreGraphics
import Foundation
import SwiftUI
import Testing

#if os(iOS)
import UIKit
#endif

@testable import BrightroomUI

/// The motions of `CanvasNavigation` against the formulas they implement: a
/// scroll view's deceleration, a critically damped spring, and the rubber
/// band's slope.
@Suite("Canvas navigation motion")
struct CanvasNavigationMotionTests {

  /// The change per second of the logarithm of a deceleration's velocity at
  /// the normal rate, which keeps 0.998 of the velocity each millisecond.
  private static let decay = 1000 * log(0.998)

  /// The angular frequency of the bounce spring: the square root of its
  /// stiffness, 100, over its mass, 1.
  private static let bounceFrequency = 10.0

  /// The angular frequency of the settling spring: a response of 0.4 s.
  private static let settleFrequency = 2 * Double.pi / 0.4

  /// 4000 x 3000 content in an 800 x 800 canvas, as in
  /// `CanvasNavigationTests`.
  private static let content = CGSize(width: 4000, height: 3000)
  private static let canvas = CGSize(width: 800, height: 800)
  private static let canvasCenter = CGPoint(x: 400, y: 400)

  /// Zoomed to twice the fit about the canvas centre. With the default
  /// sizes that is 0.4 at (2000, 1500), and the centre may then range over
  /// 1000...3000 horizontally and 1000...2000 vertically. A gesture that
  /// moved nothing has opened and closed, so the momentum that follows is
  /// not that of the zoom step.
  private func makeZoomedModel(
    content: CGSize = content,
    canvas: CGSize = canvas
  ) -> CanvasNavigation {
    var model = CanvasNavigation(contentSize: content, canvasSize: canvas)
    model.handle(
      .zoomStep(factor: 2, anchor: CGPoint(x: canvas.width / 2, y: canvas.height / 2)),
      at: 0
    )
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: nil), at: 0)
    return model
  }

  private func isClose(_ lhs: CGFloat, _ rhs: Double, tolerance: Double = 1e-6) -> Bool {
    abs(Double(lhs) - rhs) <= tolerance * max(1, abs(rhs))
  }

  /// How far from its rest a critically damped spring of angular frequency
  /// `frequency` is `elapsed` seconds after it was `distance` away and moving
  /// away at `speed`.
  private func springDistance(
    from distance: Double,
    speed: Double,
    frequency: Double,
    after elapsed: Double
  ) -> Double {
    exp(-frequency * elapsed) * (distance + (speed + frequency * distance) * elapsed)
  }

  /// The farthest from its rest that spring gets when it moves away:
  /// `springDistance` at `speed / (frequency (speed + frequency distance))`.
  private func springPeak(from distance: Double, speed: Double, frequency: Double) -> Double {
    let rate = speed + frequency * distance
    return rate / frequency * exp(-speed / rate)
  }

  /// How far past its rest that spring gets when it comes in at `speed`,
  /// faster than `frequency * distance`: `springDistance` a period of
  /// `1 / frequency` after it passes its rest.
  private func springPass(from distance: Double, speed: Double, frequency: Double) -> Double {
    let rate = speed - frequency * distance
    return rate / frequency * exp(-1 - frequency * distance / rate)
  }

  /// The last moment that spring is more than `tolerance` from its rest.
  private func settleTime(
    from distance: Double,
    speed: Double,
    frequency: Double,
    within tolerance: Double
  ) -> Double {
    var time = 10.0
    while time > 0,
      abs(springDistance(from: distance, speed: speed, frequency: frequency, after: time))
        <= tolerance
    {
      time -= 0.0001
    }
    return time
  }

  /// What a rubber band over 800 points shows of a pull of `pull` points:
  /// `(1 - 1 / (0.55 pull / 800 + 1)) 800`.
  private func rubberBand(_ pull: Double) -> Double {
    (1 - 1 / (pull * 0.55 / 800 + 1)) * 800
  }

  // MARK: - Constants

  @Test("The springs are critically damped, the bounce softer than the settle")
  func springs() {
    #expect(CanvasNavigation.bounceSpring.dampingRatio == 1)
    #expect(CanvasNavigation.settleSpring.dampingRatio == 1)
    #expect(abs(CanvasNavigation.bounceSpring.stiffness - 100) < 1e-9)
    #expect(abs(CanvasNavigation.bounceSpring.mass - 1) < 1e-12)
    #expect(abs(CanvasNavigation.settleSpring.response - 0.4) < 1e-12)
    #expect(CanvasNavigation.bounceSpring.stiffness < CanvasNavigation.settleSpring.stiffness)
  }

  @Test("The deceleration rate is a share of the velocity, and nothing else is taken")
  func decelerationRateTakesOnlyShares() {
    var model = CanvasNavigation(contentSize: Self.content, canvasSize: Self.canvas)
    #expect(model.decelerationRate == 0.998)

    for rate: CGFloat in [.nan, .infinity, 0, 1, 1.5, -0.5] {
      model.decelerationRate = rate
      #expect(model.decelerationRate == 0.998)
    }
    // A value that is not a number would make the model unequal to itself.
    #expect(model == model)

    model.decelerationRate = 0.99
    #expect(model.decelerationRate == 0.99)
  }

  #if os(iOS)
  @Test("The content decelerates at a scroll view's normal rate")
  func decelerationRateIsUIKitNormal() {
    let model = CanvasNavigation(contentSize: Self.content, canvasSize: Self.canvas)
    #expect(model.decelerationRate == UIScrollView.DecelerationRate.normal.rawValue)
  }
  #endif

  // MARK: - Deceleration

  @Test("A deceleration keeps 0.998 of its velocity each millisecond")
  func decelerationFollowsFormula() throws {
    let deceleration = try #require(
      CanvasNavigation.Deceleration(
        start: 100, velocity: 1000, startTime: 5,
        rate: 0.998, endDistance: 0.5, limits: -1e6...1e6
      )
    )

    for elapsed in [0, 0.001, 0.016, 0.1, 0.5, 1, 2, 3] {
      let kept = pow(0.998, 1000 * elapsed)
      #expect(isClose(deceleration.velocity(at: 5 + elapsed), 1000 * kept))
      // The velocity integrated from the start.
      #expect(isClose(deceleration.value(at: 5 + elapsed), 100 + 1000 * (kept - 1) / Self.decay))
    }

    // It approaches the start plus the velocity over the decay, which the
    // projection Apple gives for a scroll view, (v / 1000) d / (1 - d),
    // approximates.
    #expect(isClose(deceleration.destination, 100 - 1000 / Self.decay))
    let projection = 100 + (1000.0 / 1000) * 0.998 / (1 - 0.998)
    #expect(abs(Double(deceleration.destination) - projection) < 0.002 * 500)

    // It ends half a point short of that, and stays there.
    let end = deceleration.endTime
    #expect(isClose(CGFloat(end), 5 + log(-Self.decay * 0.5 / 1000) / Self.decay))
    #expect(isClose(deceleration.destination - deceleration.value(at: end), 0.5))
    #expect(deceleration.sample(at: end - 0.001).isFinished == false)
    #expect(deceleration.sample(at: end).isFinished)
    #expect(deceleration.sample(at: end).velocity == 0)
    #expect(deceleration.value(at: end + 10) == deceleration.value(at: end))

    // Before its start it is where it starts.
    #expect(deceleration.value(at: 4) == 100)
    #expect(deceleration.velocity(at: 4) == 1000)
  }

  @Test("A deceleration tells when it reaches a value on its way")
  func decelerationReachesValues() throws {
    let deceleration = try #require(
      CanvasNavigation.Deceleration(
        start: 100, velocity: -1000, startTime: 0,
        rate: 0.998, endDistance: 0.5, limits: -1e6...1e6
      )
    )
    for target: CGFloat in [100, 50, -100, -390] {
      let time = try #require(deceleration.time(reaching: target))
      #expect(isClose(deceleration.value(at: time), Double(target)))
    }
    // Behind the start, at the destination, and past it.
    #expect(deceleration.time(reaching: 101) == nil)
    #expect(deceleration.time(reaching: deceleration.destination) == nil)
    #expect(deceleration.time(reaching: -1000) == nil)
  }

  @Test("A velocity that carries nowhere gives no deceleration")
  func decelerationNeedsVelocity() {
    func make(_ velocity: CGFloat, rate: CGFloat = 0.998) -> CanvasNavigation.Deceleration? {
      CanvasNavigation.Deceleration(
        start: 0, velocity: velocity, startTime: 0,
        rate: rate, endDistance: 0.5, limits: -1e6...1e6
      )
    }
    #expect(make(0) == nil)
    // Under a point per second the whole way is under half a point.
    #expect(make(0.9) == nil)
    #expect(make(-0.9) == nil)
    #expect(make(1.1) != nil)
    #expect(make(.nan) == nil)
    #expect(make(.infinity) == nil)
    #expect(make(500, rate: 1) == nil)
    #expect(make(500, rate: 0) == nil)
  }

  @Test("A deceleration stays within its limits")
  func decelerationStaysWithinLimits() throws {
    // The destination is 1 past the limit at 300, so the motion would end
    // half a point past it.
    let deceleration = try #require(
      CanvasNavigation.Deceleration(
        start: 0, velocity: CGFloat(301 * -Self.decay), startTime: 0,
        rate: 0.998, endDistance: 0.5, limits: -1000...300
      )
    )
    #expect(isClose(deceleration.destination, 301))
    for time in stride(from: 0.0, through: 12, by: 0.25) {
      #expect(deceleration.value(at: time) <= 300)
    }
    #expect(deceleration.value(at: deceleration.endTime) == 300)
    #expect(deceleration.value(at: 100) == 300)
  }

  // MARK: - Spring

  @Test("A spring back is a critically damped spring that starts with a velocity")
  func springBackFollowsClosedForm() {
    let spring = CanvasNavigation.SpringBack(
      base: CanvasNavigation.bounceSpring,
      rest: 300, start: 350, velocity: 800, startTime: 2, tolerance: 0.25
    )
    #expect(spring.spring == CanvasNavigation.bounceSpring)

    for elapsed in [0, 0.01, 0.05, 0.1, 0.3, 0.6] {
      let distance = springDistance(
        from: 50, speed: 800, frequency: Self.bounceFrequency, after: elapsed
      )
      #expect(isClose(spring.value(at: 2 + elapsed), 300 + distance))
    }
    #expect(isClose(spring.velocity(at: 2), 800))

    // Before its start it is where it starts.
    #expect(spring.value(at: 1) == 350)
    #expect(spring.sample(at: 1).isFinished == false)

    // It ends within its tolerance of the rest, and is exactly there after.
    #expect(spring.endTime > 2)
    #expect(abs(spring.value(at: spring.endTime - 1e-9) - 300) < 0.25)
    #expect(spring.sample(at: spring.endTime - 1e-9).isFinished == false)
    #expect(spring.sample(at: spring.endTime) == .init(value: 300, velocity: 0, isFinished: true))
    #expect(spring.value(at: 1e9) == 300)
  }

  @Test("A spring that leaves its rest at speed peaks v / (b e) away, 1 / b seconds later")
  func springBackFromRestPeaks() {
    for speed: Double in [-4000, -300, 1000, 4000] {
      let spring = CanvasNavigation.SpringBack(
        base: CanvasNavigation.bounceSpring,
        rest: 300, start: 300, velocity: CGFloat(speed), startTime: 0, tolerance: 0.25
      )
      let peak = speed / (Self.bounceFrequency * M_E)
      #expect(isClose(spring.value(at: 1 / Self.bounceFrequency), 300 + peak))
      // Nowhere farther.
      for time in stride(from: 0.0, through: 1, by: 0.004) {
        #expect(abs(Double(spring.value(at: time)) - 300) <= abs(peak) + 1e-9)
      }
      #expect(isClose(spring.velocity(at: 1 / Self.bounceFrequency), 0, tolerance: 1e-9))
    }
  }

  @Test("A motion too fast for the spring gets a stiffer one, keeping its velocity")
  func springBackBoundsOvershoot() {
    func farthest(_ spring: CanvasNavigation.SpringBack) -> Double {
      stride(from: 0.0, through: 2, by: 0.0002)
        .map { Double(abs(spring.value(at: $0) - spring.rest)) }
        .max() ?? 0
    }
    func frequency(of spring: CanvasNavigation.SpringBack) -> Double {
      2 * .pi / spring.spring.response
    }

    // From the rest at 20 000 per second the bounce spring would go
    // 20 000 / (10 e) = 736 away. With a reach of 800 it may go half of
    // that, so the spring is the one that peaks exactly at 400.
    let fast = CanvasNavigation.SpringBack(
      base: CanvasNavigation.bounceSpring,
      rest: 0, start: 0, velocity: 20_000, startTime: 0, tolerance: 0.25,
      reach: 800
    )
    #expect(fast.velocity == 20_000)
    #expect(isClose(fast.velocity(at: 0), 20_000))
    #expect(fast.spring.dampingRatio == 1)
    #expect(isClose(CGFloat(frequency(of: fast)), 20_000 / (400 * M_E)))
    #expect(abs(farthest(fast) - 400) < 0.01)

    // A motion the spring holds within the bound keeps the spring.
    let slow = CanvasNavigation.SpringBack(
      base: CanvasNavigation.bounceSpring,
      rest: 0, start: 0, velocity: -4000, startTime: 0, tolerance: 0.25,
      reach: 800
    )
    #expect(slow.spring == CanvasNavigation.bounceSpring)

    // Starting 100 out, 700 of the reach are left, and it may go half of
    // them farther: the spring is the one that would peak 350 farther had
    // it started at its rest.
    let displaced = CanvasNavigation.SpringBack(
      base: CanvasNavigation.settleSpring,
      rest: 0, start: -100, velocity: -20_000, startTime: 0, tolerance: 0.25,
      reach: 800
    )
    #expect(displaced.velocity == -20_000)
    #expect(isClose(CGFloat(frequency(of: displaced)), 20_000 / (350 * M_E)))
    // That is 425 from its rest: past half the reach, short of 100 + 350.
    let displacedPeak = springPeak(from: 100, speed: 20_000, frequency: 20_000 / (350 * M_E))
    #expect(abs(farthest(displaced) - displacedPeak) < 0.01)

    // How far out it starts changes the room little by little: nothing
    // special happens at half the reach, and a velocity the spring holds
    // within the room keeps the spring all the way out.
    for start: CGFloat in [0, 200, 399, 400, 401, 600, 780] {
      let steady = CanvasNavigation.SpringBack(
        base: CanvasNavigation.settleSpring,
        rest: 0, start: start, velocity: 300, startTime: 0, tolerance: 0.25,
        reach: 800
      )
      #expect(steady.spring == CanvasNavigation.settleSpring)
      #expect(steady.velocity == 300)
    }

    // Starting at the reach or beyond, it keeps no speed outward and only
    // comes back.
    for start: CGFloat in [800, 900] {
      let beyond = CanvasNavigation.SpringBack(
        base: CanvasNavigation.settleSpring,
        rest: 0, start: start, velocity: 1000, startTime: 0, tolerance: 0.25,
        reach: 800
      )
      #expect(beyond.velocity == 0)
      #expect(farthest(beyond) == Double(start))
    }

    // Coming in so fast that it would pass its rest by more than half the
    // reach, it is held to that on the far side.
    let inward = CanvasNavigation.SpringBack(
      base: CanvasNavigation.settleSpring,
      rest: 0, start: 100, velocity: -50_000, startTime: 0, tolerance: 0.25,
      reach: 800
    )
    #expect(inward.velocity == -50_000)
    #expect(isClose(CGFloat(frequency(of: inward)), 50_000 / (400 * M_E)))
    let passed = stride(from: 0.0, through: 2, by: 0.0002)
      .map { -Double(inward.value(at: $0)) }
      .max() ?? 0
    // It passes its rest by 328: starting 100 out takes some of the 400 off.
    let inwardPass = springPass(from: 100, speed: 50_000, frequency: 50_000 / (400 * M_E))
    #expect(abs(passed - inwardPass) < 0.01)

    // Coming in slowly enough, it keeps the spring.
    let gentle = CanvasNavigation.SpringBack(
      base: CanvasNavigation.settleSpring,
      rest: 0, start: 100, velocity: -5000, startTime: 0, tolerance: 0.25,
      reach: 800
    )
    #expect(gentle.spring == CanvasNavigation.settleSpring)

    // A velocity that is not a number counts as none.
    let broken = CanvasNavigation.SpringBack(
      base: CanvasNavigation.settleSpring,
      rest: 0, start: 100, velocity: .nan, startTime: 0, tolerance: 0.25
    )
    #expect(broken.velocity == 0)
    #expect(broken.value(at: 0.1).isFinite)
  }

  @Test("A spring far quicker than its base still runs its course")
  func heavilyQuickenedSpringRuns() {
    // 200 000 per second with 40 to go: 184 times quicker than the bounce
    // spring, so the whole bounce takes a few hundredths of a second.
    let quickening = 200_000 / (Self.bounceFrequency * M_E * 40)
    let spring = CanvasNavigation.SpringBack(
      base: CanvasNavigation.bounceSpring,
      rest: 0, start: 0, velocity: 200_000, startTime: 0, tolerance: 0.25,
      reach: 80
    )
    let peakTime = 1 / (Self.bounceFrequency * quickening)
    #expect(isClose(spring.value(at: peakTime), 40))
    #expect(spring.endTime > peakTime)
    #expect(spring.endTime < 0.01)
    #expect(abs(spring.value(at: spring.endTime - 1e-9)) <= 0.25)
  }

  @Test("A spring ends once it is within its tolerance to stay")
  func springBackEndsOnceSettled() {
    // Coming in from 3.172 at 93.45 per second, the settling spring is
    // within a quarter of a point of its rest a tenth of a second in, but
    // only on its way through: it passes its rest by 0.33 after that.
    let passing = CanvasNavigation.SpringBack(
      base: CanvasNavigation.settleSpring,
      rest: 0, start: 3.172, velocity: -93.45, startTime: 0, tolerance: 0.25
    )
    // It is within the tolerance for good 0.195 s in.
    #expect(
      passing.endTime
        >= settleTime(from: 3.172, speed: -93.45, frequency: Self.settleFrequency, within: 0.25)
    )

    // Whatever the start and the velocity, the spring that would have run on
    // stays within the tolerance from the end time on, and the motion is
    // within it just before it ends.
    for base in [CanvasNavigation.settleSpring, CanvasNavigation.bounceSpring] {
      for start in [0, 0.3, 3.172, 30, 278, 300] {
        for velocity in [-20_000, -3413, -860, -93.45, -10, 0, 10, 500, 5000] {
          let spring = CanvasNavigation.SpringBack(
            base: base,
            rest: 0, start: CGFloat(start), velocity: CGFloat(velocity), startTime: 0,
            tolerance: 0.25, reach: 800
          )
          let frequency = 2 * Double.pi / spring.spring.response
          for step in 0..<2000 {
            let time = spring.endTime + Double(step) * 0.0005
            let ideal = springDistance(
              from: start, speed: velocity, frequency: frequency, after: time
            )
            #expect(
              abs(ideal) <= 0.25 + 1e-9,
              "start \(start), velocity \(velocity), \(time - spring.endTime) s after its end"
            )
          }
          if spring.endTime > 0 {
            #expect(abs(spring.value(at: spring.endTime - 1e-9)) <= 0.25 + 1e-6)
          }
        }
      }
    }
  }

  @Test("A spring ends within a quarter of a second, in its base spring's time, of settling for good")
  func springEndIsNotLate() {
    for base in [CanvasNavigation.settleSpring, CanvasNavigation.bounceSpring] {
      for start in [0, 0.3, 3.172, 30, 278, 300] {
        for velocity in [-20_000, -3413, -860, -93.45, -10, 0, 10, 500, 5000] {
          let spring = CanvasNavigation.SpringBack(
            base: base,
            rest: 0, start: CGFloat(start), velocity: CGFloat(velocity), startTime: 0,
            tolerance: 0.25, reach: 800
          )
          let frequency = 2 * Double.pi / spring.spring.response
          let quickening = base.response / spring.spring.response
          let settled = abs(start) <= 0.25 && velocity == 0
            ? 0
            : settleTime(
              from: start, speed: Double(spring.velocity), frequency: frequency, within: 0.25
            )
          // The end is found in tenths of a second of the base spring's
          // time, by a test that errs on the late side: up to a tenth from
          // the first answer and a tenth more from the test. A spring `q`
          // times quicker ends `q` times sooner.
          #expect(
            spring.endTime - settled <= 0.25 / quickening + 0.001,
            "start \(start), velocity \(velocity)"
          )
        }
      }
    }
  }

  // MARK: - Deceleration that reaches a limit

  @Test("A deceleration that reaches a limit bounces there with the velocity it arrives with")
  func decelerationHandsOverToBounce() throws {
    let motion = try #require(
      CanvasNavigation.AxisMotion.deceleration(
        from: 0, velocity: 3000, at: 1,
        rate: 0.998, limits: -1000...300, endDistance: 0.5,
        bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 1e6
      )
    )

    // 300 away at 3000 per second, losing speed on the way: it gets there
    // after 0.1116 s, at 2399 per second.
    let crossing = log1p(Self.decay * 300 / 3000) / Self.decay
    let speed = 3000 * exp(Self.decay * crossing)

    // Until then it is the deceleration.
    for elapsed in [0, 0.03, 0.08, 0.11] {
      let sample = motion.sample(at: 1 + elapsed)
      #expect(isClose(sample.value, 3000 * expm1(Self.decay * elapsed) / Self.decay))
      #expect(isClose(sample.velocity, 3000 * exp(Self.decay * elapsed)))
      #expect(sample.isFinished == false)
    }

    // Position and velocity are the same on both sides of the crossing.
    let before = motion.sample(at: 1 + crossing - 1e-7)
    let after = motion.sample(at: 1 + crossing + 1e-7)
    #expect(abs(before.value - 300) < 1e-3)
    #expect(abs(after.value - 300) < 1e-3)
    #expect(isClose(before.velocity, speed, tolerance: 1e-5))
    #expect(isClose(after.velocity, speed, tolerance: 1e-5))

    // From there it is the spring: deepest a tenth of a second later.
    for elapsed in [0.01, 0.1, 0.4] {
      let distance = springDistance(
        from: 0, speed: speed, frequency: Self.bounceFrequency, after: elapsed
      )
      #expect(isClose(motion.sample(at: 1 + crossing + elapsed).value, 300 + distance))
    }
    #expect(
      isClose(
        motion.sample(at: 1 + crossing + 0.1).value,
        300 + speed / (Self.bounceFrequency * M_E)
      )
    )

    let end = motion.sample(at: 6)
    #expect(end == .init(value: 300, velocity: 0, isFinished: true))
  }

  @Test("A deceleration that stops short of the limits takes no bounce")
  func decelerationInsideLimits() throws {
    let motion = try #require(
      CanvasNavigation.AxisMotion.deceleration(
        from: 0, velocity: -500, at: 0,
        rate: 0.998, limits: -1000...300, endDistance: 0.5,
        bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 1e6
      )
    )
    guard case .decelerating(let deceleration, band: nil, bounce: nil) = motion else {
      Issue.record("Inside the limits the motion is a deceleration alone")
      return
    }
    let end = motion.sample(at: 10)
    #expect(end.isFinished)
    #expect(isClose(end.value, -500 / -Self.decay + 0.5))
    #expect(end.value == deceleration.value(at: deceleration.endTime))
  }

  @Test("A destination barely past a limit ends just short of it, without a bounce")
  func decelerationBarelyPastLimit() throws {
    let motion = try #require(
      CanvasNavigation.AxisMotion.deceleration(
        from: 0, velocity: CGFloat(300.3 * -Self.decay), at: 0,
        rate: 0.998, limits: -1000...300, endDistance: 0.5,
        bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 1e6
      )
    )
    guard case .decelerating(_, band: nil, bounce: nil) = motion else {
      Issue.record("A destination within the end distance of the limit takes no bounce")
      return
    }
    // It ends when a deceleration alone would, half a point short of its
    // destination at 300.3, not at the far later moment it would touch the
    // limit.
    #expect(motion.sample(at: 4).isFinished)
    #expect(isClose(motion.sample(at: 4).value, 299.8))
  }

  @Test("A deceleration that starts at the limit bounces at once")
  func decelerationFromLimit() throws {
    let motion = try #require(
      CanvasNavigation.AxisMotion.deceleration(
        from: 300, velocity: 2000, at: 0,
        rate: 0.998, limits: -1000...300, endDistance: 0.5,
        bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 1e6
      )
    )
    #expect(motion.sample(at: 0).value == 300)
    #expect(isClose(motion.sample(at: 0).velocity, 2000))
    #expect(isClose(motion.sample(at: 0.1).value, 300 + 2000 / (Self.bounceFrequency * M_E)))
  }

  @Test("A velocity that carries nowhere gives no motion")
  func axisMotionNeedsVelocity() {
    for velocity: CGFloat in [0, 0.5, -0.5, .nan] {
      #expect(
        CanvasNavigation.AxisMotion.deceleration(
          from: 0, velocity: velocity, at: 0,
          rate: 0.998, limits: -1000...300, endDistance: 0.5,
          bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 1e6
        ) == nil
      )
    }
  }

  // MARK: - Deceleration from past a limit

  @Test("A rubber band shows a value past its limits by less, and never by its dimension")
  func rubberBandShowsPull() {
    let band = CanvasNavigation.RubberBand(limits: 100...300, dimension: 800)
    #expect(band.shown(for: 100) == 100)
    #expect(band.shown(for: 250) == 250)
    #expect(band.slope(at: 250) == 1)
    #expect(isClose(band.shown(for: 100 - 60), 100 - rubberBand(60)))
    #expect(isClose(band.shown(for: 300 + 60), 300 + rubberBand(60)))
    #expect(band.shown(for: 300 + 1e9) < 300 + 800)

    // Its slope is the change of what shows per unit of the value.
    for value: CGFloat in [40, 99, 301, 900] {
      let step: CGFloat = 1e-4
      let numeric = (band.shown(for: value + step) - band.shown(for: value - step)) / (2 * step)
      #expect(isClose(band.slope(at: value), Double(numeric), tolerance: 1e-6))
    }
  }

  @Test("A deceleration from past a limit unwinds the pull through the rubber band")
  func decelerationFromPastLimit() throws {
    // 50 past the lower limit, moving back in at 500 per second: it would
    // end 199.75 inside.
    let motion = try #require(
      CanvasNavigation.AxisMotion.deceleration(
        from: -50, velocity: 500, at: 0,
        rate: 0.998, limits: 0...1000, endDistance: 0.5,
        bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 800
      )
    )
    guard case .decelerating(let deceleration, band: .some, bounce: nil) = motion else {
      Issue.record("A start past a limit shows through a rubber band")
      return
    }
    #expect(isClose(deceleration.destination, -50 - 500 / Self.decay))

    // Past the limit it shows what a rubber band shows of the pull, moving
    // slower than the pull by the band's slope.
    let start = motion.sample(at: 0)
    #expect(isClose(start.value, -rubberBand(50)))
    #expect(isClose(start.velocity, 500 * 0.55 * pow(1 - rubberBand(50) / 800, 2)))
    for elapsed in [0.02, 0.05, 0.09] {
      let pull = 50 - 500 * expm1(Self.decay * elapsed) / Self.decay
      #expect(pull > 0)
      #expect(isClose(motion.sample(at: elapsed).value, -rubberBand(pull)))
    }

    // It reaches the limit after 0.112 s, and from there it is the
    // deceleration itself.
    let crossing = log1p(Self.decay * 50 / 500) / Self.decay
    #expect(abs(motion.sample(at: crossing).value) < 1e-9)
    for elapsed in [0.12, 0.5, 2] {
      let sample = motion.sample(at: elapsed)
      #expect(isClose(sample.value, -50 + 500 * expm1(Self.decay * elapsed) / Self.decay))
      #expect(isClose(sample.velocity, 500 * exp(Self.decay * elapsed)))
    }
    let end = motion.sample(at: 10)
    #expect(end.isFinished)
    #expect(isClose(end.value, -50 - 500 / Self.decay - 0.5))
  }

  @Test("From past a limit there is a deceleration only when it ends inside")
  func decelerationFromPastLimitNeedsReach() {
    func motion(from start: CGFloat, velocity: CGFloat) -> CanvasNavigation.AxisMotion? {
      CanvasNavigation.AxisMotion.deceleration(
        from: start, velocity: velocity, at: 0,
        rate: 0.998, limits: 0...1000, endDistance: 0.5,
        bounce: CanvasNavigation.bounceSpring, tolerance: 0.25, reach: 800
      )
    }
    // 50 out: the velocity has to carry more than 50.5.
    let needed = CGFloat(50.5 * -Self.decay)
    #expect(motion(from: -50, velocity: needed * 1.001) != nil)
    #expect(motion(from: -50, velocity: needed * 0.999) == nil)
    #expect(motion(from: 1050, velocity: -needed * 1.001) != nil)
    #expect(motion(from: 1050, velocity: -needed * 0.999) == nil)
    // Farther out, never.
    #expect(motion(from: -50, velocity: -5000) == nil)
    #expect(motion(from: 1050, velocity: 5000) == nil)
    // From inside, any velocity that moves at all.
    #expect(motion(from: 0, velocity: -5000) != nil)
    #expect(motion(from: 500, velocity: 5) != nil)
  }

  // MARK: - Velocity estimate

  @Test("The velocity estimate is the translation over the time of the last inputs")
  func velocityEstimateMeasuresInputs() throws {
    var estimate = CanvasNavigation.VelocityEstimate()
    #expect(estimate.velocity == nil)

    // 10 points right and 5 up every hundredth of a second.
    for step in 0...8 {
      estimate.add(CGSize(width: 10, height: -5), at: 1 + Double(step) * 0.01)
    }
    var velocity = try #require(estimate.velocity)
    #expect(isClose(velocity.width, 1000))
    #expect(isClose(velocity.height, -500))

    // Sixty milliseconds at another speed replace what came before.
    for step in 9...15 {
      estimate.add(CGSize(width: 30, height: 0), at: 1 + Double(step) * 0.01)
    }
    velocity = try #require(estimate.velocity)
    #expect(isClose(velocity.width, 3000))
    #expect(isClose(velocity.height, 0, tolerance: 1e-9))

    estimate.reset()
    #expect(estimate.velocity == nil)
  }

  @Test("Four milliseconds of input are enough for an estimate")
  func velocityEstimateTakesItsShortestSpan() throws {
    var estimate = CanvasNavigation.VelocityEstimate()
    estimate.add(CGSize(width: 10, height: 0), at: 0)
    estimate.add(CGSize(width: 10, height: 0), at: 0.004)
    #expect(isClose(try #require(estimate.velocity).width, 2500))
  }

  @Test("The velocity estimate spans its window, not only the last inputs")
  func velocityEstimateSpansWindow() throws {
    var estimate = CanvasNavigation.VelocityEstimate()
    estimate.add(.zero, at: 1)
    for step in 1...4 {
      estimate.add(CGSize(width: 10, height: 0), at: 1 + Double(step) * 0.01)
    }
    // A burst at the end: 60 points in 5 ms. Over the 45 ms of input the
    // content moved 100 points.
    estimate.add(CGSize(width: 60, height: 0), at: 1.045)
    #expect(isClose(try #require(estimate.velocity).width, 100 / 0.045))
  }

  @Test("Inputs delivered together count as one, and too short a stretch gives no estimate")
  func velocityEstimateGuards() throws {
    // Two inputs at one time are one input of their sum.
    var together = CanvasNavigation.VelocityEstimate()
    together.add(CGSize(width: 10, height: 0), at: 0)
    together.add(CGSize(width: 10, height: 0), at: 0.02)
    together.add(CGSize(width: 10, height: 0), at: 0.02)
    var apart = CanvasNavigation.VelocityEstimate()
    apart.add(CGSize(width: 10, height: 0), at: 0)
    apart.add(CGSize(width: 20, height: 0), at: 0.02)
    #expect(together == apart)
    #expect(isClose(try #require(together.velocity).width, 1000))

    // A time that goes back counts as the last one.
    together.add(CGSize(width: 10, height: 0), at: 0.01)
    #expect(isClose(try #require(together.velocity).width, 1500))

    // Under four milliseconds of input say nothing reliable.
    var short = CanvasNavigation.VelocityEstimate()
    short.add(CGSize(width: 10, height: 0), at: 0)
    #expect(short.velocity == nil)
    short.add(CGSize(width: 10, height: 0), at: 0.001)
    #expect(short.velocity == nil)
    short.add(CGSize(width: 10, height: 0), at: 0.005)
    #expect(isClose(try #require(short.velocity).width, 4000))

    // An input after a pause is slow by itself: its translation over the
    // whole pause.
    var paused = CanvasNavigation.VelocityEstimate()
    paused.add(CGSize(width: 10, height: 0), at: 0)
    paused.add(CGSize(width: 10, height: 0), at: 0.01)
    paused.add(CGSize(width: 10, height: 0), at: 1.01)
    #expect(isClose(try #require(paused.velocity).width, 10))

    // Values that are not numbers are left out.
    var broken = CanvasNavigation.VelocityEstimate()
    broken.add(CGSize(width: 10, height: 0), at: 0)
    broken.add(CGSize(width: CGFloat.nan, height: 0), at: 0.01)
    broken.add(CGSize(width: 10, height: 0), at: .infinity)
    broken.add(CGSize(width: 10, height: 0), at: 0.02)
    #expect(isClose(try #require(broken.velocity).width, 500))
  }

  // MARK: - A host that gives a velocity

  @Test("A fling decelerates, reaches the edge, and bounces there")
  func flingDeceleratesAndBounces() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    // The content moves right at 3000 points per second, so the centre
    // moves left at 3000 / 0.4 units per second, toward its limit at 1000.
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 0)), at: 0)
    #expect(model.isMoving)

    func decelerating(_ elapsed: Double) -> Double {
      2000 - 7500 * expm1(Self.decay * elapsed) / Self.decay
    }
    for time in [0.016, 0.05, 0.1, 0.15] {
      model.advance(to: time)
      #expect(isClose(model.position.center.x, decelerating(time)))
      #expect(model.position.center.y == 1500)
    }

    // It reaches 1000 after 0.155 s, still at 2199 points per second, and
    // goes on as a spring from there. The hand-over falls between frames.
    let crossing = log1p(Self.decay * 1000 / 7500) / Self.decay
    let speed = 7500 * exp(Self.decay * crossing)
    for time in [1.0 / 6, 0.2, crossing + 0.1, 0.5] {
      model.advance(to: time)
      let distance = springDistance(
        from: 0, speed: speed, frequency: Self.bounceFrequency, after: time - crossing
      )
      #expect(isClose(model.position.center.x, 1000 - distance))
    }

    model.advance(to: 4)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("Each axis decelerates on its own: one bounces while the other runs out")
  func axesDecelerateSeparately() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 300)), at: 0)

    // Vertically 300 points per second carry the centre 750 / 2.002 = 374.6
    // units up, well inside its limits.
    func decelerating(_ elapsed: Double) -> Double {
      1500 - 750 * expm1(Self.decay * elapsed) / Self.decay
    }
    for time in [0.05, 0.2, 0.5, 1, 2] {
      model.advance(to: time)
      #expect(isClose(model.position.center.y, decelerating(time)))
    }
    // The horizontal bounce has come to rest by now; the vertical
    // deceleration still runs.
    #expect(model.position.center.x == 1000)
    #expect(model.isMoving)

    // It ends half a point (1.25 units) short of where it was heading.
    let duration = log(-Self.decay * 1.25 / 750) / Self.decay
    model.advance(to: duration - 0.01)
    #expect(model.isMoving)
    model.advance(to: duration + 0.01)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center.y, 1500 + 750 / Self.decay + 1.25))
  }

  @Test("A touch stops a deceleration and a bounce where they are")
  func touchDownStopsEveryAxis() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 300)), at: 0)

    var running = model
    running.advance(to: 0.2)
    #expect(running.position.center.x < 1000)

    model.handle(.touchDown, at: 0.2)
    #expect(model.isMoving == false)
    #expect(model.position == running.position)

    // Lifting without moving brings the bounced axis back; the other stays.
    model.handle(.gestureEnded(velocity: .zero), at: 0.3)
    #expect(model.isMoving)
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)
    #expect(model.position.center.y == running.position.center.y)
  }

  @Test("Fingers that had stopped before lifting leave the content where it is")
  func stillFingersDoNotDecelerate() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 20, height: 0), source: .gesture), at: 0)
    model.handle(.scroll(translation: CGSize(width: 20, height: 0), source: .gesture), at: 0.01)
    let released = model.position

    // The system still reports a velocity, half a second after the fingers
    // last moved.
    model.handle(.gestureEnded(velocity: CGSize(width: 2000, height: 0)), at: 0.5)
    #expect(model.isMoving == false)
    #expect(model.position == released)
  }

  @Test("Fingers count as stopped a tenth of a second after their last movement")
  func stillnessTakesATenthOfASecond() {
    func isMoving(endedAfter pause: Double) -> Bool {
      var model = makeZoomedModel()
      model.handle(.scroll(translation: CGSize(width: 20, height: 0), source: .gesture), at: 1)
      model.handle(.scroll(translation: CGSize(width: 20, height: 0), source: .gesture), at: 1.01)
      model.handle(.gestureEnded(velocity: CGSize(width: 2000, height: 0)), at: 1.01 + pause)
      return model.isMoving
    }
    #expect(isMoving(endedAfter: 0.09))
    #expect(isMoving(endedAfter: 0.11) == false)
  }

  @Test("Fingers that moved exactly a tenth of a second before the end still count as moving")
  func stillnessIncludesItsBound() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 20, height: 0), source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 2000, height: 0)), at: 0.1)
    #expect(model.isMoving)
  }

  @Test("A second end of a gesture brings no velocity")
  func secondEndBringsNoVelocity() {
    var model = makeZoomedModel()
    for step in 0..<6 {
      model.handle(
        .scroll(translation: CGSize(width: -10, height: -10), source: .gesture),
        at: 1 + Double(step) * 0.01
      )
    }
    // The first end moves the content left only.
    model.handle(.gestureEnded(velocity: CGSize(width: -1250, height: 0)), at: 1.05)
    #expect(model.isMoving)
    var reference = model

    // Another recognizer reports the same gesture's end, with a velocity
    // downward too: the vertical axis stays at rest.
    model.handle(.gestureEnded(velocity: CGSize(width: -1250, height: -1500)), at: 1.07)
    for time in [1.07, 1.2, 2] {
      model.advance(to: time)
      reference.advance(to: time)
      #expect(model.position == reference.position)
    }
  }

  @Test("A release inside the limits with no velocity given leaves the momentum to the system")
  func releaseWithoutVelocityDoesNotDecelerate() {
    var model = makeZoomedModel()
    // Fingers moving at 1000 points per second when they lift.
    for step in 0..<3 {
      model.handle(
        .scroll(translation: CGSize(width: 10, height: 0), source: .gesture),
        at: 1 + Double(step) * 0.01
      )
    }
    model.handle(.gestureEnded(velocity: nil), at: 1.02)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center.x, 2000 - 30 / 0.4))
  }

  @Test("A velocity that is not a number leaves the content where it is")
  func brokenVelocityDoesNotDecelerate() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: CGFloat.nan, height: 3000)), at: 0)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 2000, y: 1500))
  }

  @Test("Nothing decelerates at the fit")
  func fitDoesNotDecelerate() {
    var model = CanvasNavigation(contentSize: Self.content, canvasSize: Self.canvas)
    let before = model.position
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 3000)), at: 0)
    #expect(model.isMoving == false)
    #expect(model.position == before)
  }

  @Test("An axis the content fits on does not decelerate")
  func fittingAxisDoesNotDecelerate() {
    // 4000 x 1000 at 0.4 is 1600 x 400 points: it scrolls horizontally and
    // fits vertically.
    var model = makeZoomedModel(content: CGSize(width: 4000, height: 1000))
    #expect(isClose(model.position.scale, 0.4))
    #expect(model.position.center == CGPoint(x: 2000, y: 500))

    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 0, height: 3000)), at: 0)
    #expect(model.isMoving == false)

    model.handle(.scroll(translation: .zero, source: .gesture), at: 1)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 3000)), at: 1)
    #expect(model.isMoving)
    for time in stride(from: 1.0, through: 4, by: 0.05) {
      model.advance(to: time)
      #expect(model.position.center.y == 500)
    }
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)
  }

  @Test("Nothing decelerates after a pinch")
  func pinchDoesNotDecelerate() {
    var model = makeZoomedModel()
    model.handle(.magnify(factor: 1.1, anchor: Self.canvasCenter), at: 0)
    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .gesture), at: 0.01)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 0)), at: 0.02)
    #expect(model.isMoving == false)
  }

  @Test("Without animation nothing decelerates and momentum stops at the edge")
  func noAnimationNoDeceleration() {
    var model = makeZoomedModel()
    model.animates = false

    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 0)), at: 0)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 2000, y: 1500))

    model.handle(.scroll(translation: CGSize(width: 300, height: 0), source: .momentum), at: 0.1)
    model.handle(.scroll(translation: CGSize(width: 300, height: 0), source: .momentum), at: 0.11)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("A resize stops a deceleration inside the limits")
  func resizeStopsDeceleration() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: .zero, source: .gesture), at: 0)
    model.handle(.gestureEnded(velocity: CGSize(width: 3000, height: 300)), at: 0)
    model.advance(to: 0.2)
    #expect(model.position.center.x < 1000)

    model.setCanvasSize(CGSize(width: 600, height: 600))
    #expect(model.isMoving == false)
    #expect(isClose(model.position.scale, 0.4))
    // 600 points at 0.4 show 1500 units, so the centre may now start at 750.
    let stopped = model.position
    #expect(stopped.center.x >= 750)
    #expect(stopped.center.x < 1000)

    model.advance(to: 1)
    #expect(model.position == stopped)
  }

  // MARK: - Release past a limit

  /// Pulled 60 points past the left edge by fingers moving at 1000 points
  /// per second: six inputs of 10 points, a hundredth of a second apart, the
  /// last at 1.05.
  private func makePulledModel() -> CanvasNavigation {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    for step in 0..<6 {
      model.handle(
        .scroll(translation: CGSize(width: 10, height: 0), source: .gesture),
        at: 1 + Double(step) * 0.01
      )
    }
    return model
  }

  @Test("The rubber band's slope is its change per point of pull")
  func rubberBandSlope() {
    for pull: CGFloat in [0.001, 10, 60, 300, 2000] {
      let shown = CanvasNavigation.rubberBand(pull, dimension: 800)
      let step: CGFloat = 1e-4
      let numeric = (
        CanvasNavigation.rubberBand(pull + step, dimension: 800)
          - CanvasNavigation.rubberBand(pull - step, dimension: 800)
      ) / (2 * step)
      #expect(
        isClose(
          CanvasNavigation.rubberBandSlope(showing: shown, dimension: 800), Double(numeric),
          tolerance: 1e-6
        )
      )
    }
    #expect(CanvasNavigation.rubberBandSlope(showing: 0, dimension: 800) == 0.55)
    #expect(CanvasNavigation.rubberBandSlope(showing: 800, dimension: 800) == 0)
    #expect(CanvasNavigation.rubberBandSlope(showing: 10, dimension: 0) == 0)
  }

  @Test("A release past the edge keeps the speed the content shows")
  func releasePastLimitKeepsShownSpeed() {
    var model = makePulledModel()
    let shown = rubberBand(60)
    #expect(isClose(model.position.center.x, 1000 - shown / 0.4))

    model.handle(.gestureEnded(velocity: nil), at: 1.05)
    #expect(model.isMoving)

    // Past the edge the content moves slower than the fingers, by the rubber
    // band's slope where it is: 0.55 (1 - shown / 800)^2.
    let speed = 1000 * 0.55 * pow(1 - shown / 800, 2)
    for elapsed in [0.005, 0.02, 0.05, 0.1, 0.25] {
      model.advance(to: 1.05 + elapsed)
      let pull = springDistance(
        from: shown, speed: speed, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - pull / 0.4))
    }

    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("A release past the edge with a given velocity outward slows it the same way")
  func releasePastLimitWithVelocity() {
    var model = makePulledModel()
    let shown = rubberBand(60)

    // The fingers move right, farther out, at 2000 points per second.
    model.handle(.gestureEnded(velocity: CGSize(width: 2000, height: 0)), at: 1.05)

    let speed = 2000 * 0.55 * pow(1 - shown / 800, 2)
    for elapsed in [0.005, 0.02, 0.05, 0.1, 0.25] {
      model.advance(to: 1.05 + elapsed)
      let pull = springDistance(
        from: shown, speed: speed, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - pull / 0.4))
    }
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  // MARK: - A flick back inside from past a limit, for a host that gives a velocity

  /// Where the centre is `elapsed` seconds into a deceleration that starts
  /// at `start` with `velocity` units per second.
  private func decelerated(from start: Double, velocity: Double, after elapsed: Double) -> Double {
    start + velocity * expm1(Self.decay * elapsed) / Self.decay
  }

  /// What shows for a centre that the fingers hold `center` at, past the
  /// left edge at 1000 or inside it, at a zoom of 0.4.
  private func shownPastLeftEdge(_ center: Double) -> Double {
    center < 1000 ? 1000 - rubberBand((1000 - center) * 0.4) / 0.4 : center
  }

  @Test("A flick back toward the content from past the edge decelerates on into it")
  func inwardFlickDeceleratesOn() {
    // The fingers hold the centre 60 points past the left edge, at 850, and
    // move left at 1000 points per second as they lift: the centre moves
    // right at 2500 units per second.
    var model = makePulledModel()
    model.handle(.gestureEnded(velocity: CGSize(width: -1000, height: 0)), at: 1.05)
    #expect(model.isMoving)

    // The pull unwinds as more of the gesture would, shown through the
    // rubber band, and from the edge on the content moves as fast as the
    // fingers did. It reaches the edge after 0.064 s.
    for elapsed in [0.005, 0.02, 0.05, 0.06, 0.07, 0.1, 0.5, 2] {
      model.advance(to: 1.05 + elapsed)
      let center = decelerated(from: 850, velocity: 2500, after: elapsed)
      #expect(isClose(model.position.center.x, shownPastLeftEdge(center)), "after \(elapsed) s")
      #expect(model.position.center.y == 1500)
    }

    // It ends half a point (1.25 units) short of where it was heading.
    model.advance(to: 6)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center.x, 850 - 2500 / Self.decay - 1.25))
  }

  @Test("At the release the content keeps the speed it shows, and inside it moves with the fingers")
  func inwardFlickKeepsShownSpeedAtRelease() {
    var model = makePulledModel()
    let shown = rubberBand(60)
    model.handle(.gestureEnded(velocity: CGSize(width: -1000, height: 0)), at: 1.05)

    // Past the edge: the fingers' 1000 points per second times the rubber
    // band's slope where the pull shows.
    model.advance(to: 1.05 + 0.0001)
    let first = (Double(model.position.center.x) - (1000 - shown / 0.4)) * 0.4 / 0.0001
    #expect(abs(first - 1000 * 0.55 * pow(1 - shown / 800, 2)) < 1)

    // Inside: the fingers' own speed, less what a tenth of a second took.
    model.advance(to: 1.15)
    let before = Double(model.position.center.x)
    model.advance(to: 1.1501)
    let later = (Double(model.position.center.x) - before) * 0.4 / 0.0001
    #expect(abs(later - 1000 * exp(Self.decay * 0.1)) < 1)
  }

  @Test("A flick back that does not carry the content inside leaves it to the way back")
  func weakInwardFlickGoesBack() {
    var model = makePulledModel()
    let shown = rubberBand(60)

    // 110 points per second carry 55 points, short of the 60 the fingers
    // hold the content out by.
    model.handle(.gestureEnded(velocity: CGSize(width: -110, height: 0)), at: 1.05)

    let speed = -110 * 0.55 * pow(1 - shown / 800, 2)
    for elapsed in [0.005, 0.05, 0.1, 0.25] {
      model.advance(to: 1.05 + elapsed)
      let pull = springDistance(
        from: shown, speed: speed, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - pull / 0.4))
    }
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("A flick back that crosses the whole range bounces at the far edge")
  func inwardFlickBouncesAtFarEdge() {
    // 3000 points per second: 7500 units per second from 850 would end at
    // 4596, past the right edge at 3000.
    var model = makePulledModel()
    model.handle(.gestureEnded(velocity: CGSize(width: -3000, height: 0)), at: 1.05)

    let crossing = log1p(Self.decay * 2150 / 7500) / Self.decay
    let speed = 7500 * exp(Self.decay * crossing)
    for elapsed in [0.1, 0.3, crossing - 0.01] {
      model.advance(to: 1.05 + elapsed)
      let center = decelerated(from: 850, velocity: 7500, after: elapsed)
      #expect(isClose(model.position.center.x, shownPastLeftEdge(center)))
    }
    for elapsed in [0.02, 0.1, 0.3] {
      model.advance(to: 1.05 + crossing + elapsed)
      let depth = springDistance(
        from: 0, speed: speed, frequency: Self.bounceFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 3000 + depth))
    }
    model.advance(to: 8)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 3000)
  }

  @Test("A flick from just past the edge ends where one from the edge ends; from farther out, short by the pull")
  func inwardFlickIsContinuousAtLimit() {
    func rest(pulledBy pull: CGFloat) -> CGFloat {
      var model = makeZoomedModel()
      model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
      model.handle(.scroll(translation: CGSize(width: pull, height: 0), source: .gesture), at: 1)
      model.handle(.gestureEnded(velocity: CGSize(width: -800, height: 0)), at: 1.01)
      model.advance(to: 8)
      #expect(model.isMoving == false)
      return model.position.center.x
    }
    // 800 points per second carry the centre 2000 / 2.002 units from where
    // the fingers hold it.
    let atEdge = rest(pulledBy: 0)
    #expect(isClose(atEdge, 1000 - 2000 / Self.decay - 1.25))
    // A hundredth of a point shows past the edge up to a pull of 0.018.
    #expect(isClose(rest(pulledBy: 0.01), Double(atEdge)))
    // Past that, the content starts from where the fingers hold it.
    #expect(isClose(rest(pulledBy: 0.04), Double(atEdge) - 0.04 / 0.4))
    #expect(isClose(rest(pulledBy: 10), Double(atEdge) - 10 / 0.4))
  }

  @Test("Without animation a flick back from past the edge puts the content at the edge")
  func inwardFlickWithoutAnimation() {
    var model = makePulledModel()
    model.animates = false
    model.handle(.gestureEnded(velocity: CGSize(width: -1000, height: 0)), at: 1.05)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("A release after the fingers stopped springs back from rest")
  func releaseAfterPauseSpringsFromRest() {
    var model = makePulledModel()
    let shown = rubberBand(60)

    model.handle(.gestureEnded(velocity: nil), at: 1.5)

    for elapsed in [0.01, 0.05, 0.1, 0.3] {
      model.advance(to: 1.5 + elapsed)
      // (1 + bt) e^(-bt) of the way is left.
      let pull = springDistance(
        from: shown, speed: 0, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - pull / 0.4))
    }
  }

  @Test("However far the content is pulled, a release goes back on the same spring")
  func releaseFarOutKeepsSpring() {
    // The share of the canvas the pull shows when the fingers lift, still
    // moving outward. Nothing special happens at half the canvas.
    for share in [0.3, 0.499, 0.5, 0.501, 0.6] {
      var model = makeZoomedModel()
      model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
      let shown = share * 800
      // The pull the rubber band shows as `shown`.
      let pull = 800 / 0.55 * shown / (800 - shown)
      for step in 0..<20 {
        model.handle(
          .scroll(translation: CGSize(width: pull / 20, height: 0), source: .gesture),
          at: 1 + Double(step) * 0.008
        )
      }
      let released = 1 + 19 * 0.008
      #expect(isClose(model.position.center.x, 1000 - shown / 0.4))

      model.handle(.gestureEnded(velocity: nil), at: released)
      let speed = pull / 20 / 0.008 * 0.55 * pow(1 - share, 2)
      for elapsed in [1.0 / 120, 0.05, 0.2] {
        model.advance(to: released + elapsed)
        let left = springDistance(
          from: shown, speed: speed, frequency: Self.settleFrequency, after: elapsed
        )
        #expect(isClose(model.position.center.x, 1000 - left / 0.4), "share \(share)")
      }
    }
  }

  @Test("A release ends when the content is a quarter of a canvas point from its rest")
  func releaseEndsWithinCanvasTolerance() {
    var model = makePulledModel()
    model.handle(.gestureEnded(velocity: nil), at: 1.5)

    // 0.44 s. The model answers in tenths of a second, so it ends a little
    // later, and never earlier.
    let settled = settleTime(
      from: rubberBand(60), speed: 0, frequency: Self.settleFrequency, within: 0.25
    )
    model.advance(to: 1.5 + settled - 0.02)
    #expect(model.isMoving)
    model.advance(to: 1.5 + settled + 0.105)
    #expect(model.isMoving == false)
  }

  @Test("A pull of half a point springs back too")
  func smallPullSpringsBack() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: 0.9, height: 0), source: .gesture), at: 1)
    let shown = rubberBand(0.9)
    #expect(abs(shown - 0.4947) < 1e-4)

    model.handle(.gestureEnded(velocity: nil), at: 1.5)
    #expect(model.isMoving)
    model.advance(to: 1.55)
    let left = springDistance(from: shown, speed: 0, frequency: Self.settleFrequency, after: 0.05)
    #expect(isClose(model.position.center.x, 1000 - left / 0.4))
  }

  /// Zoomed in at the top edge, with a zoom toggle back to the fit stopped
  /// where the content already fits vertically (800 points at under 4 / 15)
  /// but is not yet centred on that axis.
  private func makeToggleStoppedOffCentre() -> CanvasNavigation {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 0, height: 5000), source: .wheel), at: 0)
    model.handle(.toggleZoom(anchor: Self.canvasCenter), at: 1)
    model.advance(to: 1.15)
    return model
  }

  @Test("A release on an axis the content fits on starts from rest, whatever velocity is given")
  func fittingAxisReleaseStartsFromRest() {
    var model = makeToggleStoppedOffCentre()
    model.handle(.scroll(translation: .zero, source: .gesture), at: 1.15)
    let scale = Double(model.position.scale)
    #expect(scale < 800.0 / 3000.0)
    let pull = (1500 - Double(model.position.center.y)) * scale
    #expect(pull > 10)

    model.handle(.gestureEnded(velocity: CGSize(width: 0, height: 3000)), at: 1.16)
    #expect(model.isMoving)
    for elapsed in [0.01, 0.05, 0.1] {
      model.advance(to: 1.16 + elapsed)
      let left = springDistance(
        from: pull, speed: 0, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.y, 1500 - left / scale))
    }
  }

  @Test("A touch during a gesture leaves the fingers no velocity")
  func touchDownForgetsGestureVelocity() {
    // Fingers moving at 1000 points per second, then another touch, then
    // the end.
    var model = makePulledModel()
    model.handle(.touchDown, at: 1.06)
    model.handle(.gestureEnded(velocity: nil), at: 1.07)

    let shown = rubberBand(60)
    for elapsed in [0.01, 0.05, 0.1] {
      model.advance(to: 1.07 + elapsed)
      let left = springDistance(
        from: shown, speed: 0, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
  }

  @Test("A new gesture starts with no velocity from the one before")
  func newGestureForgetsPreviousVelocity() {
    var model = makePulledModel()
    model.handle(.gestureEnded(velocity: nil), at: 1.05)

    // A gesture that moves nothing stops the way back, and ends at once.
    model.handle(.scroll(translation: .zero, source: .gesture), at: 1.08)
    let pull = Double(1000 - model.position.center.x) * 0.4
    #expect(pull > 10)
    model.handle(.gestureEnded(velocity: nil), at: 1.09)

    for elapsed in [0.01, 0.05, 0.1] {
      model.advance(to: 1.09 + elapsed)
      let left = springDistance(
        from: pull, speed: 0, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
  }

  // MARK: - Momentum

  /// At the left edge less `distance` points, with a first momentum input of
  /// 10 points at 1.0 that leaves `distance - 10` points to the edge.
  private func makeModelNearEdge(distance: CGFloat) -> CanvasNavigation {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: -distance, height: 0), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1)
    return model
  }

  @Test("A momentum bounce is as deep as the momentum is fast, wherever its input lands")
  func momentumBounceDependsOnSpeed() {
    // 50 points in a sixtieth of a second: 3000 points per second, which
    // the bounce spring carries 110.36 points past the edge.
    let interval = 1.0 / 60
    let speed = 50 / interval
    let peak = speed / (Self.bounceFrequency * M_E)

    // The input that crosses the edge lands 10 points past it, or 40.
    for overshoot: Double in [10, 40] {
      var model = makeModelNearEdge(distance: CGFloat(50 - overshoot) + 10)
      #expect(isClose(model.position.center.x, 1000 + (50 - overshoot) / 0.4))

      model.handle(
        .scroll(translation: CGSize(width: 50, height: 0), source: .momentum),
        at: 1 + interval
      )
      #expect(model.isMoving)

      // The spring started when the content crossed the edge, so at the
      // input it is already under way: 9.67 points out, or 35.01.
      let crossing = 1 + interval - overshoot / speed
      let atInput = springDistance(
        from: 0, speed: speed, frequency: Self.bounceFrequency, after: overshoot / speed
      )
      #expect(isClose(model.position.center.x, 1000 - atInput / 0.4))

      model.advance(to: crossing + 1 / Self.bounceFrequency)
      #expect(isClose(model.position.center.x, 1000 - peak / 0.4))
    }
  }

  @Test("While one axis bounces, the other keeps following the momentum")
  func momentumFollowsPerAxis() {
    var model = makeModelNearEdge(distance: 20)
    let interval = 1.0 / 60

    // 50 points right cross the edge; 20 points down move the centre up.
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 20), source: .momentum),
      at: 1 + interval
    )
    #expect(model.isMoving)
    #expect(model.position.center.x < 1000)
    #expect(isClose(model.position.center.y, 1450))

    for step in 2...5 {
      let time = 1 + Double(step) * interval
      var bouncing = model
      bouncing.advance(to: time)
      model.handle(.scroll(translation: CGSize(width: 50, height: 20), source: .momentum), at: time)
      #expect(model.position.center.x == bouncing.position.center.x)
      #expect(isClose(model.position.center.y, 1500 - Double(step) * 50))
    }
  }

  @Test("A touch during a bounce, lifted at once, carries none of the momentum's speed")
  func touchAfterMomentumCarriesNoVelocity() {
    var model = makeModelNearEdge(distance: 20)
    model.handle(.scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1 + 1.0 / 60)

    model.handle(.touchDown, at: 1.05)
    #expect(model.isMoving == false)
    let pull = Double(1000 - model.position.center.x) * 0.4
    #expect(pull > 10)

    // More of that momentum moves nothing.
    let stopped = model.position
    model.handle(.scroll(translation: CGSize(width: 50, height: 50), source: .momentum), at: 1.055)
    #expect(model.position == stopped)

    model.handle(.gestureEnded(velocity: nil), at: 1.06)
    for elapsed in [0.01, 0.05, 0.1] {
      model.advance(to: 1.06 + elapsed)
      let left = springDistance(
        from: pull, speed: 0, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
  }

  @Test("A crossing with no time to tell a speed by stops at the edge")
  func crossingWithoutTimeStopsAtLimit() {
    var model = makeModelNearEdge(distance: 20)
    // The same time as the only input before it: no time passed, and no
    // stretch of input to estimate from.
    model.handle(.scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1)
    #expect(model.position.center.x == 1000)
    #expect(model.isMoving == false)
  }

  @Test("A crossing under a point per second stops at the edge")
  func slowCrossingStopsAtLimit() {
    // 0.2 points to the edge, then half a point a second later.
    var model = makeModelNearEdge(distance: 10.2)
    model.handle(.scroll(translation: CGSize(width: 0.5, height: 0), source: .momentum), at: 2)
    #expect(model.position.center.x == 1000)
    #expect(model.isMoving == false)
  }

  @Test("A crossing exactly four milliseconds after the input before it takes its own speed")
  func crossingAtShortestSpanUsesOwnSpeed() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    // 8 points inside the left edge.
    model.handle(.scroll(translation: CGSize(width: -8, height: 0), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: 2, height: 0), source: .momentum), at: 0.006)
    model.handle(.scroll(translation: CGSize(width: 2, height: 0), source: .momentum), at: 0.016)
    // 0.02 - 0.016 is exactly 0.004 in binary floating point: 8 points in
    // 4 ms are 2000 points per second, where the stretch of input says 714.
    model.handle(.scroll(translation: CGSize(width: 8, height: 0), source: .momentum), at: 0.02)
    #expect(model.isMoving)

    var deepest: CGFloat = 0
    for step in 0...1000 {
      model.advance(to: 0.02 + Double(step) * 0.001)
      deepest = max(deepest, (1000 - model.position.center.x) * 0.4)
    }
    let expected = 2000 / (Self.bounceFrequency * M_E)
    #expect(abs(Double(deepest) - expected) < 0.01 * expected)
  }

  @Test("A crossing too soon after the last input takes its speed from the stretch of input")
  func crossingTooSoonUsesEstimate() {
    let interval = 1.0 / 60

    // 30 points to the edge. Ten points a sixtieth of a second later, then
    // 50 more only 2 ms after that: 60 points in 18.7 ms.
    var model = makeModelNearEdge(distance: 40)
    model.handle(
      .scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1 + interval
    )
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum),
      at: 1 + interval + 0.002
    )
    #expect(model.isMoving)
    let speed = 60 / (interval + 0.002)
    // The content is 30 points past the edge, which it crossed 9 ms ago at
    // that speed; the bounce starts no earlier than the input before.
    var depth = springDistance(from: 0, speed: speed, frequency: Self.bounceFrequency, after: 0.002)
    #expect(isClose(model.position.center.x, 1000 - depth / 0.4))
    model.advance(to: 1 + interval + 0.1)
    #expect(isClose(model.position.center.x, 1000 - speed / (Self.bounceFrequency * M_E) / 0.4))

    // Delivered together with the input before it, at one time: 60 points
    // in a sixtieth of a second, and the bounce starts now.
    model = makeModelNearEdge(distance: 40)
    model.handle(
      .scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1 + interval
    )
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1 + interval
    )
    #expect(model.isMoving)
    #expect(model.position.center.x == 1000)
    model.advance(to: 1 + interval + 0.05)
    depth = springDistance(
      from: 0, speed: 60 / interval, frequency: Self.bounceFrequency, after: 0.05
    )
    #expect(isClose(model.position.center.x, 1000 - depth / 0.4))
  }

  @Test("A crossing just under four milliseconds after the input before it takes its speed from the stretch of input")
  func crossingJustUnderShortestSpanUsesEstimate() {
    let interval = 1.0 / 60
    let gap = 0.0039
    var model = makeModelNearEdge(distance: 40)
    model.handle(
      .scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1 + interval
    )
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1 + interval + gap
    )
    #expect(model.isMoving)
    // 60 points in 20.6 ms, where its own 50 points in 3.9 ms would be
    // 12 800 per second. The bounce starts no earlier than the input before.
    let speed = 60 / (interval + gap)
    let depth = springDistance(from: 0, speed: speed, frequency: Self.bounceFrequency, after: gap)
    #expect(isClose(model.position.center.x, 1000 - depth / 0.4))
    model.advance(to: 1 + interval + 0.1)
    #expect(isClose(model.position.center.x, 1000 - speed / (Self.bounceFrequency * M_E) / 0.4))
  }

  @Test("A crossing too soon after the last input counts its own axis, whatever the other one carries")
  func crossingTooSoonIgnoresOtherAxis() {
    let interval = 1.0 / 60
    // As in `crossingTooSoonUsesEstimate`, but the crossing input's vertical
    // translation is not a number: still 60 points in 18.7 ms.
    var model = makeModelNearEdge(distance: 40)
    model.handle(
      .scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1 + interval
    )
    model.handle(
      .scroll(translation: CGSize(width: 50, height: CGFloat.nan), source: .momentum),
      at: 1 + interval + 0.002
    )
    #expect(model.isMoving)
    let speed = 60 / (interval + 0.002)
    let depth = springDistance(from: 0, speed: speed, frequency: Self.bounceFrequency, after: 0.002)
    #expect(isClose(model.position.center.x, 1000 - depth / 0.4))
    #expect(model.position.center.y == 1500)
    model.advance(to: 1 + interval + 0.1)
    #expect(isClose(model.position.center.x, 1000 - speed / (Self.bounceFrequency * M_E) / 0.4))
  }

  @Test("A crossing stamped before the input it follows starts its bounce at once")
  func outOfOrderCrossingStartsNow() {
    let interval = 1.0 / 60
    var model = makeModelNearEdge(distance: 40)
    model.handle(
      .scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1 + interval
    )
    // Stamped 5 ms before the input it follows, it counts with that one: 60
    // points in a sixtieth of a second.
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum),
      at: 1 + interval - 0.005
    )
    #expect(model.isMoving)
    #expect(model.position.center.x == 1000)
    model.advance(to: 1 + interval + 0.05)
    let depth = springDistance(
      from: 0, speed: 60 / interval, frequency: Self.bounceFrequency, after: 0.05
    )
    #expect(isClose(model.position.center.x, 1000 - depth / 0.4))
  }

  @Test("A crossing whose stretch of input points back inside stops at the edge")
  func crossingAgainstEstimateStopsAtLimit() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    // The fingers pull 30 points past the left edge and come 40 back, so
    // the content is 10 points inside, and they lift.
    model.handle(.scroll(translation: CGSize(width: 30, height: 0), source: .gesture), at: 1)
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .gesture), at: 1.01)
    model.handle(.gestureEnded(velocity: nil), at: 1.01)
    #expect(isClose(model.position.center.x, 1025))

    // Momentum toward the edge only 2 ms later crosses it. Over the stretch
    // of input the content moved away from the edge, so there is no speed
    // out of it to bounce with.
    model.handle(.scroll(translation: CGSize(width: 20, height: 0), source: .momentum), at: 1.012)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)
  }

  @Test("A bounce whose input is behind the latest frame starts from that frame")
  func bounceBehindClockStartsOnClock() {
    // 10 points to the edge.
    var model = makeModelNearEdge(distance: 20)
    model.advance(to: 1.03)
    // Stamped before that frame: 3000 points per second, 40 points past.
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1 + 1.0 / 60
    )
    // The content shows where it is 40 / 3000 seconds after the crossing,
    // with that crossing counted back from the frame.
    let depth = springDistance(
      from: 0, speed: 3000, frequency: Self.bounceFrequency, after: 40.0 / 3000
    )
    #expect(isClose(model.position.center.x, 1000 - depth / 0.4))
  }

  @Test("The axis that bounced leaves the rest of that momentum alone after the bounce too")
  func bouncedAxisDropsMomentumAfterBounce() {
    var model = makeModelNearEdge(distance: 20)
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1 + 1.0 / 60
    )
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)

    model.handle(.scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 3.01)
    model.handle(.scroll(translation: CGSize(width: -50, height: 0), source: .momentum), at: 3.02)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)
  }

  @Test("A bounce goes no deeper than half the canvas along its own axis")
  func bounceDepthBoundedByCanvasAxis() {
    // An 800 x 400 canvas: the fit is 2 / 15, so twice that shows 3000 x
    // 1500 units and the centre starts at 750 vertically.
    var model = makeZoomedModel(canvas: CGSize(width: 800, height: 400))
    let scale = Double(model.position.scale)
    #expect(isClose(model.position.scale, 4.0 / 15))
    model.handle(.scroll(translation: CGSize(width: 0, height: 5000), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: 0, height: -20), source: .wheel), at: 0)
    #expect(isClose(model.position.center.y, 750 + 20 / scale))

    // 1000 points in a sixtieth of a second: 60 000 points per second, 990
    // points past the edge.
    let interval = 1.0 / 60
    model.handle(.scroll(translation: CGSize(width: 0, height: 10), source: .momentum), at: 1)
    model.handle(
      .scroll(translation: CGSize(width: 0, height: 1000), source: .momentum), at: 1 + interval
    )
    #expect(model.isMoving)

    var deepest = 0.0
    for step in 0..<15_000 {
      model.advance(to: 1 + interval + Double(step) * 0.0002)
      deepest = max(deepest, (750 - Double(model.position.center.y)) * scale)
    }
    #expect(model.isMoving == false)
    // Half of 400 points, not of 800. The spring that peaks there has an
    // angular frequency of v / (200 e), and is 990 / v seconds past the
    // crossing when its input arrives, already on its way back.
    let speed = 1000 / interval
    let frequency = speed / (200 * M_E)
    #expect(deepest <= 200)
    #expect(
      isClose(
        CGFloat(deepest),
        springDistance(from: 0, speed: speed, frequency: frequency, after: 990 / speed)
      )
    )
  }

  @Test("A bounce ends when the content is a quarter of a canvas point from the edge")
  func bounceEndsWithinCanvasTolerance() {
    var model = makeModelNearEdge(distance: 20)
    let interval = 1.0 / 60
    model.handle(
      .scroll(translation: CGSize(width: 50, height: 0), source: .momentum), at: 1 + interval
    )
    // The bounce started when the content crossed the edge, 40 points ago
    // at 3000 points per second. 0.93 s later it is within a quarter point.
    let start = 1 + interval - 40.0 / 3000
    let settled = settleTime(from: 0, speed: 3000, frequency: Self.bounceFrequency, within: 0.25)
    model.advance(to: start + settled - 0.02)
    #expect(model.isMoving)
    model.advance(to: start + settled + 0.105)
    #expect(model.isMoving == false)
  }

  @Test("A gesture that pinched drops the momentum that follows it")
  func pinchThenPanDropsMomentum() {
    var model = makeZoomedModel()
    model.handle(.magnify(factor: 1.1, anchor: Self.canvasCenter), at: 1)
    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .gesture), at: 1.01)
    model.handle(.gestureEnded(velocity: nil), at: 1.02)
    let released = model.position
    #expect(model.isMoving == false)

    model.handle(.scroll(translation: CGSize(width: 50, height: 50), source: .momentum), at: 1.03)
    #expect(model.position == released)
  }

  @Test("Momentum does not move an axis that is held past its edge")
  func momentumPastLimitWaits() {
    // A gesture holds the content 60 points past the left edge, and
    // momentum arrives before the gesture ends.
    var model = makePulledModel()
    let held = model.position
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .momentum), at: 1.06)
    #expect(model.position == held)
    #expect(model.isMoving == false)
    model.handle(.scroll(translation: CGSize(width: 40, height: 0), source: .momentum), at: 1.07)
    #expect(model.position == held)

    // The gesture's end brings the content back to the edge, no farther.
    model.handle(.gestureEnded(velocity: nil), at: 1.3)
    #expect(model.isMoving)
    var farthest = held.center.x
    for step in 0..<600 {
      model.advance(to: 1.3 + Double(step) * 0.005)
      farthest = max(farthest, model.position.center.x)
    }
    #expect(farthest == 1000)
    #expect(model.isMoving == false)
  }

  @Test("Momentum is dropped after a zoom")
  func momentumDroppedAfterZoom() {
    var model = makeZoomedModel()
    model.handle(.zoomStep(factor: 1.5, anchor: Self.canvasCenter), at: 1)
    let zoomed = model.position
    model.handle(.scroll(translation: CGSize(width: 50, height: 50), source: .momentum), at: 1.01)
    #expect(model.position == zoomed)

    // While a zoom toggle runs, too, and after it.
    model.handle(.toggleZoom(anchor: Self.canvasCenter), at: 2)
    var toggling = model
    toggling.advance(to: 2.05)
    model.handle(.scroll(translation: CGSize(width: 50, height: 50), source: .momentum), at: 2.05)
    #expect(model.position == toggling.position)
  }

  // MARK: - A flick back inside from past a limit, where the system's momentum follows

  /// Held 30 points past the left edge by fingers that pulled out 60 and
  /// are coming back at 1000 points per second, lifted at 1.03 with no
  /// velocity given: the system's momentum follows.
  private func makeModelReleasedComingBack(animates: Bool = true) -> CanvasNavigation {
    var model = makeZoomedModel()
    model.animates = animates
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: 60, height: 0), source: .gesture), at: 1)
    for step in 1...3 {
      model.handle(
        .scroll(translation: CGSize(width: -10, height: 0), source: .gesture),
        at: 1 + Double(step) * 0.01
      )
    }
    model.handle(.gestureEnded(velocity: nil), at: 1.03)
    return model
  }

  /// The pull the content shows `elapsed` seconds into its way back from
  /// that release: from what 30 points of pull show, at the speed the
  /// content showed under the fingers.
  private func wayBackFromRelease(after elapsed: Double) -> Double {
    let shown = rubberBand(30)
    return springDistance(
      from: shown, speed: -1000 * 0.55 * pow(1 - shown / 800, 2),
      frequency: Self.settleFrequency, after: elapsed
    )
  }

  /// The same release at the right edge, the centre's upper limit: held 30
  /// points past it by fingers that pulled out 60 and are coming back at 1000
  /// points per second, lifted at 1.03 with no velocity given.
  private func makeModelReleasedComingBackAtRightEdge() -> CanvasNavigation {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: -5000, height: 0), source: .wheel), at: 0)
    model.handle(.scroll(translation: CGSize(width: -60, height: 0), source: .gesture), at: 1)
    for step in 1...3 {
      model.handle(
        .scroll(translation: CGSize(width: 10, height: 0), source: .gesture),
        at: 1 + Double(step) * 0.01
      )
    }
    model.handle(.gestureEnded(velocity: nil), at: 1.03)
    return model
  }

  @Test("With no momentum, a release coming back goes back to the edge as any release does")
  func releaseComingBackWithoutMomentum() {
    var model = makeModelReleasedComingBack()
    #expect(model.isMoving)
    for elapsed in [0.005, 0.02, 0.05, 0.1] {
      model.advance(to: 1.03 + elapsed)
      #expect(isClose(model.position.center.x, 1000 - wayBackFromRelease(after: elapsed) / 0.4))
    }
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }

  @Test("Momentum that points back inside takes the content over, through the rubber band and on")
  func momentumCarriesReleaseOn() {
    var model = makeModelReleasedComingBack()

    // 12 points every hundredth of a second. The pull goes on from the 30
    // points the fingers left: 18, then 6, shown as a rubber band shows them.
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    // (The way back it took over had come less far, to 21 points of pull.)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(18) / 0.4))

    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.05)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(6) / 0.4))
    // The momentum holds the content there: it is not at rest.
    #expect(model.isMoving)

    // From the edge on the content moves as the momentum does.
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.06)
    #expect(isClose(model.position.center.x, 1000 + 6 / 0.4))
    #expect(model.isMoving == false)
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.07)
    #expect(isClose(model.position.center.x, 1000 + 18 / 0.4))

    // The momentum's end leaves it there.
    model.handle(.gestureEnded(velocity: nil), at: 1.08)
    #expect(model.isMoving == false)
    #expect(isClose(model.position.center.x, 1000 + 18 / 0.4))
  }

  @Test("At the right edge too, momentum back inside moves the pull on from where the fingers left it")
  func momentumCarriesReleaseOnAtRightEdge() {
    var model = makeModelReleasedComingBackAtRightEdge()
    #expect(isClose(model.position.center.x, 3000 + rubberBand(30) / 0.4))

    model.handle(.scroll(translation: CGSize(width: 12, height: 0), source: .momentum), at: 1.04)
    #expect(isClose(model.position.center.x, 3000 + rubberBand(18) / 0.4))
    model.handle(.scroll(translation: CGSize(width: 12, height: 0), source: .momentum), at: 1.05)
    #expect(isClose(model.position.center.x, 3000 + rubberBand(6) / 0.4))
    #expect(model.isMoving)

    model.handle(.scroll(translation: CGSize(width: 12, height: 0), source: .momentum), at: 1.06)
    #expect(isClose(model.position.center.x, 3000 - 6 / 0.4))
    #expect(model.isMoving == false)
  }

  @Test("Momentum that comes late takes over from where the way back has brought the content")
  func lateMomentumTakesOverWithoutMovingBack() {
    var model = makeModelReleasedComingBack()
    var goingBack = model
    goingBack.advance(to: 1.08)
    // By now the way back shows about one point of pull, far less than the
    // 30 the fingers left.
    let shown = wayBackFromRelease(after: 0.05)

    // 3 points in 50 ms: 60 points per second, enough to cover what is left.
    model.handle(.scroll(translation: CGSize(width: -3, height: 0), source: .momentum), at: 1.08)
    #expect(
      isClose(
        model.position.center.x, Double(goingBack.position.center.x), tolerance: 1e-12
      )
    )
    #expect(model.position.center.y == goingBack.position.center.y)

    // The next ones move the pull on from there: 800 / 0.55 s / (800 - s)
    // points of pull show as s.
    let pull = 800 / 0.55 * shown / (800 - shown)
    model.handle(.scroll(translation: CGSize(width: -3, height: 0), source: .momentum), at: 1.09)
    #expect(isClose(model.position.center.x, 1000 + (3 - pull) / 0.4))
  }

  @Test("Momentum that points farther out is dropped, and the way back goes on")
  func outwardMomentumAfterReleaseIsDropped() {
    var model = makeModelReleasedComingBack()
    var goingBack = model

    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1.04)
    // The rest of it too, whichever way it points.
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .momentum), at: 1.05)
    for time in [1.05, 1.1, 1.2, 3] {
      model.advance(to: time)
      goingBack.advance(to: time)
      #expect(model.position == goingBack.position)
    }
    #expect(model.position.center.x == 1000)
  }

  @Test("Momentum too weak to bring the content back inside is dropped")
  func weakMomentumAfterReleaseIsDropped() {
    var model = makeModelReleasedComingBack()
    var goingBack = model

    // 0.3 points in a hundredth of a second: 30 points per second, which
    // carry 15 points, with 21 points of pull left (the way back has come
    // that far in the hundredth of a second).
    model.handle(.scroll(translation: CGSize(width: -0.3, height: 0), source: .momentum), at: 1.04)
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .momentum), at: 1.05)
    for time in [1.05, 1.1, 3] {
      model.advance(to: time)
      goingBack.advance(to: time)
      #expect(model.position == goingBack.position)
    }
  }

  @Test("Momentum that stops without an end lets the content go back by itself")
  func heldContentGoesBackWhenMomentumStops() {
    var model = makeModelReleasedComingBack()
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    let shown = rubberBand(18)

    // Nothing more arrives. For a tenth of a second the content waits.
    model.advance(to: 1.09)
    #expect(isClose(model.position.center.x, 1000 - shown / 0.4))
    #expect(model.isMoving)

    // Then it goes back from rest.
    for elapsed in [0.01, 0.05, 0.2] {
      model.advance(to: 1.14 + elapsed)
      let left = springDistance(from: shown, speed: 0, frequency: Self.settleFrequency, after: elapsed)
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)
  }

  @Test("Momentum that ends while it holds the content past the edge lets it go back at once")
  func heldContentGoesBackAtMomentumEnd() {
    var model = makeModelReleasedComingBack()
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    let shown = rubberBand(18)

    // It does not wait out the tenth of a second: it goes back from rest
    // now.
    model.handle(.gestureEnded(velocity: nil), at: 1.05)
    for elapsed in [0.005, 0.02, 0.05, 0.1] {
      model.advance(to: 1.05 + elapsed)
      let left = springDistance(from: shown, speed: 0, frequency: Self.settleFrequency, after: elapsed)
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
    // A second end leaves it alone.
    var goingBack = model
    model.handle(.gestureEnded(velocity: nil), at: 1.16)
    model.advance(to: 1.3)
    goingBack.advance(to: 1.3)
    #expect(model.position == goingBack.position)
  }

  @Test("Momentum that ends with held content within a hundredth of a point of the edge leaves it at rest")
  func heldWithinHundredthEndsAtRest() {
    for (shown, goesBack) in [(0.009, false), (0.011, true)] {
      var model = makeModelReleasedComingBack()
      model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
      // Held where the content shows `shown` past the edge: 800 / 0.55 s /
      // (800 - s) points of pull show as s.
      let pull = 800 / 0.55 * shown / (800 - shown)
      model.handle(
        .scroll(translation: CGSize(width: -(18 - pull), height: 0), source: .momentum), at: 1.05
      )
      #expect(isClose(model.position.center.x, 1000 - shown / 0.4, tolerance: 1e-9), "shown \(shown)")
      #expect(model.isMoving, "shown \(shown)")

      // Within a hundredth the end puts the content at rest at once. Beyond
      // it the end starts a way back as from any pull, though one from 0.011
      // points, well inside the quarter point the content rests within, is
      // over almost at once.
      model.handle(.gestureEnded(velocity: nil), at: 1.06)
      #expect(model.isMoving == goesBack, "shown \(shown)")
      #expect((model.position.center.x == 1000) == (goesBack == false), "shown \(shown)")
      model.advance(to: 3)
      #expect(model.isMoving == false, "shown \(shown)")
      #expect(model.position.center.x == 1000, "shown \(shown)")
    }
  }

  @Test("Momentum that leaves held content a hair past the edge moves it on from the edge")
  func hairlineHoldMovesOn() {
    // Held at 18 points of pull, the next input brings the pull to within a
    // few units in the last place of the edge, on either side of it. A pull
    // that small shows as no pull at all, so what the content shows no
    // longer tells which side of the edge it is held on. Each step of
    // `hair` moves the centre by about one unit in the last place.
    let hair = 1000.0.ulp * 0.4
    var heldShowingNoPull = 0
    for steps in -40...40 {
      var model = makeModelReleasedComingBack()
      model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
      model.handle(
        .scroll(translation: CGSize(width: -(18 + Double(steps) * hair), height: 0), source: .momentum),
        at: 1.05
      )
      #expect(isClose(model.position.center.x, 1000, tolerance: 1e-12), "steps \(steps)")
      if model.isMoving, model.position.center.x == 1000 {
        heldShowingNoPull += 1
      }

      // The next input moves the content on from the edge, whatever the
      // hair left.
      model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.06)
      #expect(isClose(model.position.center.x, 1000 + 12 / 0.4), "steps \(steps)")
      #expect(model.isMoving == false, "steps \(steps)")
    }
    // Some of those steps held the content where it shows no pull: the case
    // this test is for.
    #expect(heldShowingNoPull > 0)
  }

  @Test("At the bottom edge too, momentum that leaves held content a hair past it moves it on from the edge")
  func hairlineHoldMovesOnAtBottomEdge() {
    // The vertical upper limit, 2000, where a pull of one unit in the last
    // place shows as none. Each step of `hair` moves the centre by about
    // half a unit in the last place.
    let hair = 2000.0.ulp * 0.4 / 2
    var heldShowingNoPull = 0
    for steps in -80...80 {
      var model = makeZoomedModel()
      model.handle(.scroll(translation: CGSize(width: 0, height: -5000), source: .wheel), at: 0)
      model.handle(.scroll(translation: CGSize(width: 0, height: -60), source: .gesture), at: 1)
      for step in 1...3 {
        model.handle(
          .scroll(translation: CGSize(width: 0, height: 10), source: .gesture),
          at: 1 + Double(step) * 0.01
        )
      }
      model.handle(.gestureEnded(velocity: nil), at: 1.03)
      model.handle(.scroll(translation: CGSize(width: 0, height: 12), source: .momentum), at: 1.04)
      model.handle(
        .scroll(translation: CGSize(width: 0, height: 18 + Double(steps) * hair), source: .momentum),
        at: 1.05
      )
      #expect(isClose(model.position.center.y, 2000, tolerance: 1e-12), "steps \(steps)")
      if model.isMoving, model.position.center.y == 2000 {
        heldShowingNoPull += 1
      }

      model.handle(.scroll(translation: CGSize(width: 0, height: 12), source: .momentum), at: 1.06)
      #expect(isClose(model.position.center.y, 2000 - 12 / 0.4), "steps \(steps)")
      #expect(model.isMoving == false, "steps \(steps)")
    }
    #expect(heldShowingNoPull > 0)
  }

  @Test("Momentum that takes held content inside goes on even when too slow to tell a speed")
  func slowMomentumThatReachesInsideTakesOver() {
    var model = makeModelReleasedComingBack()
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    model.handle(.scroll(translation: CGSize(width: -17.95, height: 0), source: .momentum), at: 1.05)
    // Held 0.05 points out. 0.06 points 80 ms later: under a point per second.
    model.handle(.scroll(translation: CGSize(width: -0.06, height: 0), source: .momentum), at: 1.13)
    #expect(isClose(model.position.center.x, 1000 + 0.01 / 0.4, tolerance: 1e-9))
    #expect(model.isMoving == false)
  }

  @Test("Momentum too weak to go on lets the content it held go back at the speed it shows")
  func weakMomentumAfterHoldGoesBack() {
    var model = makeModelReleasedComingBack()
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    let shown = rubberBand(18)
    // 0.3 points in a hundredth of a second: 30 points per second, which
    // carry 15 points, short of the 18 left.
    model.handle(.scroll(translation: CGSize(width: -0.3, height: 0), source: .momentum), at: 1.05)
    let speed = -30 * 0.55 * pow(1 - shown / 800, 2)
    for elapsed in [0.01, 0.05, 0.2] {
      model.advance(to: 1.05 + elapsed)
      let left = springDistance(
        from: shown, speed: speed, frequency: Self.settleFrequency, after: elapsed
      )
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
    // The rest of that momentum is dropped.
    var goingBack = model
    model.handle(.scroll(translation: CGSize(width: -40, height: 0), source: .momentum), at: 1.26)
    goingBack.advance(to: 1.26)
    #expect(model.position == goingBack.position)
  }

  @Test("Momentum that turns outward lets the content it held go back from rest")
  func outwardMomentumAfterHoldGoesBack() {
    var model = makeModelReleasedComingBack()
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    let shown = rubberBand(18)
    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .momentum), at: 1.05)
    #expect(isClose(model.position.center.x, 1000 - shown / 0.4))
    for elapsed in [0.01, 0.05, 0.2] {
      model.advance(to: 1.05 + elapsed)
      let left = springDistance(from: shown, speed: 0, frequency: Self.settleFrequency, after: elapsed)
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
  }

  @Test("Momentum takes the content over only when, fading as a deceleration does, it carries it more than half a point inside")
  func takeOverThreshold() {
    // A hundredth of a second after the release the way back shows `shown`
    // of pull, and the momentum takes over from there: it has to carry the
    // pull that shows as `shown`, plus half a point.
    let interval = 0.01
    let shown = wayBackFromRelease(after: interval)
    let pull = 800 / 0.55 * shown / (800 - shown)
    let needed = (pull + 0.5) * -Self.decay * interval

    var short = makeModelReleasedComingBack()
    var goingBack = short
    short.handle(
      .scroll(translation: CGSize(width: -0.99 * needed, height: 0), source: .momentum), at: 1.04
    )
    short.advance(to: 1.1)
    goingBack.advance(to: 1.1)
    #expect(short.position == goingBack.position)

    var enough = makeModelReleasedComingBack()
    enough.handle(
      .scroll(translation: CGSize(width: -1.01 * needed, height: 0), source: .momentum), at: 1.04
    )
    // Taken over: held where the way back had brought it.
    enough.advance(to: 1.1)
    #expect(isClose(enough.position.center.x, 1000 - shown / 0.4))
    #expect(enough.isMoving)
  }

  @Test("Momentum too soon after the release to tell a speed by takes its speed from the stretch of input")
  func momentumTooSoonUsesEstimate() {
    var model = makeModelReleasedComingBack()
    // 2 ms after the release: the stretch since 1.00 moved from 60 points of
    // pull to 18, 1312 points per second, which carry it far inside.
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.032)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(18) / 0.4))
    #expect(model.isMoving)
  }

  @Test("Momentum that holds the content counts toward the speed of an input too soon to tell its own")
  func heldMomentumFeedsEstimate() {
    var model = makeModelReleasedComingBack()
    // Held at 18 points of pull, then at 10: 8 points in 80 ms, 100 points
    // per second, which carry 50.
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    model.handle(.scroll(translation: CGSize(width: -8, height: 0), source: .momentum), at: 1.12)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(10) / 0.4))

    // 2 ms later: too soon for its own speed. The stretch of input since
    // 1.04 moved the pull from 18 to 9 in 82 ms, 110 points per second,
    // which carry 55 points: more than the 9 left.
    model.handle(.scroll(translation: CGSize(width: -1, height: 0), source: .momentum), at: 1.122)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(9) / 0.4))
    #expect(model.isMoving)
  }

  @Test("Without animation momentum leaves a way back that is under way alone")
  func momentumWithoutAnimationLeavesWayBack() {
    var model = makeModelReleasedComingBack()
    model.animates = false
    var goingBack = model
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    for time in [1.04, 1.1, 3] {
      model.advance(to: time)
      goingBack.advance(to: time)
      #expect(model.position == goingBack.position)
    }
  }

  @Test("A momentum input with no movement along an axis leaves that axis as it is")
  func momentumWithoutMovementAlongAxisChangesNothing() {
    var model = makeModelReleasedComingBack()
    var goingBack = model
    // Momentum that only moves the other axis, or nothing.
    model.handle(.scroll(translation: .zero, source: .momentum), at: 1.033)
    model.handle(.scroll(translation: CGSize(width: 0, height: -4), source: .momentum), at: 1.035)
    goingBack.advance(to: 1.035)
    #expect(model.position.center.x == goingBack.position.center.x)
    #expect(isClose(model.position.center.y, 1500 + 4 / 0.4))

    // Momentum along the axis still takes it over: 12 points in 5 ms carry
    // it far inside.
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(18) / 0.4))
  }

  @Test("Momentum just after a release is not counted on top of what the way back moved")
  func promptMomentumIsNotCountedTwice() {
    // Fingers coming back at 1000 points per second lift with little pull
    // left. The way back, at the speed the content showed, is inside the
    // edge before the first momentum input arrives.
    let interval = 1.0 / 120
    let step = 1000 * interval
    for pull in [0.5, 5.0] {
      var model = makeZoomedModel()
      model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
      model.handle(
        .scroll(translation: CGSize(width: pull + 3 * step, height: 0), source: .gesture), at: 1
      )
      for index in 1...3 {
        model.handle(
          .scroll(translation: CGSize(width: -step, height: 0), source: .gesture),
          at: 1 + Double(index) * interval
        )
      }
      model.handle(.gestureEnded(velocity: nil), at: 1 + 3 * interval)

      // The momentum goes on from the pull the fingers left.
      model.handle(
        .scroll(translation: CGSize(width: -step, height: 0), source: .momentum),
        at: 1 + 4 * interval
      )
      #expect(isClose(model.position.center.x, 1000 + (step - pull) / 0.4), "pull \(pull)")
      model.handle(
        .scroll(translation: CGSize(width: -step, height: 0), source: .momentum),
        at: 1 + 5 * interval
      )
      #expect(isClose(model.position.center.x, 1000 + (2 * step - pull) / 0.4), "pull \(pull)")
    }
  }

  @Test("Momentum that comes late, after the way back has gone inside, moves the content on from where it is")
  func lateMomentumAfterWayBackInsideDoesNotMoveBack() {
    // Fingers coming back at 1000 points per second lift half a point past
    // the edge, and the way back passes inside. The first momentum input
    // comes 50 ms later, when the way back is about 12 points inside:
    // farther than the momentum's 8.3 points would put the content from
    // where the fingers left it.
    let interval = 1.0 / 120
    let step = 1000 * interval
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    model.handle(
      .scroll(translation: CGSize(width: 0.5 + 3 * step, height: 0), source: .gesture), at: 1
    )
    for index in 1...3 {
      model.handle(
        .scroll(translation: CGSize(width: -step, height: 0), source: .gesture),
        at: 1 + Double(index) * interval
      )
    }
    model.handle(.gestureEnded(velocity: nil), at: 1 + 3 * interval)
    let late = 1 + 3 * interval + 0.05
    var goingBack = model
    goingBack.advance(to: late)
    let inside = Double(goingBack.position.center.x - 1000) * 0.4
    #expect(inside > step - 0.5)

    // The content stays where the way back was, and the momentum has the
    // axis.
    model.handle(.scroll(translation: CGSize(width: -step, height: 0), source: .momentum), at: late)
    #expect(
      isClose(
        model.position.center.x, Double(goingBack.position.center.x), tolerance: 1e-12
      )
    )
    #expect(model.isMoving == false)
    model.handle(
      .scroll(translation: CGSize(width: -step, height: 0), source: .momentum), at: late + interval
    )
    #expect(isClose(model.position.center.x, 1000 + (inside + step) / 0.4))
  }

  @Test("Momentum back inside moves a way back that first went farther out on from where it is")
  func momentumDoesNotUndoOutwardWayBack() {
    // Fingers moving out at 8000 points per second lift, so the way back
    // first carries the content farther out.
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: 5000, height: 0), source: .wheel), at: 0)
    let interval = 1.0 / 120
    model.handle(.scroll(translation: CGSize(width: 10, height: 0), source: .gesture), at: 1)
    for index in 1...8 {
      model.handle(
        .scroll(translation: CGSize(width: 8000 * interval, height: 0), source: .gesture),
        at: 1 + Double(index) * interval
      )
    }
    model.handle(.gestureEnded(velocity: nil), at: 1 + 8 * interval)
    let released = Double(1000 - model.position.center.x) * 0.4
    var goingBack = model
    goingBack.advance(to: 1 + 9 * interval)
    let before = Double(1000 - goingBack.position.center.x) * 0.4
    #expect(before > released)

    // Momentum of 20 points back inside moves the pull that shows as
    // `before` by 20 points: 800 / 0.55 s / (800 - s) points of pull show
    // as s.
    model.handle(
      .scroll(translation: CGSize(width: -20, height: 0), source: .momentum),
      at: 1 + 9 * interval
    )
    let pull = 800 / 0.55 * before / (800 - before)
    #expect(isClose(model.position.center.x, 1000 - rubberBand(pull - 20) / 0.4))
    // That is a few points on screen, not the way back's whole excursion.
    #expect(before - Double(1000 - model.position.center.x) * 0.4 < 20 * 0.55)
  }

  @Test("At the right edge too, momentum back inside does not undo a way back that went farther out")
  func momentumDoesNotUndoOutwardWayBackAtRightEdge() {
    var model = makeZoomedModel()
    model.handle(.scroll(translation: CGSize(width: -5000, height: 0), source: .wheel), at: 0)
    let interval = 1.0 / 120
    model.handle(.scroll(translation: CGSize(width: -10, height: 0), source: .gesture), at: 1)
    for index in 1...8 {
      model.handle(
        .scroll(translation: CGSize(width: -8000 * interval, height: 0), source: .gesture),
        at: 1 + Double(index) * interval
      )
    }
    model.handle(.gestureEnded(velocity: nil), at: 1 + 8 * interval)
    let released = Double(model.position.center.x - 3000) * 0.4
    var goingBack = model
    goingBack.advance(to: 1 + 9 * interval)
    let before = Double(goingBack.position.center.x - 3000) * 0.4
    #expect(before > released)

    model.handle(
      .scroll(translation: CGSize(width: 20, height: 0), source: .momentum),
      at: 1 + 9 * interval
    )
    // 800 / 0.55 s / (800 - s) points of pull show as s.
    let pull = 800 / 0.55 * before / (800 - before)
    #expect(isClose(model.position.center.x, 3000 + rubberBand(pull - 20) / 0.4))
  }

  @Test("A release past the edge on a host that gives a velocity leaves later momentum alone")
  func velocityHostReleaseDropsMomentum() {
    var model = makePulledModel()
    // Outward: the way back.
    model.handle(.gestureEnded(velocity: CGSize(width: 2000, height: 0)), at: 1.05)
    var goingBack = model
    model.handle(.scroll(translation: CGSize(width: -200, height: 0), source: .momentum), at: 1.06)
    goingBack.advance(to: 1.06)
    #expect(model.position == goingBack.position)
  }

  @Test("Momentum after a release with resting fingers does not take the content over")
  func restingReleaseDropsMomentum() {
    var model = makePulledModel()
    // A quarter of a second after the fingers last moved: no velocity.
    model.handle(.gestureEnded(velocity: nil), at: 1.3)
    var goingBack = model
    // Enough to carry the content back inside, had the fingers been moving.
    model.handle(.scroll(translation: CGSize(width: -200, height: 0), source: .momentum), at: 1.31)
    goingBack.advance(to: 1.31)
    #expect(model.position == goingBack.position)
    model.advance(to: 3)
    #expect(model.position.center.x == 1000)
  }

  @Test("A touch stops content the momentum holds, and lifting lets it go back")
  func touchStopsHeldContent() {
    var model = makeModelReleasedComingBack()
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.04)
    let shown = rubberBand(18)
    let held = model.position

    model.handle(.touchDown, at: 1.045)
    #expect(model.isMoving == false)
    #expect(model.position == held)
    // The rest of that momentum moves nothing.
    model.handle(.scroll(translation: CGSize(width: -12, height: 0), source: .momentum), at: 1.05)
    #expect(model.position == held)

    model.handle(.gestureEnded(velocity: nil), at: 1.3)
    for elapsed in [0.01, 0.05, 0.2] {
      model.advance(to: 1.3 + elapsed)
      let left = springDistance(from: shown, speed: 0, frequency: Self.settleFrequency, after: elapsed)
      #expect(isClose(model.position.center.x, 1000 - left / 0.4))
    }
  }

  @Test("Without animation the release is at the edge at once, and the momentum goes on from there")
  func momentumCarriesOnWithoutAnimation() {
    var model = makeModelReleasedComingBack(animates: false)
    #expect(model.isMoving == false)
    #expect(model.position.center.x == 1000)

    for step in 1...5 {
      model.handle(
        .scroll(translation: CGSize(width: -10, height: 0), source: .momentum),
        at: 1.03 + Double(step) * 0.01
      )
    }
    #expect(isClose(model.position.center.x, 1000 + 50 / 0.4))
    #expect(model.isMoving == false)
  }

  // MARK: - Zoom

  @Test("A zoom that settles keeps the content under the pinch in place")
  func zoomSettleKeepsAnchor() throws {
    var model = makeZoomedModel()
    model.handle(.zoomStep(factor: 100, anchor: Self.canvasCenter), at: 0)
    #expect(isClose(model.position.scale, 1.6))

    let anchor = CGPoint(x: 600, y: 300)
    model.handle(.magnify(factor: 1.5, anchor: anchor), at: 1)
    #expect(model.position.scale > 1.6)
    let pinched = try #require(model.viewport(contentScaleFactor: 2))
      .contentPoint(fromCanvasPoint: anchor)

    model.handle(.gestureEnded(velocity: nil), at: 1.01)
    #expect(model.isMoving)
    model.advance(to: 3)
    #expect(model.isMoving == false)
    #expect(model.position.scale == model.scaleRange.upperBound)

    let settled = try #require(model.viewport(contentScaleFactor: 2))
      .contentPoint(fromCanvasPoint: anchor)
    #expect(isClose(settled.x, Double(pinched.x)))
    #expect(isClose(settled.y, Double(pinched.y)))
  }

  @Test("A second end of the gesture leaves a settling zoom alone")
  func secondEndLeavesZoomSettle() {
    var model = makeZoomedModel()
    model.handle(.zoomStep(factor: 100, anchor: Self.canvasCenter), at: 0)
    model.handle(.magnify(factor: 1.5, anchor: Self.canvasCenter), at: 1)
    model.handle(.gestureEnded(velocity: nil), at: 1.01)
    var reference = model

    model.advance(to: 1.05)
    model.handle(.gestureEnded(velocity: nil), at: 1.05)
    for time in [1.1, 1.2, 2] {
      model.advance(to: time)
      reference.advance(to: time)
      #expect(model.position == reference.position)
    }
  }

  @Test("A wheel that stops a settling zoom puts it at its limit")
  func wheelStopsSettlingZoomAtLimit() {
    var model = makeZoomedModel()
    model.handle(.zoomStep(factor: 100, anchor: Self.canvasCenter), at: 0)
    model.handle(.magnify(factor: 1.5, anchor: Self.canvasCenter), at: 1)
    model.handle(.gestureEnded(velocity: nil), at: 1.01)
    model.advance(to: 1.05)
    #expect(model.isMoving)
    #expect(model.position.scale > 1.6)

    // A wheel has no end that would let the zoom finish its way back.
    model.handle(.scroll(translation: CGSize(width: 0, height: -3), source: .wheel), at: 1.05)
    #expect(model.isMoving == false)
    #expect(model.position.scale == model.scaleRange.upperBound)
    // At 1.6 the canvas shows 500 units either way.
    #expect((250...3750).contains(model.position.center.x))
    #expect((250...2750).contains(model.position.center.y))

    let stopped = model.position
    model.advance(to: 3)
    #expect(model.position == stopped)
  }

  @Test("A wheel that stops a zoom puts an axis the content fits on at its centre")
  func wheelRestsFittingAxis() {
    var model = makeToggleStoppedOffCentre()
    #expect(model.position.scale < 800.0 / 3000.0)
    #expect(model.position.center.y < 1450)

    model.handle(.scroll(translation: CGSize(width: -3, height: 0), source: .wheel), at: 1.15)
    #expect(model.isMoving == false)
    #expect(model.position.center.y == 1500)
  }

  @Test("A zoom toggle moves the zoom along its logarithm and the centre in a line, in step")
  func zoomMotionKeepsStep() {
    var model = CanvasNavigation(contentSize: Self.content, canvasSize: Self.canvas)
    // To 0.6 about the top-left quarter: the centre goes from (2000, 1500)
    // to where that point stays put.
    let anchor = CGPoint(x: 200, y: 300)
    model.handle(.toggleZoom(anchor: anchor), at: 0)
    var end = model
    end.advance(to: 5)
    #expect(isClose(end.position.scale, 0.6))
    let target = end.position.center

    for elapsed in [0.02, 0.05, 0.1, 0.2, 0.4] {
      model.advance(to: elapsed)
      // The share of the way left: (1 + bt) e^(-bt).
      let left = springDistance(from: 1, speed: 0, frequency: Self.settleFrequency, after: elapsed)
      #expect(isClose(model.position.scale, 0.6 * pow(0.2 / 0.6, left)))
      #expect(isClose(model.position.center.x, Double(target.x) + (2000 - Double(target.x)) * left))
      #expect(isClose(model.position.center.y, Double(target.y) + (1500 - Double(target.y)) * left))
    }
  }

  // MARK: - Input that is not usable

  @Test("An anchor that is not a number zooms nothing")
  func brokenAnchorIsIgnored() {
    var model = makeZoomedModel()
    let before = model.position

    model.handle(.magnify(factor: 1.1, anchor: CGPoint(x: CGFloat.nan, y: 100)), at: 1)
    #expect(model.position == before)
    model.handle(.gestureEnded(velocity: nil), at: 1.1)
    #expect(model.position == before)
    #expect(model.isMoving == false)

    model.handle(.zoomStep(factor: 2, anchor: CGPoint(x: CGFloat.infinity, y: 0)), at: 2)
    #expect(model.position == before)

    model.handle(.toggleZoom(anchor: CGPoint(x: CGFloat.nan, y: CGFloat.nan)), at: 3)
    #expect(model.position == before)
    #expect(model.isMoving == false)
  }

  @Test("An anchor far off the canvas zooms about it without losing the position")
  func farAnchorStaysFinite() {
    var model = makeZoomedModel()
    let before = model.position

    // A pinch that does not change the zoom moves nothing, wherever it is.
    model.handle(.magnify(factor: 1, anchor: CGPoint(x: 1e17, y: 10)), at: 1)
    #expect(model.position == before)
    model.handle(.gestureEnded(velocity: nil), at: 1.1)

    // Zooming in about a point that far to the right ends at the right edge:
    // at 0.44 the canvas shows 1818 units, so the centre stops at 3091.
    model.handle(.magnify(factor: 1.1, anchor: CGPoint(x: 1e308, y: 400)), at: 2)
    #expect(isClose(model.position.scale, 0.44))
    #expect(isClose(model.position.center.x, 4000 - 800 / 0.88))
    #expect(isClose(model.position.center.y, 1500))
  }

  @Test("A pull without end stays a number, under the canvas, and comes back")
  func endlessPullStaysFinite() {
    var model = makeZoomedModel()
    let endless = CGFloat.greatestFiniteMagnitude

    // The pull stops growing where the rubber band stops telling pulls
    // apart, which shows 0.999 of the canvas.
    model.handle(.scroll(translation: CGSize(width: endless, height: 0), source: .gesture), at: 1)
    var pull = (1000 - model.position.center.x) * 0.4
    #expect(abs(pull - 799.2) < 0.01)

    // The other way, from as far out as that.
    model.handle(
      .scroll(translation: CGSize(width: -endless, height: 0), source: .gesture), at: 1.01
    )
    pull = (model.position.center.x - 3000) * 0.4
    #expect(abs(pull - 799.2) < 0.01)

    model.handle(.gestureEnded(velocity: nil), at: 2)
    model.advance(to: 5)
    #expect(model.isMoving == false)
    #expect(model.position.center == CGPoint(x: 3000, y: 1500))
  }

  // MARK: - Time

  @Test("Time never runs backwards, and a time that is not a number is no time")
  func timeNeverRunsBackwards() {
    var model = makePulledModel()
    model.handle(.gestureEnded(velocity: nil), at: 1.5)

    model.advance(to: 1.6)
    let shown = model.position
    model.advance(to: 1.55)
    #expect(model.position == shown)
    model.advance(to: .nan)
    model.advance(to: .infinity)
    #expect(model.position == shown)
    #expect(model.isMoving)

    // An input with no time happens at the latest one.
    model.handle(.touchDown, at: .nan)
    #expect(model.isMoving == false)
    #expect(model.position == shown)

    // An input before the latest time acts at the latest time.
    model.handle(.gestureEnded(velocity: nil), at: 1.2)
    #expect(model.isMoving)
    model.advance(to: 1.6)
    #expect(model.position == shown)
    model.advance(to: 4)
    #expect(model.position.center == CGPoint(x: 1000, y: 1500))
  }
}
