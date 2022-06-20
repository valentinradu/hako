//
//  SwiftTinyRedux.swift
//
//
//  Created by Valentin Radu on 22/05/2022.
//

import Combine
import Foundation

public protocol Mutation: Hashable {
    associatedtype S: Equatable
    associatedtype SE: SideEffect
    func reduce(state: inout S) -> SE
}

public protocol SideEffect: Hashable {
    associatedtype E
    associatedtype M: Mutation

    func perform(environment: E) async -> M
}

public struct StoreCoordinator: Reducer {
    private var _reducers: [ReducerFactory]

    public init() {
        _reducers = []
    }

    fileprivate init(reducers: [ReducerFactory]) {
        _reducers = reducers
    }

    public func reduce<M>(_ mutation: M) where M: Mutation {
        let wasPerformed = reduce(AnyMutation(mutation))
        assert(wasPerformed)
    }

    fileprivate func reduce(_ mutation: AnyMutation) -> Bool {
        for context in _reducers {
            if context.reducer(with: self).reduce(mutation) {
                return true
            }
        }
        return false
    }

    public func add<OS, OE>(context: StoreContext<OS, OE>) -> StoreCoordinator {
        StoreCoordinator(reducers: _reducers + [ReducerFactory(context)])
    }

    public func add<OS, OE, S, E>(context: PartialContext<OS, OE, S, E>) -> StoreCoordinator {
        StoreCoordinator(reducers: _reducers + [ReducerFactory(context)])
    }
}

public struct PartialContext<OS, OE, S, E> where S: Equatable, OS: Equatable {
    private let _stateKeyPath: WritableKeyPath<OS, S>
    private let _environmentKeyPath: KeyPath<OE, E>
    private var _context: StoreContext<OS, OE>

    public init(context: StoreContext<OS, OE>,
                stateKeyPath: WritableKeyPath<OS, S>,
                environmentKeyPath: KeyPath<OE, E>)
    {
        _stateKeyPath = stateKeyPath
        _environmentKeyPath = environmentKeyPath
        _context = context
    }

    public init(context: StoreContext<OS, OE>) where OS == S, OE == E {
        _stateKeyPath = \.self
        _environmentKeyPath = \.self
        _context = context
    }

    public private(set) var state: S {
        get { _context.state[keyPath: _stateKeyPath] }
        set { _context.state[keyPath: _stateKeyPath] = newValue }
    }

    var environment: E {
        _context.environment[keyPath: _environmentKeyPath]
    }

    fileprivate func perform<R>(update: (inout S) -> R) -> R {
        _context.perform(on: _stateKeyPath, update: update)
    }
}

public class StoreContext<S, E>: ObservableObject where S: Equatable {
    private let _environment: E
    private let _queue: DispatchQueue
    private var _state: S

    public init(state: S,
                environment: E)
    {
        _environment = environment
        _state = state
        _queue = DispatchQueue(label: "com.swifttinyredux.queue",
                               attributes: .concurrent)
    }

    public fileprivate(set) var state: S {
        get { _queue.sync { _state } }
        set { perform(on: \.self) { $0 = newValue } }
    }

    public func partial<NS, NE>(state: WritableKeyPath<S, NS>, environment: KeyPath<E, NE>) -> PartialContext<S, E, NS, NE> {
        PartialContext(context: self, stateKeyPath: state,
                       environmentKeyPath: environment)
    }

    var environment: E {
        _queue.sync { _environment }
    }

    fileprivate func perform<R, NS>(on keyPath: WritableKeyPath<S, NS>, update: (inout NS) -> R) -> R where NS: Equatable {
        if Thread.isMainThread {
            var state = _state[keyPath: keyPath]
            let result = update(&state)
            if _state[keyPath: keyPath] != state {
                objectWillChange.send()
                _queue.sync(flags: .barrier) {
                    _state[keyPath: keyPath] = state
                }
            }
            return result
        }
        else {
            return DispatchQueue.main.sync {
                var state = _state[keyPath: keyPath]
                let result = update(&state)
                if _state[keyPath: keyPath] != state {
                    objectWillChange.send()
                    _queue.sync(flags: .barrier) {
                        _state[keyPath: keyPath] = state
                    }
                }

                return result
            }
        }
    }
}

public struct EmptySideEffect: SideEffect {
    public func perform(environment _: Any) async -> some Mutation {
        assertionFailure()
        return EmptyMutation()
    }
}

public extension SideEffect where Self == EmptySideEffect {
    static var empty: EmptySideEffect { EmptySideEffect() }
}

public struct EmptyMutation: Mutation {
    public func reduce(state _: inout AnyHashable) -> some SideEffect {
        assertionFailure()
        return EmptySideEffect()
    }
}

public extension Mutation where Self == EmptyMutation {
    static var empty: EmptyMutation { EmptyMutation() }
}

extension AnyMutation: Hashable {
    public static func == (lhs: AnyMutation, rhs: AnyMutation) -> Bool {
        lhs._base == rhs._base
    }

    public static func == <M>(lhs: AnyMutation, rhs: M) -> Bool where M: Mutation {
        lhs._base == AnyHashable(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(_base)
    }
}

private struct AnyMutation {
    private let _reduce: (Any, Any) -> Bool
    public let _base: AnyHashable

    public init(_ mutation: AnyMutation) {
        self = mutation
    }

    public init<M>(_ mutation: M) where M: Mutation {
        _base = mutation
        _reduce = { context, coordinator in
            guard let context = context as? AnyContext<M.S>,
                  let environment = context.environment as? M.SE.E,
                  let coordinator = coordinator as? StoreCoordinator
            else {
                return false
            }

            if type(of: mutation) == EmptyMutation.self {
                return false
            }

            let sideEffect = context.perform { oldState in
                mutation.reduce(state: &oldState)
            }

            if type(of: sideEffect) == EmptySideEffect.self {
                return true
            }

            Task.detached { [environment] in
                let nextMutation = await sideEffect.perform(environment: environment)
                _ = coordinator.reduce(AnyMutation(nextMutation))
            }

            return true
        }
    }

    func reduce(context: Any, coordinator: Any) -> Bool {
        _reduce(context, coordinator)
    }
}

private struct AnyContext<S> where S: Equatable {
    private let _perform: ((inout S) -> Any) -> Any
    private let _environment: Any
    private let _state: S

    init<E>(_ context: StoreContext<S, E>) {
        _perform = { context.perform(on: \.self, update: $0) }
        _environment = context.environment
        _state = context.state
    }

    init<OS, OE, E>(_ context: PartialContext<OS, OE, S, E>) {
        _perform = { context.perform(update: $0) }
        _environment = context.environment
        _state = context.state
    }

    var environment: Any {
        _environment
    }

    var state: S {
        _state
    }

    func perform<R>(update: (inout S) -> R) -> R {
        _perform(update) as! R
    }
}

private protocol Reducer {
    func reduce(_ mutation: AnyMutation) -> Bool
}

private struct Store<S>: Reducer where S: Equatable {
    private let _context: AnyContext<S>
    private let _coordinator: StoreCoordinator

    init(context: AnyContext<S>, coordinator: StoreCoordinator) {
        _context = context
        _coordinator = coordinator
    }

    func reduce(_ mutation: AnyMutation) -> Bool {
        mutation.reduce(context: _context,
                        coordinator: _coordinator)
    }
}

private struct ReducerFactory {
    private let _make: (StoreCoordinator) -> Reducer

    init<S, E>(_ context: StoreContext<S, E>) {
        _make = {
            Store(context: AnyContext(context), coordinator: $0)
        }
    }

    init<OS, OE, S, E>(_ context: PartialContext<OS, OE, S, E>) {
        _make = {
            Store(context: AnyContext(context), coordinator: $0)
        }
    }

    fileprivate func reducer(with coordinator: StoreCoordinator) -> Reducer {
        _make(coordinator)
    }
}
