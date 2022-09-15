
import Verge

public final class UIStateStore<State: Equatable, Activity>: Store<State, Activity> {
  
  public init(
    initialState: State,
    logger: StoreLogger? = nil
  ) {
    super.init(initialState: initialState, backingStorageRecursiveLock: VergeNoLock().asAny(), logger: logger)
  }
  
}
