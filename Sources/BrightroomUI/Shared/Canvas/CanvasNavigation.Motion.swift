import CoreGraphics
import Foundation
import struct SwiftUI.Spring

// The motions `CanvasNavigation` runs, as closed forms of time: each is a
// value fixed when the motion starts, and answers for any time on the
// caller's clock. A centre axis moves as an `AxisMotion`; the zoom's
// logarithm moves as a `SpringBack`.
extension CanvasNavigation {

  /// What a motion shows at one time.
  struct MotionSample: Equatable, Sendable {
    var value: CGFloat
    /// The value's change per second.
    var velocity: CGFloat
    /// Whether the motion has ended; `value` is then where it rests.
    var isFinished: Bool
  }

  /// A motion that keeps a fixed share of its velocity each millisecond, the
  /// way a scroll view decelerates after the fingers lift.
  ///
  /// With `k = 1000 ln(rate)`, which is negative, the value at `t` seconds
  /// is `start + velocity (e^(kt) - 1) / k`. It approaches `destination`
  /// without reaching it, so the motion ends `endDistance` short of it.
  struct Deceleration: Equatable, Sendable {

    var start: CGFloat

    /// The value's change per second at `startTime`.
    var velocity: CGFloat

    var startTime: TimeInterval

    /// The share of the velocity kept each millisecond, above 0 and below 1.
    var rate: CGFloat

    /// How close to `destination` the motion ends.
    var endDistance: CGFloat

    /// The values the motion stays within.
    var limits: ClosedRange<CGFloat>

    /// Nil when nothing would move: a velocity that would not carry the
    /// value `endDistance` away, a rate that is not above 0 and below 1, an
    /// `endDistance` that is not positive, or a value that is not finite.
    init?(
      start: CGFloat,
      velocity: CGFloat,
      startTime: TimeInterval,
      rate: CGFloat,
      endDistance: CGFloat,
      limits: ClosedRange<CGFloat>
    ) {
      guard
        rate > 0, rate < 1,
        endDistance > 0,
        start.isFinite, velocity.isFinite, startTime.isFinite,
        // The whole way is `|velocity| / -k`.
        abs(velocity) > -1000 * log(rate) * endDistance
      else {
        return nil
      }
      self.start = start
      self.velocity = velocity
      self.startTime = startTime
      self.rate = rate
      self.endDistance = endDistance
      self.limits = limits
    }

    /// The decay per second of the velocity's logarithm; negative.
    private var decay: CGFloat {
      1000 * log(rate)
    }

    /// The value the motion approaches.
    var destination: CGFloat {
      start - velocity / decay
    }

    /// How long the motion runs.
    var duration: TimeInterval {
      TimeInterval(log(-decay * endDistance / abs(velocity)) / decay)
    }

    var endTime: TimeInterval {
      startTime + duration
    }

    func value(at time: TimeInterval) -> CGFloat {
      let value = start + velocity * expm1(decay * elapsed(at: time)) / decay
      return min(max(value, limits.lowerBound), limits.upperBound)
    }

    func velocity(at time: TimeInterval) -> CGFloat {
      velocity * exp(decay * elapsed(at: time))
    }

    /// The seconds after `startTime` at which the motion reaches `value`, or
    /// nil when `value` is not on its way (behind the start, or at or past
    /// the destination).
    func time(reaching value: CGFloat) -> TimeInterval? {
      let share = decay * (value - start) / velocity
      guard share <= 0, share > -1 else { return nil }
      return TimeInterval(log1p(share) / decay)
    }

    func sample(at time: TimeInterval) -> MotionSample {
      let isFinished = (time < endTime) == false
      return MotionSample(
        value: value(at: time),
        velocity: isFinished ? 0 : velocity(at: time),
        isFinished: isFinished
      )
    }

    private func elapsed(at time: TimeInterval) -> CGFloat {
      // Written so that a time that is not a number counts as the end.
      let elapsed = time - startTime
      if elapsed <= 0 { return 0 }
      return CGFloat(elapsed < duration ? elapsed : duration)
    }
  }

  /// A spring toward a resting value that starts with a velocity. SwiftUI's
  /// `Spring` computes it.
  struct SpringBack: Equatable, Sendable {

    var spring: Spring

    /// The value the spring comes to rest at.
    var rest: CGFloat

    var start: CGFloat

    /// The value's change per second at `startTime`.
    var velocity: CGFloat

    var startTime: TimeInterval

    /// From this time on the spring rests at `rest`.
    var endTime: TimeInterval

    /// - Parameters:
    ///   - base: The spring to use, critically damped. A motion too fast for
    ///     it to stay within `reach` gets the same spring sped up instead, so
    ///     the velocity is kept.
    ///   - tolerance: How close to `rest` counts as there. The motion ends
    ///     once it is that close and stays so.
    ///   - reach: How far from `rest` the motion can be shown at all: for a
    ///     centre axis, the canvas along it, which a rubber band never
    ///     reaches. A motion that moves away from its rest goes no farther
    ///     than `CanvasNavigation.maximumOvershootFraction` of what is left
    ///     of the reach where it starts. One that comes in passes its rest
    ///     by no more than that share of the reach. A motion that starts at
    ///     the reach or beyond keeps no velocity away from its rest.
    init(
      base: Spring,
      rest: CGFloat,
      start: CGFloat,
      velocity: CGFloat,
      startTime: TimeInterval,
      tolerance: CGFloat,
      reach: CGFloat = .infinity
    ) {
      var velocity = velocity.isFinite ? velocity : 0
      let displacement = start - rest
      // Positive while the motion moves away from its rest.
      let speedAway = displacement == 0 ? abs(velocity) : (displacement < 0 ? -velocity : velocity)
      // How many times faster than `base` the spring has to be.
      var quickening = 1.0
      if speedAway != 0, reach.isFinite {
        // A critically damped spring of angular frequency `b` that moves
        // away from its rest at `u` goes no more than `u / (b e)` farther.
        // One that comes in at `u` passes its rest by no more than that.
        let room = CanvasNavigation.maximumOvershootFraction
          * (speedAway > 0 ? reach - abs(displacement) : reach)
        let needed = Double(abs(speedAway) / room) / M_E * base.response / (2 * .pi)
        if room > 0, needed.isFinite {
          quickening = max(needed, 1)
        } else {
          velocity = 0
        }
      }

      self.spring = quickening > 1
        ? Spring(response: base.response / quickening, dampingRatio: base.dampingRatio)
        : base
      self.rest = rest
      self.start = start
      self.velocity = velocity
      self.startTime = startTime

      // `settlingDuration` looks at the spring every tenth of a second. A
      // quickened spring can be done within one, so the base spring answers
      // for it: a spring `q` times faster is the base spring at a `q`th of
      // the velocity, played `q` times faster.
      let target = Double(rest - start)
      let baseVelocity = Double(velocity) / quickening
      var settling = 0.0
      if tolerance > 0 {
        let estimate = base.settlingDuration(
          target: target, initialVelocity: baseVelocity, epsilon: Double(tolerance)
        )
        settling = estimate.isFinite ? max(estimate, 0) : 0
        // It also takes a spring that is passing its rest at one of those
        // moments for settled, so look on until the spring is there to stay.
        var looks = 0
        while
          looks < 100,
          Self.hasSettled(
            base, target: target, velocity: baseVelocity, tolerance: Double(tolerance),
            at: settling
          ) == false
        {
          settling += 0.1
          looks += 1
        }
      }
      self.endTime = startTime + settling / quickening
    }

    func value(at time: TimeInterval) -> CGFloat {
      // Written so that a time that is not a number counts as the end.
      guard time < endTime else { return rest }
      return start + spring.value(
        target: rest - start,
        initialVelocity: velocity,
        time: max(time - startTime, 0)
      )
    }

    func velocity(at time: TimeInterval) -> CGFloat {
      guard time < endTime else { return 0 }
      return spring.velocity(
        target: rest - start,
        initialVelocity: velocity,
        time: max(time - startTime, 0)
      )
    }

    func sample(at time: TimeInterval) -> MotionSample {
      MotionSample(
        value: value(at: time),
        velocity: velocity(at: time),
        isFinished: (time < endTime) == false
      )
    }

    /// Whether `spring`, `time` seconds after it left for `target` at
    /// `velocity`, is within `tolerance` of its rest and stays there.
    ///
    /// A critically damped spring of angular frequency `b` that moves at `v`
    /// goes no more than `|v| / (b e)` farther from its rest when it moves
    /// away, and passes its rest by no more than that when it comes in.
    private static func hasSettled(
      _ spring: Spring,
      target: Double,
      velocity: Double,
      tolerance: Double,
      at time: TimeInterval
    ) -> Bool {
      let distance = spring.value(target: target, initialVelocity: velocity, time: time) - target
      let speed = spring.velocity(target: target, initialVelocity: velocity, time: time)
      let carried = abs(speed) * spring.response / (2 * .pi * M_E)
      let farthest = distance * speed > 0 ? abs(distance) + carried : max(abs(distance), carried)
      return farthest <= tolerance
    }
  }

  /// How a value shows once it is past the limits it scrolls within: the
  /// pull past a limit is rubber-banded.
  struct RubberBand: Equatable, Sendable {

    /// The values that show as they are.
    var limits: ClosedRange<CGFloat>

    /// What a pull is rubber-banded over, in the value's units. What shows
    /// never passes a limit by this much.
    var dimension: CGFloat

    /// What shows for `value`.
    func shown(for value: CGFloat) -> CGFloat {
      if value < limits.lowerBound {
        return limits.lowerBound
          - CanvasNavigation.rubberBand(limits.lowerBound - value, dimension: dimension)
      }
      if value > limits.upperBound {
        return limits.upperBound
          + CanvasNavigation.rubberBand(value - limits.upperBound, dimension: dimension)
      }
      return value
    }

    /// How much what shows moves for each unit `value` moves: 1 inside the
    /// limits, the rubber band's slope past them.
    func slope(at value: CGFloat) -> CGFloat {
      let pull = max(limits.lowerBound - value, value - limits.upperBound)
      guard pull > 0 else { return 1 }
      return CanvasNavigation.rubberBandSlope(
        showing: CanvasNavigation.rubberBand(pull, dimension: dimension),
        dimension: dimension
      )
    }
  }

  /// The motion of the centre along one axis.
  enum AxisMotion: Equatable, Sendable {

    /// A deceleration. When it would run past a limit, `bounce` takes over at
    /// the moment it reaches the limit, with the velocity it has there. One
    /// that starts past a limit, moving back inside, shows through `band`
    /// until it is inside, the way the fingers moved it there.
    case decelerating(Deceleration, band: RubberBand?, bounce: SpringBack?)

    case springing(SpringBack)

    /// A deceleration from `start` at `velocity`, with the bounce at the
    /// limit it would run past, or nil when nothing would move (see
    /// `Deceleration.init`).
    ///
    /// A `start` past the limits is a pull that a rubber band shows. The
    /// deceleration then moves the pull, as more of the gesture would, and
    /// there is one only when it takes the value back inside: nil otherwise.
    ///
    /// - Parameters:
    ///   - limits: The values the motion scrolls within.
    ///   - endDistance: How close to its destination the deceleration ends.
    ///     A destination past a limit by no more than this takes no bounce:
    ///     the motion then ends just short of the limit.
    ///   - bounce: The spring of the bounce.
    ///   - tolerance: How close to the limit the bounce counts as there.
    ///   - reach: How far past a limit the value can be shown at all: what a
    ///     pull is rubber-banded over, and the room of the bounce.
    static func deceleration(
      from start: CGFloat,
      velocity: CGFloat,
      at time: TimeInterval,
      rate: CGFloat,
      limits: ClosedRange<CGFloat>,
      endDistance: CGFloat,
      bounce: Spring,
      tolerance: CGFloat,
      reach: CGFloat
    ) -> AxisMotion? {
      let isPulled = limits.contains(start) == false
      guard
        let deceleration = Deceleration(
          start: start,
          velocity: velocity,
          startTime: time,
          rate: rate,
          endDistance: endDistance,
          limits: min(start, limits.lowerBound)...max(start, limits.upperBound)
        )
      else {
        return nil
      }
      if isPulled {
        // How far inside the limit it started past the deceleration ends.
        let inside = start < limits.lowerBound
          ? deceleration.destination - limits.lowerBound
          : limits.upperBound - deceleration.destination
        guard inside > endDistance else { return nil }
      }
      let band = isPulled ? RubberBand(limits: limits, dimension: reach) : nil
      let limit = velocity > 0 ? limits.upperBound : limits.lowerBound
      let past = velocity > 0 ? deceleration.destination - limit : limit - deceleration.destination
      guard past > endDistance else {
        return .decelerating(deceleration, band: band, bounce: nil)
      }
      // A start at the limit crosses at once.
      let crossing = time + (deceleration.time(reaching: limit) ?? 0)
      return .decelerating(
        deceleration,
        band: band,
        bounce: SpringBack(
          base: bounce,
          rest: limit,
          start: limit,
          velocity: deceleration.velocity(at: crossing),
          startTime: crossing,
          tolerance: tolerance,
          reach: reach
        )
      )
    }

    func sample(at time: TimeInterval) -> MotionSample {
      switch self {
      case let .decelerating(deceleration, band, bounce):
        if let bounce, (time < bounce.startTime) == false {
          return bounce.sample(at: time)
        }
        var sample = deceleration.sample(at: time)
        if let band {
          sample.velocity *= band.slope(at: sample.value)
          sample.value = band.shown(for: sample.value)
        }
        if bounce != nil {
          sample.isFinished = false
        }
        return sample
      case let .springing(spring):
        return spring.sample(at: time)
      }
    }
  }

  /// The velocity of the scroll input, measured from the translations and
  /// the times of the inputs themselves.
  ///
  /// It is the translation from the newest input at least `window` seconds
  /// old (or the first one) to the last one, over the time between them, so
  /// one input that arrived late or early (the main thread was busy, or
  /// several inputs were delivered together) does not decide it.
  struct VelocityEstimate: Equatable, Sendable {

    /// The stretch of input the velocity is measured over, in seconds.
    static let window: TimeInterval = 0.05

    /// The shortest stretch of input that gives a velocity, in seconds.
    static let minimumSpan: TimeInterval = 0.004

    private struct Sample: Equatable, Sendable {
      var time: TimeInterval
      /// The sum of the translations up to and including this input.
      var position: CGSize
    }

    /// Ordered by time: the newest sample at least `window` old, then the
    /// samples inside it.
    private var samples: [Sample] = []

    /// The translation per second, or nil when the inputs do not span
    /// `minimumSpan`.
    var velocity: CGSize? {
      guard
        let first = samples.first, let last = samples.last,
        last.time - first.time >= Self.minimumSpan
      else {
        return nil
      }
      let span = CGFloat(last.time - first.time)
      return CGSize(
        width: (last.position.width - first.position.width) / span,
        height: (last.position.height - first.position.height) / span
      )
    }

    /// Records an input that moved by `translation` at `time`. The first one
    /// after a reset only marks where the measurement starts.
    mutating func add(_ translation: CGSize, at time: TimeInterval) {
      guard time.isFinite, translation.width.isFinite, translation.height.isFinite else { return }
      guard let last = samples.last else {
        samples.append(Sample(time: time, position: translation))
        return
      }
      let position = CGSize(
        width: last.position.width + translation.width,
        height: last.position.height + translation.height
      )
      if time > last.time {
        samples.append(Sample(time: time, position: position))
      } else {
        // Inputs at one time (delivered together) count as one.
        samples[samples.count - 1].position = position
      }
      let cutoff = samples[samples.count - 1].time - Self.window
      if let reference = samples.lastIndex(where: { $0.time <= cutoff }), reference > 0 {
        samples.removeFirst(reference)
      }
    }

    mutating func reset() {
      samples.removeAll(keepingCapacity: true)
    }
  }
}
