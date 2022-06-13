//
//  AsyncOperation.swift
//  MullvadVPN
//
//  Created by pronebird on 01/06/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation

@objc enum State: Int, Comparable, CustomStringConvertible {
    case initialized
    case pending
    case evaluatingConditions
    case ready
    case executing
    case finished

    static func < (lhs: State, rhs: State) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .initialized:
            return "initialized"
        case .pending:
            return "pending"
        case .evaluatingConditions:
            return "evaluatingConditions"
        case .ready:
            return "ready"
        case .executing:
            return "executing"
        case .finished:
            return "finished"
        }
    }
}

/// A base implementation of an asynchronous operation
class AsyncOperation: Operation {
    /// Mutex lock used for guarding critical sections of operation lifecycle.
    private let operationLock = NSRecursiveLock()

    /// Mutex lock used to guard `state` and `isCancelled` properties.
    ///
    /// This lock must not encompass KVO hooks such as `willChangeValue` and `didChangeValue` to
    /// prevent deadlocks, since KVO observers may synchronously query the operation state on a
    /// different thread.
    ///
    /// `operationLock` should be used along with `stateLock` to ensure internal state consistency
    /// when multiple access to `state` or `isCancelled` is necessary, such as when testing
    /// the value before modifying it.
    private let stateLock = NSRecursiveLock()

    /// Backing variable for `state`.
    /// Access must be guarded with `stateLock`.
    private var _state: State = .initialized

    /// Backing variable for `_isCancelled`.
    /// Access must be guarded with `stateLock`.
    private var __isCancelled: Bool = false

    /// Operation state.
    @objc private var state: State {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }

            return _state
        }
        set(newState) {
            willChangeValue(for: \.state)
            stateLock.lock()
            assert(_state < newState)
            _state = newState
            stateLock.unlock()
            didChangeValue(for: \.state)
        }
    }

    private var _isCancelled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }

            return __isCancelled
        }
        set {
            willChangeValue(for: \.isCancelled)
            stateLock.lock()
            __isCancelled = newValue
            stateLock.unlock()
            didChangeValue(for: \.isCancelled)
        }
    }

    final override var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        // super.isReady should turn true when all dependencies are satisfied.
        guard super.isReady else {
            return false
        }

        // Mark operation ready when cancelled, so that operation queue could flush it faster.
        guard !__isCancelled else {
            return true
        }

        switch _state {
        case .initialized, .pending, .evaluatingConditions:
            return false

        case .ready, .executing, .finished:
            return true
        }
    }

    final override var isExecuting: Bool {
        return state == .executing
    }

    final override var isFinished: Bool {
        return state == .finished
    }

    final override var isCancelled: Bool {
        return _isCancelled
    }

    final override var isAsynchronous: Bool {
        return true
    }

    // MARK: - Observers

    private var _observers: [OperationObserver] = []

    final var observers: [OperationObserver] {
        operationLock.lock()
        defer { operationLock.unlock() }

        return _observers
    }

    final func addObserver(_ observer: OperationObserver) {
        operationLock.lock()
        assert(state < .executing)
        _observers.append(observer)
        operationLock.unlock()
        observer.didAttach(to: self)
    }

    // MARK: - Conditions

    private var _conditions: [OperationCondition] = []

    final var conditions: [OperationCondition] {
        operationLock.lock()
        defer { operationLock.unlock() }

        return _conditions
    }

    func addCondition(_ condition: OperationCondition) {
        operationLock.lock()
        assert(state < .evaluatingConditions)
        _conditions.append(condition)
        operationLock.unlock()
    }

    private func evaluateConditions() {
        guard !_conditions.isEmpty else {
            state = .ready
            return
        }

        state = .evaluatingConditions

        var results = [Bool](repeating: false, count: _conditions.count)
        let group = DispatchGroup()

        for (index, condition) in _conditions.enumerated() {
            group.enter()
            condition.evaluate(for: self) { [weak self] isSatisfied in
                self?.dispatchQueue.async {
                    results[index] = isSatisfied
                    group.leave()
                }
            }
        }

        group.notify(queue: dispatchQueue) { [weak self] in
            self?.didEvaluateConditions(results)
        }
    }

    private func didEvaluateConditions(_ results: [Bool]) {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard state < .ready else { return }

        let conditionsSatisfied = results.allSatisfy { $0 }
        if !conditionsSatisfied {
            cancel()
        }

        state = .ready
    }

    // MARK: -

    let dispatchQueue: DispatchQueue

    init(dispatchQueue: DispatchQueue? = nil) {
        self.dispatchQueue = dispatchQueue ?? DispatchQueue(label: "AsyncOperation.dispatchQueue")
        super.init()

        addObserver(self, forKeyPath: #keyPath(isReady), options: [], context: &Self.observerContext)
    }

    deinit {
        removeObserver(self, forKeyPath: #keyPath(isReady), context: &Self.observerContext)
    }

    // MARK: - KVO

    private static var observerContext = 0

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    )
    {
        if context == &Self.observerContext {
            checkReadiness()
            return
        }

        super.observeValue(
            forKeyPath: keyPath,
            of: object,
            change: change,
            context: context
        )
    }

    @objc class func keyPathsForValuesAffectingIsReady() -> Set<String> {
        return [#keyPath(state)]
    }

    @objc class func keyPathsForValuesAffectingIsExecuting() -> Set<String> {
        return [#keyPath(state)]
    }

    @objc class func keyPathsForValuesAffectingIsFinished() -> Set<String> {
        return [#keyPath(state)]
    }

    // MARK: - Lifecycle

    final override func start() {
        let currentQueue = OperationQueue.current
        let underlyingQueue = currentQueue?.underlyingQueue

        if underlyingQueue == dispatchQueue {
            _start()
        } else {
            dispatchQueue.async {
                self._start()
            }
        }
    }

    private func _start() {
        operationLock.lock()
        if _isCancelled {
            operationLock.unlock()
            finish()
        } else {
            state = .executing

            for observer in _observers {
                observer.operationDidStart(self)
            }
            operationLock.unlock()

            main()
        }
    }

    override func main() {
        // Override in subclasses
    }

    final override func cancel() {
        var notifyDidCancel = false

        operationLock.lock()
        if !_isCancelled {
            _isCancelled = true
            notifyDidCancel = true
        }
        operationLock.unlock()

        super.cancel()

        if notifyDidCancel {
            dispatchQueue.async {
                self.operationDidCancel()

                for observer in self.observers {
                    observer.operationDidCancel(self)
                }
            }
        }
    }

    func finish() {
        var notifyDidFinish = false

        operationLock.lock()
        if state < .finished {
            state = .finished
            notifyDidFinish = true
        }
        operationLock.unlock()

        if notifyDidFinish {
            dispatchQueue.async {
                self.operationDidFinish()

                for observer in self.observers {
                    observer.operationDidFinish(self)
                }
            }
        }
    }

    // MARK: - Private

    func didEnqueue() {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard state == .initialized else {
            return
        }

        state = .pending
    }

    private func checkReadiness() {
        operationLock.lock()

        if state == .pending, !_isCancelled, super.isReady {
            evaluateConditions()
        }

        operationLock.unlock()
    }


    // MARK: - Subclass overrides

    func operationDidCancel() {
        // Override in subclasses.
    }

    func operationDidFinish() {
        // Override in subclasses.
    }
}

extension Operation {
    func addDependencies(_ dependencies: [Operation]) {
        for dependency in dependencies {
            addDependency(dependency)
        }
    }
}

extension Operation {
    var operationName: String {
        return name ?? "\(self)"
    }
}


protocol OperationBlockObserverSupport {}
extension AsyncOperation: OperationBlockObserverSupport {}

extension OperationBlockObserverSupport where Self: AsyncOperation {
    func addBlockObserver(_ observer: OperationBlockObserver<Self>) {
        addObserver(observer)
    }
}
