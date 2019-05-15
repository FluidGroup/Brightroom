# TransitionPatch

## Sample

```
let value = ValuePatch(10)
  .progress(start: 0, end: 13)
  .clip(min: 0, max: 1)
  .reverse()
  .transition(start: 30, end: 60)
  .value

// value == 36.92307692307692
```

## Functions

### Make a Progress

Make a value of progress from CGFloat between a range.

```swift
let progress: ProgressPatch = ValuePatch(10)
  .progress(start: 5, end: 15)

// progress.fractionCompleted == 0.5
```

### Make a Transition from progress

Make a value of transition from progress between start and end.

```swift
let value: ValuePatch = ProgressPatch(0.5)
  .transition(start: 10, end: 20)

// value.value == 15
```
